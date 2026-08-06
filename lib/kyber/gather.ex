defmodule Kyber.Gather do
  @moduledoc """
  The provisional subscription registry (T10): handlers subscribe by declared
  input shape and fire when that shape is SATURATED. The handler contract is
  `(delta[]) -> delta[]` — a pure function of its accumulated input view,
  returning zero or more signed wire envelopes.

  **The gather is container-shaped.** Each subscription's accumulated view IS
  an ad-hoc container: its own delta-set, resolvable, dropped after firing.
  T10 implements the degenerate form — the declared shape is a single ROLE
  and the view saturates at one delta — but the structure is the general one:
  a subscription carries `{role, saturation, view}`, the gather accumulates
  matching deltas into the view, and the handler fires on saturation (the
  reactor's future `{inputs, function}` is the same shape).

  Routing matches on the FIRST pointer's role — the atom has no kind field
  (SPEC-1 §2: the event kind is the template's leading pointer role, and
  template order is part of the content address). `message.received` routes
  as `"received"`; the ack's `message.sent` routes as `"sent"`; a handler is
  therefore structurally unable to subscribe to its own outputs (AC2).

  A handler that crashes (or returns a non-list) contributes an error, never
  a gather crash — the daemon's loop must survive a bad handler. Handlers run
  inside the gather process and MUST be pure: a handler that calls back into
  the gather (or the daemon) would deadlock; the contract forbids it anyway.

  `notify/1` is the PULSE channel (AC5): an ephemeral signed delta, verified
  by the same door as every persisted claim (`Kyber.Store.verify/1` — reject,
  never repair), routed immediately, and NEVER persisted here. Outputs the
  pulse fires are handed to the running daemon's sink (`Kyber.Daemon.emit/1`,
  persist-everything default) and returned to the caller. `notify/1` runs in
  the caller's process — the daemon itself never calls it (its own heartbeat
  routes internally), so the hand-off cannot deadlock.
  """

  use GenServer

  alias Rhizomatic.Delta

  @type delta :: %{id: String.t(), claims: Delta.claims()}
  @type handler :: ([delta()] -> [map()])
  @type route_report :: %{fired: non_neg_integer(), outputs: [map()], errors: [term()]}

  @doc "Start the registry (empty — subscriptions are runtime state, never claims)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribe a handler by role (the T10 degenerate input shape: one role,
  saturation 1). Returns `{:ok, ref}`.
  """
  @spec subscribe(String.t(), handler()) :: {:ok, reference()}
  def subscribe(role, fun) when is_binary(role) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:subscribe, role, fun})
  end

  @doc """
  Route one verified delta into every matching subscription's view and fire
  the saturated ones. Returns `{:ok, %{fired: n, outputs: [wire], errors: [..]}}`
  with outputs in subscription order. The caller owns what happens to the
  outputs (the daemon's sink applies the admission policy).
  """
  @spec route(delta()) :: {:ok, route_report()} | {:error, :gather_not_running}
  def route(delta) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:route, delta})
    else
      {:error, :gather_not_running}
    end
  end

  @doc """
  The live-pulse intake (AC5): verify the wire at the door, route it, hand
  any fired outputs to the daemon's sink (when a daemon is running), and
  return `{:ok, outputs}`. The pulse itself is never persisted — ephemeral by
  channel. A door-refused pulse returns the door's own reason and routes
  nothing.
  """
  @spec notify(map()) :: {:ok, [map()]} | {:error, term()}
  def notify(wire) do
    with {:ok, delta} <- Kyber.Store.verify(wire),
         {:ok, report} <- route(delta) do
      if Process.whereis(Kyber.Daemon), do: Enum.each(report.outputs, &Kyber.Daemon.emit/1)
      {:ok, report.outputs}
    end
  end

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(:ok), do: {:ok, %{subs: []}}

  @impl true
  def handle_call({:subscribe, role, fun}, _from, state) do
    ref = make_ref()
    sub = %{ref: ref, role: role, saturation: 1, view: [], fun: fun}
    {:reply, {:ok, ref}, %{state | subs: state.subs ++ [sub]}}
  end

  def handle_call({:route, delta}, _from, state) do
    role = kind_marker(delta.claims)

    {subs, report} =
      Enum.map_reduce(state.subs, %{fired: 0, outputs: [], errors: []}, fn sub, acc ->
        if sub.role == role, do: accumulate(sub, delta, acc), else: {sub, acc}
      end)

    {:reply, {:ok, %{report | outputs: Enum.reverse(report.outputs)}}, %{state | subs: subs}}
  end

  # -------------------------------------------------------------- machinery

  # the kind marker: the template's FIRST pointer role (SPEC-1 §2)
  defp kind_marker(%{pointers: [%{role: role} | _rest]}), do: role

  # the container in motion: append to the view; fire on saturation; the
  # fired view is dropped (a fresh container accumulates the next match)
  defp accumulate(sub, delta, acc) do
    view = sub.view ++ [delta]

    if length(view) >= sub.saturation do
      case run_handler(sub.fun, view) do
        {:ok, outputs} ->
          {%{sub | view: []},
           %{acc | fired: acc.fired + 1, outputs: Enum.reverse(outputs) ++ acc.outputs}}

        {:error, reason} ->
          {%{sub | view: []}, %{acc | errors: acc.errors ++ [reason]}}
      end
    else
      {%{sub | view: view}, acc}
    end
  end

  # a bad handler is an error entry, never a gather crash — the daemon loop
  # outlives its worst subscriber
  defp run_handler(fun, view) do
    case fun.(view) do
      outputs when is_list(outputs) -> {:ok, outputs}
      _other -> {:error, :handler_output_not_a_list}
    end
  rescue
    e -> {:error, {:handler_crashed, Exception.message(e)}}
  end
end
