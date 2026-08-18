defmodule Kyber.Live.EmitterTest do
  @moduledoc """
  AC6 — the pin-1 emitter seam: with no collector registered, every emitter
  call returns `:ok` and the wrapped call site's return value is
  byte-identical to its pre-instrumentation value (I7). Also covers the
  engine/executor/store call-site returns with a collector present.
  """

  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Events, Wire}
  alias Kyber.Agent.ToolExecutor
  alias Kyber.Agent.Action.Gate
  alias Kyber.Trace.Collector

  @human_seed String.duplicate("cd", 32)

  # ------------------------------------------------------------ helpers

  defp tmp_store do
    dir = Path.join(System.tmp_dir!(), "kyber-emitter-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, "store.jsonl")
  end

  defp received_wire(ts, msg_id, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:emitter",
        "session:emitter",
        content
      )

    Wire.envelope(signed)
  end

  defp tool_call_delta(seed, ts, tool_id, args, request_id) do
    {:ok, signed} = Kyber.Agent.Events.tool_call(seed, ts, tool_id, args, request_id)
    {:ok, %{id: id, claims: claims}} = Kyber.Store.verify(Wire.envelope(signed))
    %{id: id, claims: claims}
  end

  # ---------------------------------------------------------------- AC6

  test "AC6: every emitter call returns :ok with no collector registered" do
    # nothing in this file starts a collector for THIS test — the seam is a
    # cast to an unregistered name (silent drop, never a crash)
    assert :ok ==
             Kyber.Trace.span_start(%{
               span_id: "turn:no-collector",
               kind: :turn,
               trace_id: "no-collector",
               refs: ["no-collector"],
               ts: 1_000.0,
               data: %{gate: :open}
             })

    assert :ok == Kyber.Trace.span_end("turn:no-collector", %{status: :closed, data: %{}})
    assert :ok == Kyber.Trace.attribution("no-collector", "no-collector")

    # defensive clauses (garbage inputs) are :ok too — totality
    assert :ok == Kyber.Trace.span_start("garbage")
    assert :ok == Kyber.Trace.span_start(%{})
    assert :ok == Kyber.Trace.span_end(nil, nil)
    assert :ok == Kyber.Trace.attribution(nil, "x")
  end

  test "AC6: the store append return value is identical with and without a collector" do
    store = start_supervised!({DurableStore, tmp_store()})
    wire = received_wire(1_500.0, "ac6-m1", "hello without collector")
    assert :ok == DurableStore.append(wire)

    # now WITH a collector — the same call site returns the identical value
    start_supervised!(Collector)

    assert :ok == DurableStore.append(received_wire(1_500.1, "ac6-m2", "hello with collector"))

    # a duplicate re-append returns :ok identically too
    assert :ok == DurableStore.append(wire)
  end

  test "AC6: the tool executor's returned wires are byte-identical with and without a collector" do
    seed = String.duplicate("ab", 32)
    call = tool_call_delta(seed, 1_600.0, "tool:echo", ~s({"echo":"hi"}), "ac6-request-1")
    set = %{call.id => {call.claims, "sig"}}

    handler = fn ->
      ToolExecutor.handler(
        seed: seed,
        tools: ToolExecutor.stub_tools(),
        gate: Gate.new(allow: ["tool:echo"]),
        store: fn -> set end
      )
    end

    gather = handler.()

    # no collector yet
    wires_without = gather.([call])
    assert length(wires_without) == 2  # gate_decision + tool_result

    start_supervised!(Collector)
    wires_with = gather.([call])

    assert wires_with == wires_without
  end

  test "AC6: the reactor path's emitted store claims are identical with and without a collector" do
    # the reactor's receive-path (turn span, dispatch span, refusal end) —
    # boot a daemon with loop: :reactor and a test observer; the emitted
    # claims in the store must be identical whether or not a collector runs
    keyring_dir = Path.join(System.tmp_dir!(), "kyber-emitter-kr-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(keyring_dir)
    :ok = Kyber.Keys.import_human_seed(@human_seed, keyring_dir)
    {:ok, agent_seed} = Kyber.Keys.mint_agent_seed(keyring_dir)

    config_log_path = Application.get_env(:kyber, :log_path)

    boot = fn
      log_path ->
        # a FRESH log per run (the store replays the log — the runs must
        # not share one)
        Application.put_env(:kyber, :log_path, log_path)
        {:ok, _} = Application.ensure_all_started(:kyber)
        {:ok, pid} =
          Kyber.Daemon.boot(
            keyring_dir: keyring_dir,
            tick_ms: :manual,
            loop: :reactor,
            oracle_seed: :absent,
            budget_cap: 8,
            test_pid: self()
          )

        pid
    end

    stop_app = fn ->
      Kyber.Daemon.stop()

      case Application.stop(:kyber) do
        :ok -> :ok
        {:error, {:not_started, :kyber}} -> :ok
        _other -> :ok
      end
    end

    try do
      # run 1: no collector — a fresh app boot on a fresh log
      log_1 = Path.join(tmp_store(), "run1.jsonl")
      boot.(log_1)
      assert is_pid(Process.whereis(DurableStore))
      wire = received_wire(1_700.0, "ac6-turn-1", "turn without collector")
      assert :ok = DurableStore.append(wire)
      assert_receive {:reactor, {:dispatch, "received", _id}}, 1_000

      claims_1 = store_claims()
      stop_app.()

      # run 2: with a collector — the SAME call sites, a fresh app boot on a
      # fresh log
      start_supervised!(Collector)
      log_2 = Path.join(tmp_store(), "run2.jsonl")
      boot.(log_2)
      wire2 = received_wire(1_700.1, "ac6-turn-2", "turn with collector")
      assert :ok = DurableStore.append(wire2)
      assert_receive {:reactor, {:dispatch, "received", _id}}, 1_000

      claims_2 = store_claims()

      # the store grew by the same delta shapes in both runs (the collector
      # never changed the call sites' behavior — I7)
      assert map_size(claims_1) == map_size(claims_2)
      kinds_1 = Enum.map(claims_1, fn {_id, {c, _}} -> kind(c) end) |> Enum.sort()
      kinds_2 = Enum.map(claims_2, fn {_id, {c, _}} -> kind(c) end) |> Enum.sort()
      assert kinds_1 == kinds_2
      stop_app.()
    after
      Kyber.Daemon.stop()

      case Application.stop(:kyber) do
        :ok -> :ok
        {:error, {:not_started, :kyber}} -> :ok
        _other -> :ok
      end

      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf!(keyring_dir)
    end
  end

  defp store_claims, do: DurableStore.set()

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
end
