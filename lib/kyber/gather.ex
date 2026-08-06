defmodule Kyber.Gather do
  @moduledoc """
  The gather (T10, spec/05-harness.md): the provisional subscription registry
  and firing engine. Handlers subscribe by their declared input shape — in
  T10 the shape is a ROLE (the first-pointer role, the claim's *flavor*) and
  the degenerate single-delta view: a handler saturates the instant one
  matching delta arrives, so it fires immediately with a one-element input
  view. The contract is written for composition, not just this case: a
  handler is a pure `([delta]) -> [delta]` function of its accumulated input
  view, and the view IS an ad-hoc container (its own delta-set) that fires on
  saturation — the reactor's future `{inputs, function}` is the same shape.

  **One object type, two channels.** A delta is `{claims, sig_hex}` — the same
  signed thing whether it is memory or a pulse. Whether it becomes MEMORY
  (persisted) or stays a PULSE (fires handlers, never persisted) is ADMISSION
  POLICY at the sink, never a property of the object:

    * `route/2` — a claim already IN the log (the daemon read it past the
      dispatch cursor). Fire matching handlers; sink each output. The input is
      already memory; this call only routes and produces.
    * `notify/2` — the live pulse/intake bus. A signed WIRE envelope is pushed
      in. The door verifies it first (a malformed/unsigned pulse is REFUSED,
      never fired — the door is never weakened). Then the admission knob: a
      shape tuned to `pulse_only` fires handlers WITHOUT persisting (ephemeral,
      fires exactly once by construction); every other shape is admitted to
      the store by default (persist-everything) and fires later through the
      daemon's cursor-tracked log-poll — one firing path for persisted claims,
      so `notify` never double-fires them.

  **The knob tunes DOWN, never up.** `pulse_only` is the only deviation from
  persist-everything; a shape whose history stops earning its keep (a
  `watcher.tick` heartbeat — D5) is tuned to pulse-only. Nothing is dropped by
  default.

  The `sink`/`persist` is one injected function `({claims, sig}) -> :ok |
  {:error, _}`: it admits a delta to the store (the daemon wires it to
  `Kyber.DurableStore.append/1`; tests inject a probe). Handlers are pure and
  sign their outputs with a key captured at subscription time (Ed25519 is
  deterministic — a function of claims+seed, no IO), so an output's content
  address is reproducible and re-firing is a union no-op.
  """

  use GenServer

  alias Kyber.{Store, Wire}

  @type delta :: {Rhizomatic.Delta.claims(), String.t()}
  @type handler :: ([delta()] -> [delta()])
  @type persist :: (delta() -> :ok | {:error, term()})

  # ------------------------------------------------------------------- API

  @doc """
  Start the gather. Options:

    * `:name` — the registered name (default `#{inspect(__MODULE__)}`; pass
      `nil` for an unnamed instance so tests can run async).
    * `:persist` — the sink `({claims, sig}) -> :ok | {:error, _}` (required).
    * `:pulse_only` — the flavors admitted pulse-only (default `[]`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Subscribe `handler` to a `flavor` (the first-pointer role it fires on)."
  @spec subscribe(GenServer.server(), String.t(), handler()) :: :ok
  def subscribe(gather \\ __MODULE__, flavor, handler)
      when is_binary(flavor) and is_function(handler, 1) do
    GenServer.call(gather, {:subscribe, flavor, handler})
  end

  @doc """
  Route a LOG delta (already persisted) to its matching handlers, sinking each
  output. Returns `{:ok, outputs}` — the sinked output deltas (the daemon uses
  their ids to advance the cursor).
  """
  @spec route(GenServer.server(), delta()) :: {:ok, [delta()]}
  def route(gather \\ __MODULE__, delta) do
    GenServer.call(gather, {:route, delta})
  end

  @doc """
  The live pulse/intake bus. Door-verify `wire`, then apply admission policy:
  a `pulse_only` shape fires (returns `{:ok, :pulsed}`); any other shape is
  admitted to the store (returns `{:ok, :persisted}`) and fires later via the
  daemon's log-poll. A door refusal returns `{:error, reason}` and fires
  nothing.
  """
  @spec notify(GenServer.server(), map()) ::
          {:ok, :pulsed | :persisted} | {:error, term()}
  def notify(gather \\ __MODULE__, wire) do
    GenServer.call(gather, {:notify, wire})
  end

  # ------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    # the default sink is the durable store; tests inject a probe
    persist = Keyword.get(opts, :persist, &__MODULE__.durable_sink/1)
    pulse_only = opts |> Keyword.get(:pulse_only, []) |> MapSet.new()
    {:ok, %{subs: %{}, persist: persist, pulse_only: pulse_only}}
  end

  @impl true
  def handle_call({:subscribe, flavor, handler}, _from, state) do
    subs = Map.update(state.subs, flavor, [handler], &(&1 ++ [handler]))
    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call({:route, delta}, _from, state) do
    {:reply, {:ok, fire_and_sink(delta, state)}, state}
  end

  def handle_call({:notify, wire}, _from, state) do
    {:reply, admit(wire, state), state}
  end

  # ----------------------------------------------------------- the sink

  # verify -> classify -> admit: the door FIRST (reject, never repair), then
  # the knob decides memory vs pulse
  defp admit(wire, state) do
    case Store.verify(wire) do
      {:ok, {claims, _sig} = delta} ->
        if MapSet.member?(state.pulse_only, flavor(claims)) do
          _outputs = fire_and_sink(delta, state)
          {:ok, :pulsed}
        else
          # persist-everything default: admit the input; the log-poll fires it
          case state.persist.(delta) do
            :ok -> {:ok, :persisted}
            {:error, _} = err -> err
          end
        end

      {:error, _reason} = err ->
        err
    end
  end

  # fire every handler matching the delta's flavor (single-delta saturated
  # view), sink each output, and return the outputs
  defp fire_and_sink({claims, _sig} = delta, state) do
    handlers = Map.get(state.subs, flavor(claims), [])

    outputs = Enum.flat_map(handlers, fn handler -> handler.([delta]) end)
    Enum.each(outputs, state.persist)
    outputs
  end

  # the flavor is the first-pointer role (spec/01-events.md: role.flavor). A
  # message.received flavors as "received"; its message.sent reply flavors as
  # "sent" — role-based routing makes "a handler is not its own subscriber"
  # STRUCTURAL, not a guard (AC2).
  defp flavor(%{pointers: [%{role: role} | _]}), do: role
  defp flavor(_), do: nil

  @doc false
  # the daemon's default sink: envelope a delta and append it to the durable
  # store. Kept here so the wiring lives with the gather it feeds.
  @spec durable_sink(delta()) :: :ok | {:error, term()}
  def durable_sink(delta) do
    Kyber.DurableStore.append(Wire.envelope(delta))
  end
end
