defmodule Kyber.Daemon do
  require Logger

  @moduledoc """
  The long-lived process (T10): an agent actually living in the claims
  substrate. The daemon boots against the app-configured store, watches the
  log for claims newer than its dispatch cursor (a `send_after` TICKER —
  never `Process.sleep`), routes new deltas into `Kyber.Gather`, applies the
  admission policy to everything the handlers produce, and shuts down
  cleanly on SIGTERM.

  **Two channels, one object type (AC5).** Deltas ARE the events; persisted
  vs pulse is admission policy at the sink, never a type:

    * the LOG channel — claims already persisted (CLI ingest, federation,
      the daemon's own appends) are dispatched once, in log order, and the
      cursor advances;
    * the PULSE channel — ephemeral signed deltas (`Kyber.Gather.notify/1`,
      plus the daemon's own `watcher.tick` heartbeat each tick) are door-
      verified, routed immediately, and never persisted. Ephemeral-by-channel
      is how D5 survives the persist-everything default: mechanism heartbeats
      ride the pulse channel, so they never reach the delta layer.

  **The sink (AC6).** Handler outputs and the daemon's own mechanism claims
  go through one admission point: persist-everything by default; the
  `:pulse_only` knob (a list of kind-marker roles, `--pulse-only` on the
  CLI) tunes specific shapes DOWN to the pulse channel. The knob never
  weakens the door — pulsed shapes are verified by the same
  `Kyber.Store.verify/1` as everything else, and an unsigned delta is
  refused, not pulsed. An output whose id is already in the store is skipped
  (the deterministic ack re-fired in a crash window dedupes by content
  address). Pulse-fired outputs recurse through the sink with a depth cap —
  a handler cycle is refused (`:pulse_depth`), never an infinite loop.

  **The cursor persists as data (AC3).** After a tick that dispatched any
  non-checkpoint claim, the daemon emits a `daemon.checkpoint` claim carrying
  its line position — state as data, an ordinary signed claim in the store.
  On boot the cursor is derived from the highest checkpoint in the replayed
  set (a derived reading, never a source of truth), so a re-boot resumes
  exactly where the previous run stopped and never re-fires. Checkpoint-only
  ticks write no further checkpoint, so the mechanism converges instead of
  checkpointing its own checkpoints.

  **The lock (AC1).** `<log>.lock` beside the log carries the OS pid, acquired
  with an atomic O_EXCL create (no TOCTOU between racing daemons). A
  live foreign pid refuses the second daemon (`{:already_running, path}`); a
  dead, unreadable, or own-pid lock is stale and is retaken — a killed
  daemon must never brick re-boot. The daemon joins the app supervision tree
  (`boot/1`), which is what makes SIGTERM clean: `init:stop` terminates the
  tree, `terminate/2` runs, the lock releases, exit 0.

  A torn line at the log's tail is held, not consumed — it may be a
  concurrent writer's append still in flight; it is retried next tick and
  only counted torn once a later line lands behind it (mid-log torn lines
  are reported and skipped, never repaired — the replay classification).
  """

  use GenServer

  alias Kyber.{AgentLoop, DeltaSet, DurableStore, Gather, Keys, Log, Store, Wire}
  alias Kyber.Agent.{Config, Identity, Profile, Redactor}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @default_tick_ms 250
  @max_pulse_depth 8
  @lock_attempts 3

  @type status :: %{
          cursor: non_neg_integer(),
          author: String.t(),
          log_path: Path.t(),
          fired: non_neg_integer(),
          persisted: non_neg_integer(),
          pulsed: non_neg_integer(),
          skipped: non_neg_integer()
        }

  # ------------------------------------------------------------------ boot

  @doc """
  Start the daemon under the app supervisor — the only placement that gives
  it a graceful terminate (lock release) when SIGTERM's `init:stop` unwinds
  the tree. Options: `:keyring_dir` (required; a missing agent seed is
  minted — first boot IS the mint), `:tick_ms` (positive integer or
  `:manual`, default #{@default_tick_ms}), `:pulse_only` (list of kind-marker
  roles, default `[]` — persist-everything), `:narrate` (boolean, default
  false — one line per dispatch/fire/persist for the operator).

  T14a (the reactor, OPT-IN — the default stays `:ack`, pin 25/H7):
  `:loop` accepts `:reactor` (the reactor owns all five kinds wholesale; the
  daemon's flush forwards cursor deltas to it as `{:ingest, delta}` casts
  with a `:sync` barrier — pin 26), and the reactor boot opts thread through
  untouched: `:oracle_seed` (`:present`/`:absent`, default `:absent` — the
  pin-17 seed assertion), `:budget_cap` (positive integer, default 32),
  `:engine` (keyword | `:none`, default `:none` — the hosted engine's full
  construction surface, H6), `:test_pid` (observation pid for the
  `Ctx.test_pid` probes).
  """
  @spec boot(keyword()) :: {:ok, pid()} | {:error, term()}
  def boot(opts) do
    # T15 (AC1): thread the boot system_prompt into app env so
    # Prompt.system_prompt/0 (assembly path) agrees with LlmHandler
    # (gather path) — both must carry the same persona for a coherent
    # agent. Only override when explicitly supplied; otherwise the pinned
    # kyber default stands. Loop-agnostic: applies to :ack and :reactor.
    case Keyword.get(opts, :system_prompt) do
      sp when is_binary(sp) and sp != "" ->
        Application.put_env(:kyber, :system_prompt, sp)

      _ ->
        # no explicit persona: clear any prior boot's override so the pinned
        # kyber default is restored (prevents a previous agent's persona
        # leaking into a default boot in the same BEAM).
        if Application.get_env(:kyber, :system_prompt) do
          Application.delete_env(:kyber, :system_prompt)
        end
    end

    if Process.whereis(Kyber.Supervisor) do
      case Supervisor.start_child(Kyber.Supervisor, spec(opts)) do
        {:ok, pid} -> {:ok, pid}
        {:error, :already_present} -> replace_child(opts)
        {:error, reason} -> {:error, boot_reason(reason)}
      end
    else
      {:error, :store_not_running}
    end
  end

  @doc "Stop the daemon and drop its child spec. Idempotent."
  @spec stop() :: :ok
  def stop do
    if Process.whereis(Kyber.Supervisor) do
      Supervisor.terminate_child(Kyber.Supervisor, __MODULE__)
      Supervisor.delete_child(Kyber.Supervisor, __MODULE__)
    end

    :ok
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ------------------------------------------------------------------- api

  @doc "Run one dispatch cycle synchronously (the tests' no-sleep drive)."
  @spec tick() :: {:ok, status()}
  def tick, do: GenServer.call(__MODULE__, :tick)

  @doc "The operational shape: cursor, author, log path, counters."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  The sink, public (AC6): admit one wire through the daemon's admission
  policy — persisted by default, pulse-only when its kind-marker role is
  tuned down, skipped when its content address is already in the store,
  refused by the door when invalid.
  """
  @spec emit(map()) :: {:ok, :persisted | :pulsed | :skipped} | {:error, term()}
  def emit(wire), do: GenServer.call(__MODULE__, {:emit, wire})

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    log_path = Application.get_env(:kyber, :log_path)
    keyring_dir = Keyword.fetch!(opts, :keyring_dir)

    with :ok <- guard_store(),
         :ok <- guard_log(log_path),
         # T14i (H7): the channel daemon consumes the SAME boot_context/1
         # helper as attach — `--profile` with an absent/unnamed
         # operator-seed env REFUSES boot ({:error, {:unknown_profile,
         # name}}), never a silent profile-less render with keyed claims
         # minting (AC3)
         :ok <- guard_profile(opts),
         {:ok, seed} <- ensure_agent_seed(keyring_dir),
         :ok <- take_lock(log_path),
         {:ok, channel_socket} <- start_channel_socket(opts, log_path) do
      Process.flag(:trap_exit, true)
      {:ok, gather} = start_gather()

      # `:loop` (T11b + T14a): `:ack` (default) subscribes the T10
      # deterministic ack loop — the fallback, not a casualty (AC9);
      # `:none` leaves "received" to the LLM stack
      # (`Kyber.Agent.attach/1` wires it post-boot); `:reactor` (T14a,
      # OPT-IN — the shipped default stays `:ack`, pin 25/H7) makes the
      # reactor the owner of all five kinds wholesale — the daemon's own
      # gather holds no reactor subscriptions (pin 25's own-container)
      loop = Keyword.get(opts, :loop, :ack)

      if loop == :ack do
        {:ok, _ref} = Gather.subscribe("received", AgentLoop.handler(seed))
      end

      state = %{
        log_path: log_path,
        lock: lock_path(log_path),
        seed: seed,
        author: Keys.author_for_seed(seed),
        gather: gather,
        cursor: checkpoint_cursor(DurableStore.set()),
        tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
        pulse_only: Keyword.get(opts, :pulse_only, []),
        narrate: Keyword.get(opts, :narrate, false),
        loop: loop,
        channel_socket: channel_socket,
        reactor: nil,
        adapter: nil,
        fired: 0,
        persisted: 0,
        pulsed: 0,
        skipped: 0
      }

      state = agent_identity_init(state, opts)

      case loop do
        :reactor ->
          # pin 17: the oracle_seed boot-opt assertion — `:present` appends
          # ONE fixed-content seed delta at boot, signed by the daemon's
          # existing boot key (fixed content => fixed content-derived id =>
          # the two-boot AC5 companion holds). M2: retraction-detection (a
          # negates pointer targeting the seed id) is the gate's closing
          # mechanism — the reactor reads it from store state.
          reactor_opts = reactor_opts(opts, seed)

          with :ok <- assert_oracle_seed(state, opts),
               {:ok, reactor} <- start_reactor(reactor_opts),
               # T15: the federation peer — opens a TCP listener so a sibling
               # agent (e.g. Liet) can import Wisp's signed claims. Only when
               # --peer-port is supplied; absent = no listener (the default).
               {:ok, _peer} <- start_peer(opts),
               # T14i (H9): the gateway adapter — daemon-owned like the
               # socket, one per boot, never in the app tree
               {:ok, adapter} <- start_gateway(state, opts) do
            state = %{state | reactor: reactor, adapter: adapter}
            schedule(state)
            {:ok, state}
          else
            {:error, reason} -> {:stop, reason}
          end

        _ack_or_none ->
          schedule(state)
          {:ok, state}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:tick, _from, state) do
    state = do_tick(state)
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:emit, wire}, _from, state) do
    {result, state} = sink(wire, state, 0)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule(state)
    {:noreply, state}
  end

  # T17 (AC10/AC23): the T16 feed watcher — an `AgentSet` on this daemon's
  # agent hot-swaps the live config AND arms the safety harness; an
  # `AgentRetract` hot-swaps only (never arms — the harness's own rollback
  # retractions must not re-arm it into a loop). Everything else is inert.
  def handle_info({:delta, id, claims}, %{agent: agent} = state) when is_binary(agent) do
    case Kyber.Schema.resolve(claims) do
      %{type: "AgentSet", agent: {:entity, ^agent, _ctx}} = resolved ->
        {:noreply, agent_config_changed(state, id, claims, resolved)}

      %{type: "AgentRetract", agent: {:entity, ^agent, _ctx}} ->
        {:noreply, agent_hot_swap(state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:delta, _id, _claims}, state), do: {:noreply, state}

  # T17 (AC12): engine completion signals, forwarded by the reactor (a
  # send, never a call — pin 26(c)), feed the safety harness.
  def handle_info({:engine, event}, %{agent: agent} = state) when is_binary(agent) do
    {:noreply, agent_engine_event(event, state)}
  end

  def handle_info({:engine, _event}, state), do: {:noreply, state}

  # the gather is link-coupled: if it dies abnormally the daemon stops with
  # it (the supervisor's :transient restart re-inits both)
  def handle_info({:EXIT, pid, reason}, %{gather: pid} = state), do: {:stop, reason, state}
  # the reactor is link-coupled exactly like the gather: an abnormal death
  # stops the daemon (the supervisor's :transient restart re-inits both)
  def handle_info({:EXIT, pid, reason}, %{reactor: pid} = state), do: {:stop, reason, state}
  # the gateway adapter is link-coupled the same way (T14i H9)
  def handle_info({:EXIT, pid, reason}, %{adapter: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    File.rm(state.lock)

    # T14i (H2): the stale <log>.sock is removed under the held lock before
    # bind AND here — a kill -9 leaves the file behind and the next boot's
    # bind fails :eaddrinuse (only File.rm unblocks)
    if is_pid(state.channel_socket) and Process.alive?(state.channel_socket) do
      case :sys.get_state(state.channel_socket) do
        %{path: path} -> File.rm(path)
        _other -> :ok
      end
    end

    :ok
  end

  # ----------------------------------------------------------------- ticks

  defp schedule(%{tick_ms: :manual}), do: :ok
  defp schedule(%{tick_ms: ms}), do: Process.send_after(self(), :tick, ms)

  defp do_tick(state) do
    {consumed, deltas} = collect(state)
    state = %{state | cursor: state.cursor + consumed}

    case state.loop do
      :reactor ->
        # pin 26/H1: under loop: :reactor the flush does NOT route through
        # the daemon's own Gather (which holds no reactor subscriptions);
        # it collects cursor deltas exactly as today and FORWARDS each as an
        # {:ingest, delta} cast — the pin-1 seam — then performs the :sync
        # barrier AFTER the forwarding casts (mailbox ordering: the casts are
        # processed before the :sync reply), so tick returning means the
        # forwarded deltas were ingested. Pin 8's once-per-delta-id routing
        # dedupe drops any delta the push cast already delivered — only
        # genuine log-tail dead letters actually dispatch.
        state = forward_to_reactor(state, deltas)
        state = maybe_checkpoint(deltas, state)
        heartbeat(state)

      _ack_or_none ->
        {outputs, state} = dispatch(deltas, state)
        state = Enum.reduce(outputs, state, fn wire, s -> sink(wire, s, 0) |> elem(1) end)
        state = maybe_checkpoint(deltas, state)
        heartbeat(state)
    end
  end

  # the reactor-mode flush: cast each cursor delta into the reactor (the
  # pin-1 seam), then the sync barrier. The reactor NEVER makes a
  # synchronous call to the daemon (pin 26(c)) — daemon->reactor traffic is
  # casts plus this single :sync call inside tick.
  defp forward_to_reactor(state, deltas) do
    Enum.each(deltas, fn delta ->
      narrate(state, "forwarded #{kind(delta)} #{short(delta.id)}")
      GenServer.cast(Kyber.Agent.Reactor, {:ingest, delta})
    end)

    GenServer.call(Kyber.Agent.Reactor, :sync)
    state
  end

  # the log-channel intake: everything past the cursor, classified exactly
  # like replay (blank consumed; torn mid-log consumed and skipped; torn at
  # the tail HELD for the next tick; door-refused consumed and reported;
  # door-verified handed on)
  defp collect(state) do
    pending = state.log_path |> Log.stream() |> Enum.drop(state.cursor)
    last = length(pending) - 1

    {consumed, deltas} =
      pending
      |> Enum.with_index()
      |> Enum.reduce_while({0, []}, fn {line, i}, {n, acc} ->
        classify_line(line, i == last, {n, acc}, state)
      end)

    {consumed, Enum.reverse(deltas)}
  end

  defp classify_line(line, at_tail?, {n, acc}, state) do
    if String.trim(line) == "" do
      {:cont, {n + 1, acc}}
    else
      case JSON.decode(line) do
        {:error, _} when at_tail? ->
          {:halt, {n, acc}}

        {:error, _} ->
          narrate(state, "torn line skipped")
          {:cont, {n + 1, acc}}

        {:ok, term} ->
          case Store.verify(term) do
            {:ok, delta} ->
              {:cont, {n + 1, [delta | acc]}}

            {:error, reason} ->
              narrate(state, "refused #{inspect(reason)}")
              {:cont, {n + 1, acc}}
          end
      end
    end
  end

  defp dispatch(deltas, state) do
    Enum.map_reduce(deltas, state, fn delta, s ->
      narrate(s, "dispatched #{kind(delta)} #{short(delta.id)}")
      {:ok, report} = Gather.route(delta)
      Enum.each(report.errors, &narrate(s, "handler error #{inspect(&1)}"))
      if report.fired > 0, do: narrate(s, "fired #{kind(delta)} +#{length(report.outputs)}")
      {report.outputs, %{s | fired: s.fired + report.fired}}
    end)
    |> then(fn {outputs, s} -> {List.flatten(outputs), s} end)
  end

  # ------------------------------------------------------------------ sink

  defp sink(_wire, state, depth) when depth > @max_pulse_depth,
    do: {{:error, :pulse_depth}, state}

  defp sink(wire, state, depth) do
    if wire_role(wire) in state.pulse_only do
      pulse(wire, state, depth)
    else
      persist(wire, state)
    end
  end

  defp persist(wire, state) do
    id = wire["id"]

    if is_binary(id) and DeltaSet.member?(DurableStore.set(), id) do
      narrate(state, "skipped #{short(id)}")
      {{:ok, :skipped}, %{state | skipped: state.skipped + 1}}
    else
      case schema_door(wire) do
        :ok ->
          case DurableStore.append(wire) do
            :ok ->
              narrate(state, "persisted #{wire_role(wire)} #{short(id)}")
              {{:ok, :persisted}, %{state | persisted: state.persisted + 1}}

            {:error, reason} ->
              narrate(state, "refused #{inspect(reason)}")
              {{:error, reason}, state}
          end

        {:error, reason} ->
          narrate(state, "refused #{inspect(reason)}")
          {{:error, reason}, state}
      end
    end
  end

  # the door/schema seam (T11b carried addition 1): a delta DECLARING a known
  # lifecycle type is validated against its schema at admission — ill-shaped
  # is refused, never repaired; undeclared/unknown is raw admission. One door
  # for both channels.
  defp schema_door(wire) do
    with {:ok, delta} <- Store.verify(wire) do
      case Kyber.Schema.validate(delta.claims) do
        {:error, reason} -> {:error, {:schema_refused, reason}}
        _typed_or_raw -> :ok
      end
    end
  end

  # the pulse channel: the same door, then route-and-drop; outputs recurse
  # through the sink (a pulse may fire a handler whose output IS memory)
  defp pulse(wire, state, depth) do
    with {:ok, delta} <- Store.verify(wire),
         :ok <- schema_door(wire) do
      {:ok, report} = Gather.route(delta)
      if report.fired > 0, do: narrate(state, "pulse #{kind(delta)} fired +#{report.fired}")

      state =
        Enum.reduce(report.outputs, %{state | pulsed: state.pulsed + 1}, fn w, s ->
          sink(w, s, depth + 1) |> elem(1)
        end)

      {{:ok, :pulsed}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # -------------------------------------------------------- mechanism claims

  # checkpoint only when this tick dispatched something worth remembering —
  # a checkpoint-only tick writes nothing, so the cursor converges
  defp maybe_checkpoint(deltas, state) do
    if Enum.any?(deltas, &(kind(&1) != "checkpoint")) do
      {_result, state} = sink(checkpoint_wire(state), state, 0)
      narrate(state, "checkpoint #{state.cursor}")
      state
    else
      state
    end
  end

  # the heartbeat is ephemeral BY CHANNEL (D5): straight to the pulse path,
  # never through the knob — a signed delta by shape, memory never
  defp heartbeat(state) do
    {_result, state} = pulse(tick_wire(state), state, 0)
    state
  end

  defp checkpoint_wire(state) do
    build_signed(state, [
      %{role: "checkpoint", target: {:entity, "daemon:kyber", "checkpoints"}},
      %{role: "position", target: {:number, state.cursor * 1.0}}
    ])
  end

  defp tick_wire(state) do
    build_signed(state, [%{role: "tick", target: {:entity, "cron:daemon-ticker", "fired"}}])
  end

  defp build_signed(state, pointers), do: build_signed(state, pointers, now_ts())

  # pin 17: the oracle seed's timestamp is FIXED (never now) — the seed's
  # content-derived id must be identical across boots for the two-boot AC5
  # companion (identical seeded commit sequence => identical delta-id sets)
  @oracle_seed_ts 1_700_000_000_000.0

  defp build_signed(state, pointers, ts) do
    raw = %{
      timestamp: ts,
      author: state.author,
      pointers: pointers
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, state.seed)
    Wire.envelope({claims, sig})
  end

  defp now_ts, do: 1.0 * System.system_time(:millisecond)

  # the cursor is derived, never a source of truth: the highest checkpoint
  # position in the replayed set
  defp checkpoint_cursor(set) do
    set
    |> Enum.flat_map(fn {_id, {claims, _sig}} -> checkpoint_position(claims) end)
    |> case do
      [] -> 0
      positions -> positions |> Enum.max() |> trunc()
    end
  end

  defp checkpoint_position(claims) do
    with [%{role: "checkpoint"} | _rest] <- claims.pointers,
         %{target: {:number, n}} <- Enum.find(claims.pointers, &(&1.role == "position")) do
      [n]
    else
      _ -> []
    end
  end

  # ------------------------------------------------------------------ init

  defp guard_store do
    if Process.whereis(DurableStore), do: :ok, else: {:error, :store_not_running}
  end

  # the daemon never runs on an implicit default store: with no configured
  # :log_path (the real-~/.kyber fallback) it refuses — structural enforcement
  # of "the daemon never touches the real store"
  defp guard_log(nil), do: {:error, :no_log_path}
  defp guard_log(path) when is_binary(path), do: :ok

  defp ensure_agent_seed(keyring_dir) do
    case Keys.load_agent_seed(keyring_dir) do
      {:ok, seed} -> {:ok, seed}
      {:error, :no_agent_seed} -> Keys.mint_agent_seed(keyring_dir)
      {:error, _reason} = err -> err
    end
  end

  defp start_gather do
    case Gather.start_link() do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Process.link(pid)
        {:ok, pid}
    end
  end

  # T14a (H3): the reactor boot path. Started only under loop: :reactor; the
  # boot opts budget_cap:/engine:/test_pid are threaded UNTOUCHED to the
  # reactor (pins 12/21, H6). T14c (D6): :operator_seed (caller-resolved
  # hex — the daemon loads no keyring itself) rides the same whitelist,
  # which would otherwise drop the opt before Reactor.start_link.
  defp reactor_opts(opts, seed) do
    llm_opts = [
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt)
    ]

    # an explicit engine: opt (e.g. a test-injected stub) wins; otherwise
    # build one from the daemon's llm opts so a :reactor boot actually runs
    # the model (defaulting to :none here would leave delegate_to_engine
    # with a nil engine and never call the model).
    engine =
      case Keyword.get(opts, :engine) do
        nil -> build_daemon_engine(seed, llm_opts)
        explicit -> explicit
      end

    # engine may be {:error, reason} if LlmHandler construction failed (e.g.
    # no api key resolved from --api-key-env). Rather than booting a reactor
    # with a dead engine that silently answers nothing, we still boot but
    # warn LOUDLY so the operator knows the daemon cannot actually run the
    # model. See ADLC P5 (PR #5), round 4 medium-severity finding: the prior
    # :none path was silent. Fail-fast (returning {:error, :no_api_key}) would
    # break the many degraded-reactor boots used to exercise the socket /
    # attestation paths; a loud warning keeps the suite honest without that
    # blast radius.
    engine =
      case engine do
        {:error, :no_api_key} ->
          Logger.warning(
            "kyber: daemon booting :reactor loop without an api key — the engine " <>
              "is disabled and the model will not run. Pass --api-key-env (or " <>
              "engine: in opts) to enable inference."
          )

          :none

        {:error, other} ->
          Logger.warning(
            "kyber: engine construction failed (#{inspect(other)}); reactor boots without a model"
          )

          :none

        ok ->
          ok
      end

    [
      seed: seed,
      budget_cap: Keyword.get(opts, :budget_cap, 32),
      engine: engine,
      test_pid: Keyword.get(opts, :test_pid),
      operator_seed: Keyword.get(opts, :operator_seed),
      # T14i (D3 — the threading): :profile rides the same whitelist into
      # Reactor.start_link, where the boot_context helper resolves the
      # engine's :boot tuple and the H8 intersect
      profile: Keyword.get(opts, :profile),
      # T15: model/provider identity for an isolated sibling agent (Wisp).
      # llm_for/2 threads these to LlmHandler.new; absent => k3 defaults.
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      peer_port: Keyword.get(opts, :peer_port)
    ]
  end

  # builds the engine opt list [llm: llm, tools: []] from daemon llm opts.
  # Returns {:error, reason} if LlmHandler construction fails (e.g. no
  # api key), so the caller can fail the boot loudly instead of starting a
  # reactor with a dead engine.
  defp build_daemon_engine(seed, llm_opts) do
    case Kyber.Agent.Reactor.llm_for(seed, llm_opts) do
      {:ok, llm} -> [llm: llm, tools: []]
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_reactor(opts) do
    case Kyber.Agent.Reactor.start_link(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Process.link(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # T15: federation peer — opens a TCP listener (Kyber.Peer) when --peer-port
  # is set, so a sibling agent can import this one's signed claims. Absent
  # port => no listener (the default; most boots don't federate).
  defp start_peer(opts) do
    case Keyword.get(opts, :peer_port) do
      nil -> {:ok, nil}
      port when is_integer(port) -> Kyber.Peer.start_link(port: port)
    end
  end

  # pin 17: the oracle_seed assertion — :present appends ONE fixed-content
  # seed delta (fixed timestamp + fixed pointers, signed by the daemon's
  # boot key) so its content-derived id is deterministic across boots; the
  # reactor's gate reads it from store state. :absent (the default) appends
  # nothing. A failed append refuses the boot.
  defp assert_oracle_seed(state, opts) do
    case Keyword.get(opts, :oracle_seed, :absent) do
      :present ->
        wire =
          build_signed(
            state,
            [%{role: "seed", target: {:entity, "oracle", "seed"}}],
            @oracle_seed_ts
          )

        case DurableStore.append(wire) do
          :ok -> :ok
          {:error, reason} -> {:error, {:oracle_seed, reason}}
        end

      :absent ->
        :ok
    end
  end

  # D6: the hot path keeps the oracle gate consistent with the fold. The
  # gate is a pure store read (reactor pin 16: open iff an unretracted seed
  # claim exists), so the flip is a delta operation — never reactor state:
  # fold wants :present with no live seed => append one (the boot shape;
  # the fixed ts unless a retracted seed already holds that content id, in
  # which case a fresh ts mints a new claim the dedup can't absorb); fold
  # wants :absent with a live seed => append its negation (retraction-is-
  # negation, the store only learns). A gate already matching the fold
  # appends nothing. Takes effect on the next dispatch — the next
  # inference cycle, no reboot.
  defp sync_oracle_gate(state, fold_opts) do
    # the fold DECLARES the gate only when it sets `oracle_seed` explicitly:
    # boot_opts/2 rejects nil values, so an ABSENT key means "the fold never
    # spoke about the gate" — the boot state stands (the operator's boot flag
    # or the boot-time assert stays). Only an explicit fold value syncs.
    case Keyword.fetch(fold_opts, :oracle_seed) do
      :error ->
        :ok

      {:ok, want} ->
        {live_id, any_seed?} = seed_claim_state(DurableStore.set())

        cond do
          want == :present and live_id == nil ->
            ts = if any_seed?, do: now_ts(), else: @oracle_seed_ts
            wire = build_signed(state, [%{role: "seed", target: {:entity, "oracle", "seed"}}], ts)

            case DurableStore.append(wire) do
              :ok -> narrate(state, "oracle gate open via config hot-swap")
              {:error, reason} -> narrate(state, "oracle gate open refused #{inspect(reason)}")
            end

          want == :absent and live_id != nil ->
            wire =
              build_signed(state, [%{role: "negates", target: {:delta, live_id, "retracted"}}])

            case DurableStore.append(wire) do
              :ok -> narrate(state, "oracle gate closed via config hot-swap")
              {:error, reason} -> narrate(state, "oracle gate close refused #{inspect(reason)}")
            end

          true ->
            :ok
        end
    end
  end

  # {live unretracted seed claim id | nil, any seed claim at all?} — the
  # second element tells the re-open path the fixed-content boot id is
  # already taken by a retracted claim
  defp seed_claim_state(set) do
    retracted =
      for {_id, {claims, _sig}} <- set,
          %{role: "negates", target: {:delta, target, _ctx}} <- claims.pointers,
          into: MapSet.new(),
          do: target

    seeds =
      for {id, {claims, _sig}} <- set,
          match?([%{role: "seed"} | _rest], claims.pointers),
          do: id

    {Enum.find(seeds, &(not MapSet.member?(retracted, &1))), seeds != []}
  end

  # ------------------------------------------------------------------ T14i

  # H7: the channel daemon boot consumes the SAME boot_context/1 helper as
  # attach (agent.ex:103; {_name, nil} -> {:error, {:unknown_profile, name}}):
  # `--profile` with an absent/unnamed operator-seed env REFUSES boot; an
  # unknown profile name refuses with the same reason.
  defp guard_profile(opts) do
    case Profile.boot_context(
           profile: Keyword.get(opts, :profile),
           operator_seed: Keyword.get(opts, :operator_seed)
         ) do
      {:ok, _boot} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # D6/H2: the daemon-owned channel socket. Under the HELD lock the stale
  # <log>.sock is File.rm'd BEFORE bind (a kill -9 leaves it behind and the
  # next bind fails :eaddrinuse — only File.rm unblocks); :default resolves
  # to <log>.sock (the discovery file IS the socket); nil = disabled.
  defp start_channel_socket(opts, log_path) do
    case Keyword.get(opts, :channel_socket) do
      nil ->
        {:ok, nil}

      :default ->
        do_start_channel_socket(log_path <> ".sock", opts)

      path when is_binary(path) ->
        do_start_channel_socket(path, opts)
    end
  end

  defp do_start_channel_socket(path, opts) do
    File.rm(path)

    case Kyber.Channel.Socket.start_link(
           socket_path: path,
           log_path: Application.get_env(:kyber, :log_path),
           operator_seed: Keyword.get(opts, :operator_seed)
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:channel_socket, reason}}
    end
  end

  # H9: the gateway adapter — daemon-owned, one per boot, never in the app
  # tree. The per-server seed derives from the operator seed (M4); the token
  # rides the delivery seam as a CLOSURE (M12 — outside inspectable state);
  # a gateway without an operator seed is fail-closed (the CLI's
  # profile-mandatory refusal already guards the surface).
  defp start_gateway(_state, opts) do
    case Keyword.get(opts, :gateway) do
      nil ->
        {:ok, nil}

      gw ->
        operator_seed = Keyword.get(opts, :operator_seed)

        if is_nil(operator_seed) do
          {:error, {:unknown_profile, Keyword.get(opts, :profile)}}
        else
          server_id = Keyword.fetch!(gw, :server_id)
          server_seed = Keys.derive_seed(operator_seed, "kyber:discord-server:" <> server_id)

          adapter_opts = [
            server: server_id,
            seed: server_seed,
            token_holder: Keyword.get(gw, :token, fn -> nil end),
            intents: Keyword.get(gw, :intents, 33_280),
            url: Keyword.get(gw, :url, "wss://gateway.discord.gg/?v=10&encoding=json"),
            transport: {Kyber.Channel.Transport.Ws, %{}},
            delivery: {Kyber.Channel.Delivery.Httpc, %{}}
          ]

          case Kyber.Channel.Adapter.start_link(adapter_opts) do
            {:ok, pid} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # ------------------------------------------------------- T17 agent identity

  # Agent mode (`agent:` boot opt): subscribe to the T16 feed, fold the
  # AgentSet stream into the state, mint the soul (AC6), and carry the
  # harness/rollback state. Non-agent boots get `agent: nil` and every T17
  # clause is inert.
  defp agent_identity_init(state, opts) do
    case Keyword.get(opts, :agent) do
      nil ->
        Map.put(state, :agent, nil)

      agent when is_binary(agent) ->
        # subscribe BEFORE the fold: a delta landing between the two is both
        # folded and re-delivered — the hot-swap re-fold is idempotent
        :ok = DurableStore.subscribe(self())

        state
        |> Map.merge(%{
          agent: agent,
          operator_seed: Keyword.get(opts, :operator_seed),
          overrides: Keyword.get(opts, :overrides, []),
          rollback_threshold: Keyword.get(opts, :rollback_threshold, 2),
          fold_view: agent_fold(agent),
          live: %{
            model: Keyword.get(opts, :model),
            base_url: Keyword.get(opts, :base_url)
          },
          boot_api_key: Keyword.get(opts, :api_key),
          armed: nil,
          failures: 0,
          rollbacks: 0,
          redact: Enum.filter([Keyword.get(opts, :api_key)], &is_binary/1)
        })
        |> mint_soul()
    end
  end

  defp agent_fold(agent) do
    case Config.resolve(DurableStore.set(), agent) do
      {:ok, view} -> view
      :not_found -> nil
    end
  end

  # AC6: boot mints `identity:soul` from the fold's soul — IDEMPOTENT (a
  # live soul head is never re-minted, and the mint's timestamp is the soul
  # head delta's own, so a raced double-mint collapses to one content
  # address). Signed by the operator seed: the identity fold is author-
  # filtered to the operator (H2), so an agent-signed mint would be inert.
  defp mint_soul(%{fold_view: %{soul: soul} = view, operator_seed: seed} = state)
       when is_binary(soul) and is_binary(seed) do
    set = DurableStore.set()

    case Identity.primitive(set, Keys.author_for_seed(seed), "soul") do
      {:ok, _live} ->
        state

      :not_found ->
        ts = soul_head_ts(set, view)
        {:ok, signed} = AgentEvents.identity_set(seed, ts, "identity:soul", "soul", soul)

        case DurableStore.append(Wire.envelope(signed)) do
          :ok -> narrate(state, "minted identity:soul from the #{state.agent} fold")
          {:error, reason} -> narrate(state, "soul mint refused #{inspect(reason)}")
        end

        state
    end
  end

  defp mint_soul(state), do: state

  defp soul_head_ts(set, view) do
    case set[view.heads[:soul]] do
      {claims, _sig} -> claims.timestamp
      nil -> now_ts()
    end
  end

  # an AgentSet on this agent: hot-swap, then ARM the harness — the source
  # classification (operator vs agent author) decides rollback-vs-detection
  # when the next inference fails config-class (AC12)
  defp agent_config_changed(state, id, claims, resolved) do
    state = agent_hot_swap(state)

    source =
      case state.fold_view do
        %{operator_author: author} when author == claims.author -> :operator
        _other -> :agent
      end

    fields = agent_delta_fields(resolved)
    %{state | armed: %{source: source, id: id, fields: fields}, failures: 0}
  end

  defp agent_delta_fields(resolved) do
    sets = for field <- Config.fields(), Map.get(resolved, field) != nil, do: field

    unsets =
      for name <- Map.get(resolved, :unset, []),
          field = Enum.find(Config.fields(), &(Atom.to_string(&1) == to_string(name))),
          do: field

    Enum.uniq(sets ++ unsets)
  end

  # the hot-swap (AC10/AC23): re-fold, re-apply the boot OVERRIDES last
  # (pinned across every re-fold), rebuild the handler through the SAME
  # llm_for/2 boot path (absent fields land on the engine's deepseek
  # defaults — the terminal step-back state), and swap it into the live
  # engine. Only a :reactor loop has an engine to swap.
  defp agent_hot_swap(%{loop: :reactor} = state) do
    view = agent_fold(state.agent)
    state = %{state | fold_view: view}
    fold_opts = if view, do: Config.boot_opts(view, state.overrides), else: state.overrides
    sync_oracle_gate(state, fold_opts)

    with {:ok, api_key} <- agent_swap_key(fold_opts[:api_key], state),
         llm_opts =
           [
             api_key: api_key,
             base_url: fold_opts[:base_url],
             model: fold_opts[:model],
             system_prompt: fold_opts[:system_prompt]
           ]
           |> Enum.reject(fn {_k, v} -> is_nil(v) end),
         {:ok, handler} <- Kyber.Agent.Reactor.llm_for(state.seed, llm_opts),
         changes = Map.take(handler, [:model, :base_url, :system_prompt, :api_key]),
         :ok <- Kyber.Agent.Reactor.swap_llm_config(changes) do
      narrate(state, "config hot-swap #{state.agent}: model #{handler.model}")

      %{
        state
        | live: %{model: handler.model, base_url: handler.base_url},
          redact: Enum.uniq(Enum.filter([api_key | state.redact], &is_binary/1))
      }
    else
      {:error, reason} ->
        narrate(state, "config hot-swap failed #{inspect(reason)}")
        agent_failure(state, reason)
    end
  end

  defp agent_hot_swap(state), do: %{state | fold_view: agent_fold(state.agent)}

  # the tagged key resolves to a VALUE only here, at the swap boundary; a
  # fold with no key falls back to the boot-resolved key (the engine keeps
  # running rather than losing its credential to an unrelated re-fold)
  defp agent_swap_key({:env, name}, state) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _unset -> {:error, {:agent_key_missing, state.agent, name}}
    end
  end

  defp agent_swap_key({:enc, ciphertext}, state) do
    case state.operator_seed do
      nil ->
        {:error, {:decrypt_failed, state.agent}}

      seed ->
        case Kyber.Agent.Secrets.decrypt(ciphertext, seed) do
          {:ok, value} -> {:ok, value}
          {:error, _reason} -> {:error, {:decrypt_failed, state.agent}}
        end
    end
  end

  defp agent_swap_key(nil, state), do: {:ok, state.boot_api_key}

  # AC12: the harness. `answered` resets the consecutive counter; a
  # config-class llm error counts (transient neither counts nor resets).
  defp agent_engine_event({:llm_error, reason}, state) do
    if config_class?(reason), do: agent_failure(state, reason), else: state
  end

  defp agent_engine_event({:answered, _request_id}, state), do: %{state | failures: 0}
  defp agent_engine_event(_event, state), do: state

  # the EXPLICIT classifier (premortem fold): 400/401/404, refused/unknown
  # host binds, missing key env, decrypt failures are CONFIG-CLASS;
  # 429/5xx/timeouts and everything unrecognized are TRANSIENT (conservative
  # default — a brownout destroys no good deltas).
  defp config_class?({:llm_http, status, _body}) when status in [400, 401, 404], do: true
  defp config_class?({:llm_transport, reason}) when reason in [:econnrefused, :nxdomain], do: true
  defp config_class?({:agent_key_missing, _agent, _env}), do: true
  defp config_class?({:decrypt_failed, _agent}), do: true
  defp config_class?(_reason), do: false

  # no operator seed => the harness cannot sign a retraction: detection only
  defp agent_failure(%{operator_seed: nil} = state, _reason), do: state

  defp agent_failure(state, reason) do
    case state.armed do
      %{source: :agent} = armed ->
        failures = state.failures + 1

        if failures >= state.rollback_threshold do
          agent_rollback(state, armed, reason)
        else
          %{state | failures: failures}
        end

      %{source: :operator} ->
        narrate(
          state,
          "config-class failure after an OPERATOR delta (#{inspect(reason)}) — " <>
            "detection only, no auto-retract (run `kyber agent retract` to step back)"
        )

        state

      nil ->
        state
    end
  end

  # the bounded, per-FIELD step-back: retract exactly the AGENT-authored
  # deltas that last set the armed fields (an operator head is NEVER
  # auto-retracted), then the ConfigRollback notification. The feed then
  # re-delivers the retractions and the hot-swap restores the live engine.
  defp agent_rollback(state, armed, reason) do
    set = DurableStore.set()
    operator_author = with %{operator_author: author} <- state.fold_view, do: author

    offends =
      armed.fields
      |> Enum.map(&(state.fold_view && state.fold_view.heads[&1]))
      |> Enum.filter(& &1)
      |> Enum.uniq()
      |> Enum.filter(fn head_id ->
        case set[head_id] do
          {claims, _sig} -> claims.author != operator_author
          nil -> false
        end
      end)

    case offends do
      [] ->
        %{state | armed: nil, failures: 0}

      _offending ->
        ts = now_ts()

        Enum.each(offends, fn target_id ->
          {:ok, signed} =
            AgentEvents.agent_retract(state.operator_seed, ts, state.agent, target_id)

          DurableStore.append(Wire.envelope(signed))
        end)

        restored = Enum.map(armed.fields, &Atom.to_string/1)

        {:ok, rollback} =
          AgentEvents.config_rollback(
            state.operator_seed,
            ts + 1.0,
            state.agent,
            "config-class failure: #{inspect(reason)}",
            offends,
            restored
          )

        DurableStore.append(Wire.envelope(rollback))

        narrate(
          state,
          "config rollback #{state.agent}: retracted #{length(offends)} delta(s), " <>
            "restored #{Enum.join(restored, ", ")}"
        )

        %{state | armed: nil, failures: 0, rollbacks: state.rollbacks + 1}
    end
  end

  defp fold_summary(nil), do: nil
  defp fold_summary(view), do: Map.take(view, [:model, :base_url, :soul, :self_config])

  # ------------------------------------------------------------------ lock

  defp lock_path(log_path), do: log_path <> ".lock"

  defp take_lock(log_path) do
    do_take_lock(lock_path(log_path), @lock_attempts)
  end

  defp do_take_lock(_lock, 0), do: {:error, {:lock_failed, :contended}}

  # O_EXCL create: the exists-check and the create are ONE atomic operation —
  # no TOCTOU between two racing daemons (the sibling review's finding, folded
  # in post-verdict). A held lock is reclaimed only when its pid is provably
  # dead; a killed daemon must never brick re-boot.
  defp do_take_lock(lock, attempts) do
    case File.open(lock, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        with :ok <- IO.binwrite(io, System.pid()), :ok <- File.close(io) do
          :ok
        else
          {:error, reason} -> {:error, {:lock_failed, reason}}
        end

      {:error, :eexist} ->
        # stale, garbage, or our own pid: reclaim (dead, unreadable, or a
        # live foreign pid must refuse, not be presumed dead)
        if lock_held_by_live_pid?(lock) do
          {:error, {:already_running, Path.rootname(lock, ".lock")}}
        else
          File.rm(lock)
          do_take_lock(lock, attempts - 1)
        end

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end

  defp lock_held_by_live_pid?(lock) do
    case File.read(lock) do
      {:ok, content} ->
        # our own OS pid = a crash-restart of a daemon in THIS VM (the old
        # instance died; the lock is ours to retake) — only a FOREIGN live
        # pid refuses the second daemon
        pid = String.trim(content)
        pid != System.pid() and os_pid_alive?(pid)

      {:error, _unreadable} ->
        false
    end
  end

  # `ps -p` rather than `kill -0`: a pid we may not signal (EPERM) is still
  # alive, and a live foreign daemon must refuse, not be presumed dead
  defp os_pid_alive?(pid_text) do
    case Integer.parse(pid_text) do
      {n, ""} when n > 0 ->
        match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(n)], stderr_to_stdout: true))

      _ ->
        false
    end
  end

  # -------------------------------------------------------------- machinery

  defp spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  # a previously stopped daemon leaves its spec behind; replace it so new
  # options (tick, knob) take effect on re-boot
  defp replace_child(opts) do
    Supervisor.delete_child(Kyber.Supervisor, __MODULE__)

    case Supervisor.start_child(Kyber.Supervisor, spec(opts)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, boot_reason(reason)}
    end
  end

  defp boot_reason({:already_started, _pid}),
    do: {:already_running, Application.get_env(:kyber, :log_path)}

  # start_child wraps an init failure as {reason, child_record}
  defp boot_reason({reason, child}) when is_tuple(child) and elem(child, 0) == :child,
    do: boot_reason(reason)

  defp boot_reason(reason), do: reason

  # T17 (AC23): agent mode exposes the FOLD value and the LIVE value
  # DISTINCTLY (they can never silently disagree) plus the rollback counter
  # (AC12 surfacing). JSON-safe scalars only — never the tagged api_key.
  defp status_map(%{agent: agent} = state) when is_binary(agent) do
    state
    |> Map.take([:cursor, :author, :log_path, :fired, :persisted, :pulsed, :skipped])
    |> Map.merge(%{
      agent: agent,
      rollbacks: state.rollbacks,
      config: %{fold: fold_summary(state.fold_view), live: state.live}
    })
  end

  defp status_map(state) do
    Map.take(state, [:cursor, :author, :log_path, :fired, :persisted, :pulsed, :skipped])
  end

  defp kind(%{claims: %{pointers: [%{role: role} | _rest]}}), do: role

  defp wire_role(%{"claims" => %{"pointers" => [%{"role" => role} | _rest]}})
       when is_binary(role),
       do: role

  defp wire_role(_wire), do: nil

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(_id), do: "?"

  # T17 (AC19): the narration path redacts every configured key VALUE (known
  # from the boot/swap closures) — an error message never echoes a key
  defp narrate(%{narrate: true} = state, message), do: IO.puts(redact_line(state, message))
  defp narrate(_state, _message), do: :ok

  defp redact_line(%{redact: [_ | _] = values}, message), do: Redactor.redact(message, values)
  defp redact_line(_state, message), do: message
end
