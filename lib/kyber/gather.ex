defmodule Kyber.Gather do
  @moduledoc """
  The provisional subscription registry (T10): handlers subscribe by declared
  input shape (T10: by ROLE — a match predicate over the claim); the gather
  routes new deltas into matching handlers' views and fires saturated ones.

  **Container-shaped** (the contract's spine §4): each subscription's
  accumulated view IS a container — its own delta-set, accumulated as
  matching deltas arrive, resolved by firing, dropped after firing (the view
  resets to empty once the handler has fired). T10 implements the degenerate
  single-delta form: every view saturates at one delta.

  **Two intake channels, one object type.** Both take the pinned wire
  envelope and both go through the door (`Kyber.Store.admit/2` — the ONE
  verification path; a malformed or unsigned delta is refused, never
  pulsed); the admission policy is the only difference:

  * `route/2` — the log channel: persist-everything default. A door-valid
    claim is appended to the store UNLESS its shape (first-pointer role) is
    tuned down to pulse-only (the admission knob, AC6).
  * `notify/1` — the live pulse bus: door-validated and dispatched, but the
    pulse itself is NEVER persisted (ephemeral by construction, D5).

  Handler outputs are ordinary signed deltas and persist through the door
  like any claim: a pulse's RESPONSE is memory even though the pulse is not
  (AC5 — the `watcher.tick` subscriber's `message.sent` lands in the store
  while no `watcher.tick` claim ever does).

  Handlers are pure `(delta[]) -> delta[]`: they receive their accumulated
  view (atom-keyed claims) and return signed deltas `{claims, sig_hex}`.
  A handler (or matcher) that raises is caught and reported — a broken
  subscription must never take the registry down.
  """

  use GenServer

  alias Kyber.{DeltaSet, DurableStore, Store, Wire}

  @type claims :: Rhizomatic.Delta.claims()
  @type signed :: {claims(), String.t()}
  @type match :: (claims() -> boolean())
  @type handler :: ([claims()] -> [signed()])
  @type report :: %{
          id: String.t() | nil,
          role: String.t() | nil,
          persisted: boolean(),
          fired: [term()],
          errors: [term()]
        }

  # ------------------------------------------------------------------- API

  @doc """
  Start the registry. Options: `:pulse_only` (list of first-pointer roles
  tuned down to pulse-only — the admission knob, AC6), `:name` (default
  `Kyber.Gather`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribe a handler by input shape: `match` selects the deltas that
  accumulate into the handler's view; `handler` fires on saturation. The
  subscription id is unique — a duplicate is refused.
  """
  @spec subscribe(GenServer.server(), term(), match(), handler()) ::
          :ok | {:error, {:already_subscribed, term()}}
  def subscribe(server \\ __MODULE__, id, match, handler)
      when is_function(match, 1) and is_function(handler, 1) do
    GenServer.call(server, {:subscribe, id, match, handler})
  end

  @doc """
  The log channel (persist-everything default): door-verify, persist unless
  the claim's shape is tuned pulse-only, dispatch to matching views, fire
  saturated handlers. Options: `:persist` — `false` for claims that are
  already persisted (the daemon's log tail; default `true`).
  """
  @spec route(GenServer.server(), map(), keyword()) :: {:ok, report()} | {:error, term()}
  def route(server \\ __MODULE__, wire, opts \\ []) do
    GenServer.call(server, {:intake, wire, :log, Keyword.get(opts, :persist, true)})
  end

  @doc """
  The live pulse bus: door-verify and dispatch, NEVER persist the pulse.
  Arity-1 targets the registry named `Kyber.Gather` (the daemon's).
  """
  @spec notify(map()) :: {:ok, report()} | {:error, term()}
  def notify(wire), do: notify(__MODULE__, wire)

  @spec notify(GenServer.server(), map()) :: {:ok, report()} | {:error, term()}
  def notify(server, wire) do
    GenServer.call(server, {:intake, wire, :pulse, false})
  end

  @doc "The subscription ids currently registered (introspection for tests)."
  @spec subscriptions(GenServer.server()) :: [term()]
  def subscriptions(server \\ __MODULE__) do
    GenServer.call(server, :subscriptions)
  end

  # ------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    {:ok,
     %{
       subs: [],
       pulse_only: opts |> Keyword.get(:pulse_only, []) |> MapSet.new()
     }}
  end

  @impl true
  def handle_call({:subscribe, id, match, handler}, _from, state) do
    if Enum.any?(state.subs, &(&1.id == id)) do
      {:reply, {:error, {:already_subscribed, id}}, state}
    else
      sub = %{id: id, match: match, handler: handler, view: []}
      {:reply, :ok, %{state | subs: state.subs ++ [sub]}}
    end
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, Enum.map(state.subs, & &1.id), state}
  end

  def handle_call({:intake, wire, channel, persist?}, _from, state) do
    case door(wire) do
      {:ok, id, claims} ->
        case admit_memory(channel, persist?, wire, claims, state) do
          {:ok, persisted} ->
            {report, state} = dispatch(claims, state)

            {:reply,
             {:ok,
              %{
                id: id,
                role: first_role(claims),
                persisted: persisted,
                fired: report.fired,
                errors: report.errors
              }}, state}

          {:error, _reason} = err ->
            {:reply, err, state}
        end

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  # ------------------------------------------------------------------ door

  # the ONE verification path — the same pure door the store's replay and
  # live appends use; the gathered claims are the admitted set's own parsed
  # form (atom-keyed, signature-verified)
  defp door(wire) do
    case Store.admit(wire, DeltaSet.new()) do
      {:ok, set} ->
        {id, {claims, _sig}} = Enum.at(set, 0)
        {:ok, id, claims}

      {:error, _reason} = err ->
        err
    end
  end

  # ------------------------------------------------------------- admission

  # the admission policy is the ONLY difference between the channels; both
  # are door-verified before this point. A persist failure fails the intake
  # (the claim is neither remembered nor dispatched — the log channel's
  # whole point is memory).
  defp admit_memory(:pulse, _persist?, _wire, _claims, _state), do: {:ok, false}

  defp admit_memory(:log, false, _wire, _claims, _state), do: {:ok, false}

  defp admit_memory(:log, true, wire, claims, state) do
    if MapSet.member?(state.pulse_only, first_role(claims)) do
      {:ok, false}
    else
      persist(wire)
    end
  end

  # union is idempotent: a claim the store already knows is not re-appended
  # (the log would grow a duplicate LINE even though the set would not)
  defp persist(wire) do
    with :ok <- guard_store(),
         {:ok, known?} <- known(wire) do
      if known? do
        {:ok, true}
      else
        case DurableStore.append(wire) do
          :ok -> {:ok, true}
          {:error, _reason} = err -> err
        end
      end
    end
  end

  defp persist_output(signed) do
    with :ok <- guard_store() do
      signed |> Wire.envelope() |> DurableStore.append()
    end
  end

  defp guard_store do
    if Process.whereis(DurableStore), do: :ok, else: {:error, :store_not_running}
  end

  defp known(wire) do
    try do
      {:ok, DeltaSet.member?(DurableStore.set(), Map.fetch!(wire, "id"))}
    catch
      :exit, {:noproc, _} -> {:error, :store_not_running}
      :exit, reason -> {:error, {:store_exit, reason}}
    end
  end

  # -------------------------------------------------------------- dispatch

  # route the claims into every matching view; fire the saturated ones.
  # A fired view resets to empty (droppable after firing); a crashing
  # matcher is a non-match and a crashing handler is reported — neither
  # takes the registry down.
  defp dispatch(claims, state) do
    {fired, errors, subs} =
      Enum.reduce(state.subs, {[], [], state.subs}, fn sub, {fired, errors, subs} ->
        case safe_apply(sub.match, claims) do
          {:ok, true} ->
            view = sub.view ++ [claims]

            case safe_apply(sub.handler, view) do
              {:ok, outputs} when is_list(outputs) ->
                output_errors = persist_outputs(outputs)
                sub = %{sub | view: []}
                {[sub.id | fired], errors ++ output_errors, put_sub(subs, sub)}

              {:ok, _not_a_list} ->
                sub = %{sub | view: []}
                {fired, [{:handler_not_a_list, sub.id} | errors], put_sub(subs, sub)}

              {:error, reason} ->
                sub = %{sub | view: []}
                {fired, [{:handler_error, sub.id, reason} | errors], put_sub(subs, sub)}
            end

          {:ok, _not_true} ->
            {fired, errors, subs}

          {:error, reason} ->
            {fired, [{:match_error, sub.id, reason} | errors], subs}
        end
      end)

    {%{fired: Enum.reverse(fired), errors: Enum.reverse(errors)}, %{state | subs: subs}}
  end

  defp persist_outputs(outputs) do
    Enum.reduce(outputs, [], fn signed, errors ->
      case persist_output(signed) do
        :ok -> errors
        {:error, reason} -> [{:output_refused, reason} | errors]
      end
    end)
    |> Enum.reverse()
  end

  defp put_sub(subs, sub) do
    Enum.map(subs, fn
      %{id: id} when id == sub.id -> sub
      other -> other
    end)
  end

  defp safe_apply(fun, arg) do
    {:ok, fun.(arg)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp first_role(claims) do
    case List.first(claims.pointers) do
      %{role: role} -> role
      _ -> nil
    end
  end
end
