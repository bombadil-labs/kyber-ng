defmodule Kyber.Agent.ReactorTest do
  @moduledoc """
  T14a — the reactor (AC1/AC2/AC3/AC5; AC4 lives in
  reactor_operational_test.exs). The reactor makes the agent fire on
  deltas: a store delta whose kind matches a subscription routes to its
  handler WITHOUT a manual tick; per-turn budgets constrain the turn; model
  initiation is gated by the Oracle seed.

  Anti-placebo discipline (pins 18–21): every test boots a tmp store + tmp
  keyring with `tick_ms: :manual` — no background loop exists; NO test ever
  calls `Daemon.tick/0` (the reactor fires on the store's post-commit
  ingest cast); the red leg (`loop: :ack`) proves that a manual-tick daemon
  WITHOUT the reactor dispatches nothing — assert_receive times out AND the
  store effect is absent.
  """

  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Keys, Schema, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)

  # the no-tick tripwire (pin 18): P1's test-LOCAL raising tick guard,
  # implemented test-side with ZERO new daemon surface — any test in this
  # file that ever needs a flush must use this and gets a loud raise
  # instead of silently ticking (the reactor fires on deltas; a tick would
  # be a placebo escape hatch)
  defmodule NoTickGuard do
    def tick,
      do: raise("reactor_test.exs must never call Daemon.tick/0 — the reactor fires on deltas")
  end

  # ------------------------------------------------ the T5/T6/T7/T8 lifecycle
  # (mirrors daemon_test): isolated store per test on a fresh tmp log_path,
  # own tmp keyring; the real ~/.kyber is never touched; ticks manual.
  setup_all do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)
    assert is_binary(keyring_dir)
    assert is_binary(config_log_path)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
    end)

    {:ok, keyring_dir: keyring_dir}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp fresh_dir(base, tag) do
    Path.join(
      base,
      "kyber-reactor-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  setup %{keyring_dir: keyring_dir} do
    key_dir = fresh_dir(keyring_dir, "keyring")
    File.mkdir_p!(key_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed, log_path: log_path}
  end

  # ---------------------------------------------------------------- helpers

  # the pinned deterministic boot shape (pin 21): loop: :reactor,
  # oracle_seed: :present, budget_cap: <per-test>, tick_ms: :manual
  defp boot_daemon!(ctx, opts \\ []) do
    boot_opts =
      Keyword.merge(
        [
          keyring_dir: ctx.keyring_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          budget_cap: 32,
          test_pid: self()
        ],
        opts
      )

    assert {:ok, pid} = Daemon.boot(boot_opts)
    pid
  end

  # a fixed "received" delta: fixed content + fixed timestamp => fixed id
  defp received_wire(ts, msg_id, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:reactor",
        "session:reactor",
        content
      )

    Wire.envelope(signed)
  end

  defp signed_wire(seed, pointers, ts) do
    raw = %{timestamp: ts, author: Keys.author_for_seed(seed), pointers: pointers}
    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, seed)
    Wire.envelope({claims, sig})
  end

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  # the store proof: probe claims for ONE delta (per-invocation-distinct —
  # the probe embeds the delta id + invocation index, so a double dispatch
  # yields TWO claims, never one)
  defp probe_claims(set, delta_id) do
    set
    |> Enum.filter(fn {_id, {claims, _sig}} ->
      kind(claims) == "probe" and is_binary(probe_marker(claims)) and
        probe_marker(claims) =~ delta_id
    end)
    |> Enum.map(fn {id, {claims, _sig}} -> {id, claims} end)
  end

  # the probe's marker rides the "probe" role target: "dispatch:<id>#<index>"
  defp probe_marker(%{pointers: pointers}) do
    case Enum.find(pointers, &(&1.role == "probe")) do
      %{target: {:string, marker}} -> marker
      _other -> nil
    end
  end

  # bounded sleep-free store polling (the no-sleep idiom: a timeout-only
  # receive never matches mailbox messages, so it cannot swallow probes)
  defp poll_store(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Enum.find(DurableStore.set(), pred) do
        nil ->
          receive do
          after
            25 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end

  defp seed_claim(set) do
    Enum.find(set, fn {_id, {claims, _sig}} -> kind(claims) == "seed" end)
  end

  # ------------------------------------------------------------------- AC1

  test "AC1 anti-placebo (red leg): a manual-tick daemon WITHOUT the reactor dispatches nothing",
       ctx do
    # boot loop: :ack — the reactor does not exist under this loop;
    # tick_ms: :manual — no background loop. oracle_seed: :present is a
    # legal opt. Append a fixed "received" delta. NEVER tick.
    boot_daemon!(ctx, loop: :ack, oracle_seed: :present)

    wire = received_wire(1_754_600_000_000, "message:reactor:anti", "never fires")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)

    # the append landed — the delta IS in the store...
    assert Map.has_key?(DurableStore.set(), received_id)

    # ...but nothing dispatched: assert_receive would time out and the
    # store effect (the probe claim) is absent
    refute_receive {:reactor, {:dispatch, "received", _id}}, 300
    set = DurableStore.set()
    assert probe_claims(set, received_id) == []
  end

  test "AC1: a delta of a subscribed kind fires its handler WITHOUT a manual tick", ctx do
    boot_daemon!(ctx)

    wire = received_wire(1_754_600_000_000, "message:reactor:ac1", "fire without a tick")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)

    # the fast signal: one dispatch probe, no tick anywhere in this file
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    set = DurableStore.set()

    # the store proof (primary — AC1: "provable from store state"): exactly
    # ONE probe claim for this delta — a double dispatch would produce two
    # (per-invocation-distinct), so count == 1 proves exactly-once
    probes = probe_claims(set, received_id)
    assert length(probes) == 1

    # the handler's emitted delta is in the store: the InferenceRequested
    # pointing at the received claim
    assert Enum.any?(set, fn {_id, {claims, _sig}} ->
             kind(claims) == "promptRef" and
               pointer(claims, "promptRef") == {:delta, received_id, "requested"}
           end)

    # the probe claims the dispatched delta's timestamp (AC5: no wall-clock
    # in the reactor's decision surface)
    [{_probe_id, probe_claims_map}] = probes
    assert probe_claims_map.timestamp == 1_754_600_000_000.0

    # exactly-once (secondary): no second probe for the same delta
    refute_receive {:reactor, {:dispatch, "received", ^received_id}}, 300

    # the secondary signal: the reactor counted exactly this invocation
    state = :sys.get_state(Kyber.Agent.Reactor)
    assert state.invocation_count >= 1
  end

  test "AC1: an unsubscribed-kind delta is :ignore — never an error, never a probe (negative control)",
       ctx do
    boot_daemon!(ctx)

    # a "note" delta — not one of the five subscribed kinds
    {:ok, agent_seed} = Keys.load_agent_seed(ctx.keyring_dir)

    wire =
      signed_wire(
        agent_seed,
        [%{role: "note", target: {:string, "negative control"}}],
        1_754_600_000_000.0
      )

    assert :ok = DurableStore.append(wire)

    refute_receive {:reactor, {:dispatch, "note", _id}}, 300

    set = DurableStore.set()
    assert probe_claims(set, wire["id"]) == []
    assert Map.has_key?(set, wire["id"])
  end

  # ------------------------------------------------------------------- AC2

  test "AC2: a turn exceeding its budget terminates cleanly with exactly one refusal delta",
       ctx do
    # the tiny cap the override exists for (pin 12)
    boot_daemon!(ctx, budget_cap: 1)

    wire = received_wire(1_754_600_000_000, "message:reactor:ac2", "budget me")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)

    # a charge landing exactly on max succeeds (pin 10): the received
    # dispatch fires (charge 1 == cap)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    # the handler's emission: the InferenceRequested (charged to the
    # emitting turn) — already in the store when the received probe lands
    set = DurableStore.set()

    {request_id, {request_claims, _sig}} =
      Enum.find(set, fn {_id, {claims, _sig}} ->
        kind(claims) == "promptRef" and
          pointer(claims, "promptRef") == {:delta, received_id, "requested"}
      end)

    # the promptRef dispatch check refuses (2 > 1) BEFORE dispatch — no
    # probe for it — and emits ONE budget GateDecision (the refusal delta)
    {_gd_id, {gd_claims, _sig}} =
      poll_store(fn {_id, {claims, _sig}} -> kind(claims) == "decides" end)

    assert gd_claims != nil

    typed = Schema.resolve(gd_claims)
    assert typed.type == "GateDecision"
    assert typed.verdict == "refuse"
    assert typed.policy == "budget"
    assert typed.decides == {:delta, request_id, "decided"}

    # M2/M3: the refusal delta claims the refused delta's timestamp — no
    # wall-clock in the reactor's decision surface (AC5)
    assert gd_claims.timestamp == request_claims.timestamp

    # exactly one refusal delta, finite store, no live-lock, no hang (pin
    # 7/10: the turn end is STRUCTURAL — a refused "decides" emits nothing)
    final_set = DurableStore.set()
    assert length(for {_id, {claims, _sig}} <- final_set, kind(claims) == "decides", do: 1) == 1

    # no model answer anywhere (the chain never reached the engine)
    refute Enum.any?(final_set, fn {_id, {claims, _sig}} -> kind(claims) == "requestRef" end)

    # the mailbox-empty class of failure is excluded by construction: after
    # the refusal nothing else dispatches (refuse-receive, never sleep)
    refute_receive {:reactor, {:dispatch, _kind, _id}}, 300

    # the finite store: seed + received + request + refusal + probe == 5
    assert map_size(final_set) == 5
  end

  # ------------------------------------------------------------------- AC3

  test "AC3: without the oracle seed, model initiation is refused and the refusal routes as a GateDecision",
       ctx do
    boot_daemon!(ctx, oracle_seed: :absent)

    wire = received_wire(1_754_600_000_000, "message:reactor:ac3", "gate me")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)

    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    # the refusal GateDecision is in the store, routed as "decides"
    {_gd_id, {gd_claims, _sig}} =
      poll_store(fn {_id, {claims, _sig}} -> kind(claims) == "decides" end)

    assert gd_claims != nil

    typed = Schema.resolve(gd_claims)
    assert typed.verdict == "refuse"
    assert typed.policy == "oracle_gate"
    assert typed.decides == {:delta, received_id, "decided"}
    assert gd_claims.timestamp == 1_754_600_000_000.0

    # the decides-dispatch probe: the closed refusal loop's entry, exercised
    # THROUGH the reactor (with a hosted engine this reaches the model)
    assert_receive {:reactor, {:dispatch, "decides", _gd_id}}, 2_000

    # NO model initiation: no InferenceRequested, no ResponseDelta, no
    # engine at all (engine: :none — no code path can construct an HTTP
    # client, pin 6/H6)
    set = DurableStore.set()
    refute Enum.any?(set, fn {_id, {claims, _sig}} -> kind(claims) == "promptRef" end)
    refute Enum.any?(set, fn {_id, {claims, _sig}} -> kind(claims) == "requestRef" end)
    refute_receive {:reactor, {:dispatch, "promptRef", _}}, 300
  end

  test "AC3: a retracted seed closes the gate (retraction-is-negation, pin 16)", ctx do
    boot_daemon!(ctx)

    {seed_id, _seed_claims} = seed_claim(DurableStore.set())
    assert is_binary(seed_id)

    # a negation delta targeting the seed id — the gate's closing mechanism
    {:ok, agent_seed} = Keys.load_agent_seed(ctx.keyring_dir)

    neg =
      signed_wire(
        agent_seed,
        [%{role: "negates", target: {:delta, seed_id, "retracted"}}],
        1_754_600_000_000.0
      )

    assert :ok = DurableStore.append(neg)

    wire = received_wire(1_754_600_100_000, "message:reactor:ac3r", "gate retracted")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)

    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    # the gate is closed: the refusal routes as a GateDecision (oracle_gate)
    assert_receive {:reactor, {:dispatch, "decides", gd_id}}, 2_000
    {gd_claims, _sig} = Map.get(DurableStore.set(), gd_id)
    typed = Schema.resolve(gd_claims)
    assert typed.verdict == "refuse"
    assert typed.policy == "oracle_gate"
    assert typed.decides == {:delta, received_id, "decided"}
  end

  test "AC3: the directly-written promptRef bypass is closed — promptRef is gated too", ctx do
    boot_daemon!(ctx, oracle_seed: :absent)

    # a real received (its turn exists), then a DIRECTLY-appended
    # InferenceRequested pointing at it — the A2-conceded bypass
    wire = received_wire(1_754_600_000_000, "message:reactor:ac3p", "bypass me")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    {:ok, agent_seed} = Keys.load_agent_seed(ctx.keyring_dir)

    {:ok, signed} =
      AgentEvents.inference_requested(
        agent_seed,
        1_754_600_100_000,
        "kimi-k3",
        "session:reactor",
        "conversation:ref",
        received_id,
        []
      )

    request_wire = Wire.envelope(signed)
    request_id = request_wire["id"]
    assert :ok = DurableStore.append(request_wire)

    # the promptRef handler's FIRST line is the gate check (pin 14): closed
    # => refuse, never a model call
    assert_receive {:reactor, {:dispatch, "promptRef", ^request_id}}, 2_000

    # the refusal GateDecision targeting the DIRECTLY-appended promptRef
    # (the received's own refusal is a different decides claim)
    {_gd_id, {gd_claims, _sig}} =
      poll_store(fn {_id, {claims, _sig}} ->
        kind(claims) == "decides" and
          match?({:delta, ^request_id, _ctx}, pointer(claims, "decides"))
      end)

    assert gd_claims != nil
    typed = Schema.resolve(gd_claims)
    assert typed.verdict == "refuse"
    assert typed.policy == "oracle_gate"
    assert typed.decides == {:delta, request_id, "decided"}
  end

  # ------------------------------------------------------------------- AC5

  test "AC5: two boots with an identical seeded commit sequence produce identical delta-id sets",
       ctx do
    # boot A
    boot_daemon!(ctx)

    wire = received_wire(1_754_600_000_000, "message:reactor:ac5", "determinism")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert_receive {:reactor, {:dispatch, "promptRef", _request_id}}, 2_000

    set_a = DurableStore.set()
    ids_a = set_a |> Map.keys() |> Enum.sort()

    # no wall-clock in the decision surface: every emission claims the
    # dispatched delta's timestamp
    [probe_a] = probe_claims(set_a, received_id)
    assert probe_a |> elem(1) |> Map.get(:timestamp) == 1_754_600_000_000.0

    {_rid, {request_claims, _sig}} =
      Enum.find(set_a, fn {_id, {claims, _sig}} -> kind(claims) == "promptRef" end)

    assert request_claims.timestamp == 1_754_600_000_000.0

    # boot B: a fresh store, the SAME keyring (same agent key => same
    # authors, same seed id, same emission ids)
    Daemon.stop()
    log_dir_b = fresh_dir(System.tmp_dir!(), "log")
    log_path_b = Path.join(log_dir_b, "store.jsonl")
    boot_on(log_path_b)
    on_exit(fn -> File.rm_rf(log_dir_b) end)

    boot_daemon!(ctx)
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert_receive {:reactor, {:dispatch, "promptRef", _request_id}}, 2_000

    ids_b = DurableStore.set() |> Map.keys() |> Enum.sort()

    # the two-boot companion (pin 20/17): identical seeded commit sequence
    # in two boots => identical delta-id sets
    assert ids_a == ids_b
  end

  test "AC5 same-log companion: re-boot over the SAME log replays byte-identically (pin 17's fixed-content rationale)",
       ctx do
    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    on_exit(fn -> File.rm_rf(log_dir) end)

    boot_on(log_path)
    boot_daemon!(ctx)

    wire = received_wire(1_754_600_000_000, "message:reactor:ac5-samelog", "determinism")
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert_receive {:reactor, {:dispatch, "promptRef", request_id}}, 2_000

    ids_first = DurableStore.set() |> Map.keys() |> Enum.sort()

    # re-boot the SAME log + keyring: replay re-derives everything; the
    # re-asserted fixed-content seed is absorbed by merge-is-union — the
    # exact rationale pin 17 exists for
    Daemon.stop()
    boot_on(log_path)
    boot_daemon!(ctx)

    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert_receive {:reactor, {:dispatch, "promptRef", ^request_id}}, 2_000

    assert DurableStore.set() |> Map.keys() |> Enum.sort() == ids_first
  end
end
