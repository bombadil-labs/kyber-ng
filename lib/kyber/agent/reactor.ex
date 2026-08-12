defmodule Kyber.Agent.Reactor do
  @moduledoc """
  The event-driven reactor (T14a): an agent that RUNS. A store delta whose
  kind matches a subscription routes to its handler WITHOUT a manual tick —
  the store's post-commit append casts the pin-1 seam
  (`GenServer.cast(Kyber.Agent.Reactor, {:ingest, delta})`) and the daemon's
  flush under `loop: :reactor` forwards cursor deltas through the same seam
  (pin 26). Once-per-delta-id routing dedupes push duplicates; per-turn
  budgets constrain the turn (a turn exceeding its budget terminates
  cleanly with a refusal delta — the mailbox-empty class of failure is
  excluded by construction); model initiation is gated by the Oracle seed.

  The reactor HOSTS the closed refusal loop (the engine "decides"
  subscription + refusal routing, merged pre-2026-08-07) — it does not
  rebuild it. Refusals ARE `GateDecision` deltas routed as `"decides"`.

  Placement (pin 2/H3): daemon-scoped — started BY the daemon under
  `loop: :reactor` only, registered under the module name so the pin-1 cast
  reaches it; its lifetime IS the daemon's; it never appears in the app
  tree. Where no reactor is running the store's cast is a silent no-op.

  The engine seam (pin 6/H6): the reactor starts and owns the hosted engine,
  constructed at init from the single boot opt `engine: keyword() | :none`
  (default `:none`). Under `:none` there IS no engine — the `"promptRef"`
  handler (post-gate) is `:ignore` and no code path can construct an HTTP
  client; deterministic tests boot `engine: :none` and can NEVER fire a real
  model call. The AC4 operational test injects the recording adapter + real
  key through this same opt.
  """

  use GenServer

  alias Kyber.{DurableStore, Keys, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, Events, LlmHandler, MemoryPort, Profile, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @default_cap 32

  @typedoc "The dispatch handler contract (pin 6): emit wires, refuse with a pinned reason, or ignore."
  @type handler_result :: {:emit, [map()]} | {:refuse, atom()} | :ignore

  # ------------------------------------------------------------- the pins

  # pin 6: the pinned context — store pid, the emitting turn (nil outside a
  # turn), and the test observation pid (nil in production).
  defmodule Ctx do
    @moduledoc false
    defstruct store: nil, turn: nil, test_pid: nil
  end

  # pin 11: the per-turn record — turn_id = the initiating "received"
  # claim's content-derived id; budget = the per-turn Budget.
  defmodule Turn do
    @moduledoc false
    defstruct turn_id: nil, budget: nil
  end

  # pin 13: the pure budget core. Pins 9–12: one dispatch unit per
  # dispatched delta of a subscribed kind, check-before-dispatch, a charge
  # landing exactly on max succeeds and the next exhausts.
  defmodule Budget do
    @moduledoc false
    @type t :: %{cap: pos_integer(), charged: non_neg_integer()}
    @spec new(pos_integer()) :: t()
    def new(cap), do: %{cap: cap, charged: 0}
    @spec charge(t()) :: t()
    def charge(%{charged: n} = budget), do: %{budget | charged: n + 1}
    @spec exhausted?(t()) :: boolean()
    def exhausted?(%{cap: cap, charged: charged}), do: charged >= cap
  end

  # -------------------------------------------------------------- handlers

  # pin 14/16: the gate check is the FIRST line of BOTH the "received" and
  # "promptRef" handlers — a PURE store check (gate open iff an UNRETRACTED
  # seed claim exists; retraction-is-negation closes it)
  def handle_received(delta, _ctx) do
    if gate_open?() do
      {:emit, Process.get({__MODULE__, :builder}).([delta])}
    else
      {:refuse, :no_oracle_seed}
    end
  end

  def handle_prompt_ref(delta, _ctx) do
    if gate_open?() do
      delegate_to_engine(delta)
    else
      {:refuse, :no_oracle_seed}
    end
  end

  # "call" is the ToolResult role — never an initiation gate (pin 14,
  # vacuous); delegates to the hosted engine's tool_result path
  def handle_call(delta, _ctx), do: delegate_to_engine(delta)

  # the closed refusal loop (T12 carry): GateDecision deltas route to the
  # engine so a denied/refused call comes back to the model — hosted, never
  # rebuilt
  def handle_decides(delta, _ctx), do: delegate_to_engine(delta)

  # "tool" delegates to the existing executor path (pure gather handler)
  def handle_tool(delta, _ctx) do
    {:emit, Process.get({__MODULE__, :executor}).([delta])}
  end

  def delegate_to_engine(delta) do
    case Process.get({__MODULE__, :engine}) do
      nil ->
        # pin 6/H6: under engine: :none there IS no engine — :ignore, and
        # no code path can construct an HTTP client
        :ignore

      engine ->
        # the engine's own gather handler shape: cast the delta in, no
        # outputs (async — the sink carries the results)
        GenServer.cast(engine, {:delta, delta})
        :ignore
    end
  end

  # ------------------------------------------------------------------- api

  @doc "The pin-1 seam: one verified delta enters the reactor (cast)."
  @spec ingest(map()) :: :ok
  def ingest(%{id: _id, claims: _claims} = delta),
    do: GenServer.cast(__MODULE__, {:ingest, delta})

  @doc """
  Start the reactor (pin 2/H3): BY the daemon, under `loop: :reactor` only,
  registered under the module name. Options: `:seed` (the daemon's agent
  seed, required), `:budget_cap` (default #{@default_cap}), `:engine`
  (keyword | :none, default :none), `:test_pid` (observation pid),
  `:operator_seed` (hex — T14c D5: emit the boot attestation at init when
  the store holds an unretracted seed claim under that seed; default nil).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)
    engine_opts = Keyword.get(opts, :engine, :none)

    # T14i (H7/H8): the ONE boot-context resolution (the shared helper — the
    # SAME refusal attach uses): {profile, nil} refuses loudly, an unknown
    # profile name refuses loudly; the boot tuple feeds the engine's `:boot`
    # opt AND the construction-time capability intersect (reactor.ex:441).
    with {:ok, boot} <- Profile.boot_context(opts),
         {:ok, engine} <- start_engine(seed, engine_opts, boot),
         {:ok, builder} <- builder_for(seed, engine_opts),
         {:ok, executor} <- executor_for(seed, engine_opts, boot),
         :ok <- attest_boot(opts, seed) do
      # the handlers (pin 6, module functions of (delta, ctx)) reach the
      # state-dependent machinery through the reactor's own process
      # dictionary — the callbacks run inside this process, so the
      # dictionary IS part of the state (a plain closure would break the
      # pinned handle_<kind>/2 contract).
      Process.put({__MODULE__, :engine}, engine)
      Process.put({__MODULE__, :builder}, builder)
      Process.put({__MODULE__, :executor}, executor)

      {:ok,
       %{
         seed: seed,
         author: Keys.author_for_seed(seed),
         store: Process.whereis(DurableStore),
         budget_cap: Keyword.get(opts, :budget_cap, @default_cap),
         engine: engine,
         test_pid: Keyword.get(opts, :test_pid),
         turns: %{},
         dispatched: MapSet.new(),
         emitted: %{},
         invocation_count: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:ingest, delta}, state) do
    # pin 8: routing owns once-per-delta-id — a push duplicate (the flush's
    # dead-letter drain re-forwarding a delta the push cast already
    # delivered) is dropped; the store's content-addressed admission skip is
    # the backstop; no capped MapSet cache.
    if MapSet.member?(state.dispatched, delta.id) do
      {:noreply, state}
    else
      state = %{state | dispatched: MapSet.put(state.dispatched, delta.id)}
      {:noreply, route(state, delta)}
    end
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  # engine completion signals (notify: defaults to the reactor, pin 6) are
  # forwarded to the observer when one is watching (the AC4 sleep-free wait),
  # dropped otherwise — never fatal
  @impl true
  def handle_info({:engine, _event} = message, state) do
    if state.test_pid, do: send(state.test_pid, message)
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # pin 3: the subscription map is a STATIC module-attribute constant — no
  # runtime subscribe/2; observation rides Ctx.test_pid, never mutation.
  # pin 4/5: wire strings verbatim, the five Gather kinds only; no :refusal
  # kind — refusals ARE GateDecision deltas routed as "decides".
  @subscriptions %{
    "received" => &__MODULE__.handle_received/2,
    "promptRef" => &__MODULE__.handle_prompt_ref/2,
    "call" => &__MODULE__.handle_call/2,
    "tool" => &__MODULE__.handle_tool/2,
    "decides" => &__MODULE__.handle_decides/2
  }

  # -------------------------------------------------------------- routing

  # pin 6: a kind not in the map is :ignore, never an error
  defp route(state, delta) do
    case Map.fetch(@subscriptions, kind(delta)) do
      {:ok, handler} -> dispatch(state, handler, delta)
      :error -> state
    end
  end

  # pins 9/10: check-before-dispatch — an exceeding dispatch never fires;
  # a charge landing exactly on max succeeds, the next exhausts. Pin 7: turn
  # end is STRUCTURAL (chain end or budget refusal), never mailbox-emptiness.
  defp dispatch(state, handler, delta) do
    delta_kind = kind(delta)
    {state, turn} = turn_for(state, delta_kind, delta)

    case turn do
      nil ->
        # a delta that resolves to no turn (no walkable pointer to a
        # received) initiates or is ignored per pin 14 — never charged to an
        # arbitrary turn
        state

      %Turn{} = turn ->
        if Budget.exhausted?(turn.budget) do
          refuse_budget(state, turn, delta, delta_kind)
        else
          turn = %{turn | budget: Budget.charge(turn.budget)}
          state = %{state | turns: Map.put(state.turns, turn.turn_id, turn)}
          invoke(state, handler, delta_kind, delta, turn)
        end
    end
  end

  # pin 14: a turn is initiated by a "received" delta — the Turn record is
  # created there, keyed by the initiating claim's content-derived id (pin 11)
  defp turn_for(state, "received", delta) do
    case Map.get(state.turns, delta.id) do
      %Turn{} = turn ->
        {state, turn}

      nil ->
        turn = %Turn{turn_id: delta.id, budget: Budget.new(state.budget_cap)}
        {%{state | turns: Map.put(state.turns, delta.id, turn)}, turn}
    end
  end

  defp turn_for(state, _kind, delta) do
    case resolve_turn(state, delta) do
      %Turn{} = turn -> {state, turn}
      :no_turn -> {state, nil}
    end
  end

  # SYNTH-NEW-1/H5 attribution precedence: the Ctx.turn carry (the reactor's
  # own emission record) when present, else the pointer-walk against store
  # state (the engine's rebuild_pending pattern — store-derived per AC5)
  defp resolve_turn(state, delta) do
    case Map.get(state.emitted, delta.id) do
      nil ->
        case walk_to_received(DurableStore.set(), delta.id) do
          nil -> :no_turn
          received_id -> Map.get(state.turns, received_id) || :no_turn
        end

      turn_id ->
        Map.get(state.turns, turn_id) || :no_turn
    end
  end

  # the pointer-walk: ToolCall.requestRef → promptRef → the initiating
  # received (the substrate's rebuild_pending shape, against store state)
  defp walk_to_received(set, id), do: do_walk(set, id, MapSet.new())

  defp do_walk(_set, nil, _seen), do: nil

  defp do_walk(set, id, seen) do
    cond do
      MapSet.member?(seen, id) ->
        nil

      true ->
        case Map.get(set, id) do
          nil ->
            nil

          {claims, _sig} ->
            case kind(claims) do
              "received" -> id
              other -> walk_pointer(set, claims, other, id, seen)
            end
        end
    end
  end

  defp walk_pointer(set, claims, delta_kind, id, seen) do
    case pointer(claims, walk_role(delta_kind)) do
      {:delta, next, _ctx} -> do_walk(set, next, MapSet.put(seen, id))
      _other -> nil
    end
  end

  # the pointer role that leads toward the initiating received, per kind
  defp walk_role("promptRef"), do: "promptRef"
  defp walk_role("tool"), do: "requestRef"
  defp walk_role("call"), do: "call"
  defp walk_role("decides"), do: "decides"
  defp walk_role(_other), do: nil

  # -------------------------------------------------------------- invoke

  defp invoke(state, handler, delta_kind, delta, turn) do
    ctx = %Ctx{store: state.store, turn: turn, test_pid: state.test_pid}

    case handler.(delta, ctx) do
      {:emit, wires} ->
        state |> emit(turn.turn_id, wires) |> observe(delta_kind, delta)

      {:refuse, reason} ->
        state |> refuse(turn.turn_id, delta, reason) |> observe(delta_kind, delta)

      :ignore ->
        observe(state, delta_kind, delta)
    end
  end

  # pin 19/20: the production handlers are OBSERVED — Ctx.test_pid probe
  # message as the fast signal + the per-invocation-DISTINCT probe claim in
  # the store as the proof (under merge-is-union, identical re-emits
  # collapse to one claim and would fake the count — the embedded delta id +
  # invocation index makes a double dispatch TWO claims, never one). The
  # probe claims the dispatched delta's timestamp: no wall-clock in the
  # reactor's decision surface (AC5, the two-boot companion).
  defp observe(state, _kind, _delta) when is_nil(state.test_pid), do: state

  defp observe(state, delta_kind, delta) do
    count = state.invocation_count + 1
    probe = probe_wire(state, delta, count)
    # the probe claim lands BEFORE the fast signal, so the message implies
    # the store effect
    DurableStore.append(probe)
    send(state.test_pid, {:reactor, {:dispatch, delta_kind, delta.id}})
    %{state | invocation_count: count}
  end

  defp probe_wire(state, delta, index) do
    raw = %{
      timestamp: delta.claims.timestamp,
      author: state.author,
      pointers: [%{role: "probe", target: {:string, "dispatch:#{delta.id}##{index}"}}]
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, state.seed)
    Wire.envelope({claims, sig})
  end

  # pin 26(b): emissions go DIRECTLY to DurableStore.append, never
  # Daemon.emit; the reactor NEVER makes a synchronous call to the daemon.
  defp emit(state, turn_id, wires) do
    Enum.reduce(wires, state, fn wire, s ->
      # the Ctx.turn carry through the re-entry seam (SYNTH-NEW-1): this
      # emission re-enters attributed to the emitting handler's turn
      s = %{s | emitted: Map.put(s.emitted, wire["id"], turn_id)}
      DurableStore.append(wire)
      s
    end)
  end

  # pin 5/6: refusals ARE GateDecision deltas routed as "decides"; M2/M3:
  # refusal GateDecisions carry verdict "refuse" and policy
  # "oracle_gate"/"budget"; the emission timestamp = the dispatched delta's
  # claims.timestamp (never System.system_time).
  defp refuse(state, turn_id, delta, reason) do
    {verdict, policy} =
      case reason do
        :no_oracle_seed -> {"refuse", "oracle_gate"}
        :budget_exhausted -> {"refuse", "budget"}
      end

    case Events.gate_decision(state.seed, delta.claims.timestamp, delta.id, verdict, policy) do
      {:ok, signed} -> emit(state, turn_id, [Wire.envelope(signed)])
      {:error, _reason} -> state
    end
  end

  # H2 DROP-REFUSAL-OF-REFUSAL (pin 10): a refused dispatch emits the budget
  # GateDecision ONLY IF the refused delta's kind is NOT "decides"; a
  # refused "decides" emits nothing and the turn is structurally terminal —
  # exactly one refusal delta, finite store, no live-lock, no hang.
  defp refuse_budget(state, _turn, _delta, "decides"), do: state

  defp refuse_budget(state, turn, delta, _kind),
    do: refuse(state, turn.turn_id, delta, :budget_exhausted)

  # pin 16: the gate — open iff an UNRETRACTED seed claim exists (the seed
  # is asserted by the daemon's oracle_seed boot opt, pin 17); M2:
  # retraction-detection scans for a negates pointer targeting the seed id
  defp gate_open? do
    case Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} -> kind(claims) == "seed" end) do
      nil -> false
      {seed_id, _seed_claims} -> not retracted?(seed_id)
    end
  end

  defp retracted?(seed_id) do
    Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
      match?({:delta, ^seed_id, _ctx}, pointer(claims, "negates"))
    end)
  end

  # ------------------------------------------------------------- machinery

  # pin 6/H6: the hosted engine — constructed at reactor init from the
  # engine boot opt; sink omitted => the reactor's own emission path (direct
  # DurableStore.append, never Daemon.emit); notify defaults to the reactor
  defp start_engine(_seed, :none, _boot), do: {:ok, nil}

  defp start_engine(seed, opts, boot) when is_list(opts) do
    with {:ok, llm} <- llm_for(seed, opts) do
      # T14i (H8 — the FOURTH touchpoint): the capability intersect is
      # consumed at the ENGINE CONSTRUCTION — the SINGLE `tools` var is
      # narrowed by the shared helper BEFORE tool_specs/tool_key_map, so
      # profile-excluded tools are neither advertised nor executable (the
      # enforcement spelling is the executor's "unknown tool").
      # T14j (C1): the workspace-aware default — the ONE tuple-returning
      # helper (explicit :tools/:context win (M1); absent :workspace =>
      # stub, byte-identical); the intersect narrows AFTER the seam. The
      # engine consumes only the tools half (the context rides the
      # executor, reactor.ex executor_for).
      {tools, _context} = ToolExecutor.default_tools(opts)
      tools = Profile.intersect_tools(tools, boot)

      engine_opts = [
        name: nil,
        llm: llm,
        tools: ToolExecutor.tool_specs(tools),
        tool_keys: ToolExecutor.tool_key_map(tools),
        store: &DurableStore.set/0,
        sink: Keyword.get(opts, :sink, &DurableStore.append/1),
        notify: Keyword.get(opts, :notify, self()),
        # T14g (R1): the ONE boot context {profile | nil, operator_author |
        # nil} — the engine's assemble site is profile-aware under a profile
        boot: boot
      ]

      case Engine.start_link(engine_opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Builds the engine's LLM handler from daemon-supplied opts (model /
  # base_url / api_key / system_prompt). Exposed so Daemon.boot can wire a
  # real engine for a :reactor loop (it must not default to :none — that
  # leaves delegate_to_engine with a nil engine and the model is never
  # called). Absent opts => k3 defaults inside LlmHandler.new.
  def llm_for(seed, opts) do
    case Keyword.get(opts, :llm) do
      %LlmHandler{} = llm -> {:ok, llm}
      nil -> LlmHandler.new(seed: seed, api_key: Keyword.get(opts, :api_key),
                            base_url: Keyword.get(opts, :base_url),
                            model: Keyword.get(opts, :model),
                            system_prompt: Keyword.get(opts, :system_prompt))
    end
  end

  # the received → InferenceRequested path (the existing context builder —
  # hosted, never rebuilt)
  defp builder_for(seed, :none) do
    {:ok, ContextBuilder.handler(seed: seed, store: &DurableStore.set/0)}
  end

  defp builder_for(seed, opts) when is_list(opts) do
    {:ok,
     ContextBuilder.handler(
       seed: seed,
       store: &DurableStore.set/0,
       memory: Keyword.get(opts, :memory, {MemoryPort.Stub, %{}})
     )}
  end

  # the tool path (the existing pure executor handler — hosted, never rebuilt)
  defp executor_for(seed, :none, _boot) do
    {:ok, ToolExecutor.handler(seed: seed, store: &DurableStore.set/0)}
  end

  defp executor_for(seed, opts, boot) when is_list(opts) do
    # T14i (H8): the SAME narrowed `tools` var feeds the executor registry —
    # a one-sided intersect would leave profile-excluded tools executable
    # T14j (C1): BOTH halves of the workspace-aware default are consumed
    # here — the tools (the registry) AND the context (the executor's
    # context-parity half; an unthreaded context answers the fs/sh
    # arg-error-string class, never real content).
    {tools, context} = ToolExecutor.default_tools(opts)
    tools = Profile.intersect_tools(tools, boot)

    {:ok,
     ToolExecutor.handler(
       seed: seed,
       tools: tools,
       gate: Keyword.get(opts, :gate, Gate.new()),
       context: context,
       store: &DurableStore.set/0,
       # T14g (M2): the boot context threads into the tool-side policy
       # layers too — profile-aware epochs under a profile
       boot: boot
     )}
  end

  # T14c D5/H3: the operator-key boot attestation. Boot opt :operator_seed
  # (hex), default nil => no attestation (existing boots unchanged); no
  # UNRETRACTED seed claim in the store under [the boot carrying] the
  # operator seed => no attestation — skip, never crash. The attested seed
  # claim is THE oracle seed claim (T14a pin 17: asserted by the daemon at
  # boot, signed by its boot key — "operator-key signing stays T14c" means
  # the ATTESTATION is operator-signed, never the seed claim). Emission at
  # init via DIRECT DurableStore.append (never Daemon.emit); ts = the seed
  # claim's claims.timestamp — the only store-derived clock at boot — so
  # reboots over one store merge to exactly one attestation (union-no-op).
  defp attest_boot(opts, agent_seed) do
    case Keyword.get(opts, :operator_seed) do
      nil ->
        :ok

      operator_seed ->
        agent_author = Keys.author_for_seed(agent_seed)

        case unretracted_seed_claim(DurableStore.set()) do
          nil ->
            :ok

          {seed_claim_id, seed_claims} ->
            case Events.boot_attestation(
                   operator_seed,
                   seed_claims.timestamp,
                   agent_author,
                   seed_claim_id
                 ) do
              {:ok, signed} ->
                # skip, never crash: an append failure must not fail the boot
                case DurableStore.append(Wire.envelope(signed)) do
                  :ok -> :ok
                  {:error, _reason} -> :ok
                end

              {:error, _reason} ->
                :ok
            end
        end
    end
  end

  # THE unretracted seed claim: kind "seed" (the oracle seed claim the
  # daemon asserted at boot), no negates pointer at its id — the store
  # only learns, so retraction-detection is the closing mechanism
  defp unretracted_seed_claim(set) do
    retracted = retracted_ids(set)

    Enum.find_value(set, fn {id, {claims, _sig}} ->
      if kind(claims) == "seed" and not MapSet.member?(retracted, id), do: {id, claims}
    end)
  end

  defp retracted_ids(set) do
    for {_id, {claims, _sig}} <- set,
        %{role: "negates", target: {:delta, target, _ctx}} <- claims.pointers,
        into: MapSet.new(),
        do: target
  end

  defp kind(%{claims: %{pointers: [%{role: role} | _rest]}}), do: role
  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
