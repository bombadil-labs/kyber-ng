defmodule Kyber.DaemonTest do
  use ExUnit.Case, async: false

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "kyber-t10-daemon-#{System.unique_integer([:positive])}"
      )

    log = Path.join(tmp, "store.jsonl")
    keyring = Path.join(tmp, "keyring")
    File.mkdir_p!(keyring)
    {:ok, _seed} = Kyber.Keys.mint_agent_seed(keyring)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, log: log, keyring: keyring, tmp: tmp}
  end

  test "AC1: daemon boots on a tmp store, refuses a second instance, stops cleanly",
       %{log: log, keyring: keyring} do
    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring)
    assert Process.alive?(pid)

    # the pid-lock lands next to the log and carries the OS pid
    lock = log <> ".daemon"
    assert File.exists?(lock)
    assert String.trim(File.read!(lock)) == System.pid()

    # a second daemon on the SAME log is refused with a clean tuple
    assert {:error, {:already_running, ^log}} =
             Kyber.Daemon.start_link(log: log, keyring: keyring)

    assert :ok = GenServer.stop(pid)
    refute Process.alive?(pid)

    # the lock releases on clean shutdown
    refute File.exists?(lock)
  end

  test "AC1: a stale lock from a dead daemon does not brick re-boot",
       %{log: log, keyring: keyring} do
    # simulate a killed daemon: a lock file carrying a pid that does not exist
    lock = log <> ".daemon"
    File.write!(lock, "999999999")
    refute os_alive?("999999999")

    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring)
    assert Process.alive?(pid)
    assert :ok = GenServer.stop(pid)
  end

  test "AC1: the ticker is send_after-based and ticks without sleeping",
       %{log: log, keyring: keyring} do
    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring, tick_interval: 20)

    # bounded explicit polling: wait until at least two ticks have fired
    assert_poll(fn -> Kyber.Daemon.stats(pid).ticks >= 2 end, 500)
    assert :ok = GenServer.stop(pid)
  end

  test "AC1: a missing agent seed refuses the boot with a tagged tuple",
       %{log: log, tmp: tmp} do
    empty_keyring = Path.join(tmp, "empty-keyring")
    File.mkdir_p!(empty_keyring)

    assert {:error, :no_agent_seed} =
             Kyber.Daemon.start_link(log: log, keyring: empty_keyring)

    # the failed boot left no lock behind
    refute File.exists?(log <> ".daemon")
  end

  test "AC2: the daemon watches the log — handler fires, cursor advances, no self re-fire",
       %{log: log, keyring: keyring} do
    human_seed = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    :ok = Kyber.Keys.import_human_seed(human_seed, keyring)
    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring, tick_interval: 20)

    {:ok, received_id} =
      Kyber.Harness.ingest(
        %{
          "message_id" => "m-1",
          "channel_id" => "cli",
          "session_id" => "s-1",
          "content" => "hello kyber"
        },
        keyring
      )

    # the handler fired: exactly one message.sent — the deterministic ack,
    # pointing back at the received claim
    assert_poll(fn -> length(sent_claims()) == 1 end, 2_000)
    [sent] = sent_claims()
    assert content_of(sent) == "ack " <> received_id
    assert caused_by_of(sent) == received_id
    assert Kyber.Daemon.stats(pid).cursor >= 1

    # a claim the daemon itself wrote (its own message.sent output) does NOT
    # re-fire the producing handler: write another agent-signed message.sent
    # through the harness, let several ticks pass, and assert the agent loop
    # never fired on it (no third claim appears)
    {:ok, _second} =
      Kyber.Harness.agent_event(
        %{
          "response_delta_id" => received_id,
          "out_message_id" => "m-2",
          "channel_id" => "cli",
          "content" => "ack " <> received_id
        },
        keyring
      )

    assert_poll(fn -> length(sent_claims()) == 2 end, 2_000)
    ticks_then = Kyber.Daemon.stats(pid).ticks
    assert_poll(fn -> Kyber.Daemon.stats(pid).ticks >= ticks_then + 3 end, 2_000)
    assert length(sent_claims()) == 2

    assert :ok = GenServer.stop(pid)
  end

  defp sent_claims do
    Kyber.Harness.view()
    |> Enum.filter(fn claims ->
      case List.first(claims.pointers) do
        %{role: "sent"} -> true
        _ -> false
      end
    end)
  end

  defp content_of(claims) do
    claims.pointers
    |> Enum.find_value(fn
      %{role: "content", target: {:string, s}} -> s
      _ -> nil
    end)
  end

  defp caused_by_of(claims) do
    claims.pointers
    |> Enum.find_value(fn
      %{role: "caused_by", target: {:delta, hex, _ctx}} -> hex
      _ -> nil
    end)
  end

  test "AC3: the dispatch cursor persists — kill + re-boot does not re-fire",
       %{log: log, keyring: keyring} do
    human_seed = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    :ok = Kyber.Keys.import_human_seed(human_seed, keyring)
    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring, tick_interval: 20)

    {:ok, received_id} =
      Kyber.Harness.ingest(
        %{
          "message_id" => "m-ac3",
          "channel_id" => "cli",
          "session_id" => "s-ac3",
          "content" => "ping"
        },
        keyring
      )

    # the handler fired exactly once
    assert_poll(fn -> length(sent_claims()) == 1 end, 2_000)

    # the cursor is state as data: at least one daemon.checkpoint claim,
    # carrying a numeric cursor pointer, signed by the daemon's own author
    assert_poll(fn -> checkpoint_claims() != [] end, 2_000)

    assert Enum.all?(checkpoint_claims(), fn claims ->
             claims.author ==
               Kyber.Keys.author_for_seed(
                 File.read!(Path.join(keyring, "agent.seed"))
                 |> String.trim()
               ) and
               Enum.any?(claims.pointers, fn
                 %{role: "cursor", target: {:number, n}} when is_float(n) -> true
                 _ -> false
               end)
           end)

    cursor_at_kill = Kyber.Daemon.stats(pid).cursor
    assert cursor_at_kill > 0

    # the kill (the in-VM SIGTERM equivalent: a clean stop) and re-boot
    assert :ok = GenServer.stop(pid)
    {:ok, pid2} = Kyber.Daemon.start_link(log: log, keyring: keyring, tick_interval: 20)

    # the cursor RESUMED from the persisted checkpoint (not in-memory-only)
    assert Kyber.Daemon.stats(pid2).cursor >= cursor_at_kill

    # wait two ticks — no second message.sent, no re-fire of any kind
    assert_poll(fn -> Kyber.Daemon.stats(pid2).ticks >= 2 end, 2_000)
    assert [sent] = sent_claims()
    assert content_of(sent) == "ack " <> received_id

    # exactly one exchange in the store, even after the re-boot settled
    ticks_then = Kyber.Daemon.stats(pid2).ticks
    assert_poll(fn -> Kyber.Daemon.stats(pid2).ticks >= ticks_then + 2 end, 2_000)
    assert length(sent_claims()) == 1
    assert length(received_claims()) == 1

    assert :ok = GenServer.stop(pid2)
  end

  defp received_claims do
    Kyber.Harness.view()
    |> Enum.filter(fn claims ->
      case List.first(claims.pointers) do
        %{role: "received"} -> true
        _ -> false
      end
    end)
  end

  defp checkpoint_claims do
    Kyber.Harness.view()
    |> Enum.filter(fn claims ->
      case List.first(claims.pointers) do
        %{role: "checkpoint"} -> true
        _ -> false
      end
    end)
  end

  test "AC4: the runtime agent loop is a pure, deterministic (delta[]) -> delta[]",
       %{keyring: keyring} do
    agent_seed = Path.join(keyring, "agent.seed") |> File.read!() |> String.trim()
    human_seed = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    {match, handler} =
      Kyber.AgentLoop.subscription(agent_seed, now: fn -> 1_700_000_000_000.0 end)

    {:ok, {received, _sig}} =
      Kyber.Events.message_received(
        human_seed,
        1_699_999_999_999.0,
        "m-ac4",
        "cli",
        "s-ac4",
        "hi"
      )

    received_id = Rhizomatic.Delta.id_hex(received)

    # the match is structural: message.received in, message.sent NOT matched
    assert match.(received)

    {:ok, {a_sent_claim, _}} =
      Kyber.Events.message_sent(agent_seed, 1_699_999_999_999.0, received_id, "x", "cli", "y")

    refute match.(a_sent_claim)

    # PURE: no store running, no daemon, no keyring IO — and deterministic:
    # the same input view yields a byte-identical signed delta twice
    [out1] = handler.([received])
    [out2] = handler.([received])
    assert out1 == out2

    {claims, sig} = out1

    # a NEW claim: role message, flavor sent
    assert %{role: "sent", target: {:entity, "ack-" <> rid, "outgoing"}} =
             List.first(claims.pointers)

    assert rid == received_id

    # the origin pointer: caused_by = the received claim's id
    assert Enum.any?(claims.pointers, fn
             %{role: "caused_by", target: {:delta, hex, _ctx}} -> hex == received_id
             _pointer -> false
           end)

    # the pinned reply text, verbatim
    assert content_of(claims) == "ack " <> received_id

    # signed with the daemon's keyring — and the door verifies it
    assert claims.author == Kyber.Keys.author_for_seed(agent_seed)

    assert {:ok, _set} =
             Kyber.Store.admit(Kyber.Wire.envelope({claims, sig}), Kyber.DeltaSet.new())
  end

  test "AC5: two-channel intake — a watcher.tick pulse fires its subscriber, never persists",
       %{log: log, keyring: keyring} do
    {:ok, pid} = Kyber.Daemon.start_link(log: log, keyring: keyring, tick_interval: 20)
    agent_seed = Path.join(keyring, "agent.seed") |> File.read!() |> String.trim()

    # a watcher.tick subscriber on the live pulse bus: fires a visible side
    # effect (a message.sent response) when its shape saturates
    match = fn claims ->
      case List.first(claims.pointers) do
        %{role: "tick"} -> true
        _ -> false
      end
    end

    handler = fn [tick | _rest] ->
      tick_id = Rhizomatic.Delta.id_hex(tick)

      case Kyber.Events.message_sent(
             agent_seed,
             1.0 * System.system_time(:millisecond),
             tick_id,
             "tick-out-1",
             "watcher",
             "tick-ack"
           ) do
        {:ok, signed} -> [signed]
        {:error, _reason} -> []
      end
    end

    :ok = Kyber.Gather.subscribe(Kyber.Gather, :watcher_tick, match, handler)

    # push a SIGNED watcher.tick pulse (a delta by shape: author, pointers,
    # timestamp, signature — the door's verification applies to pulses too)
    {:ok, wire} =
      sign_wire(agent_seed, [%{role: "tick", target: {:entity, "watcher:main", "ticks"}}])

    assert {:ok, report} = Kyber.Gather.notify(wire)
    assert report.persisted == false
    assert :watcher_tick in report.fired

    # the subscriber fired: its message.sent RESPONSE is memory...
    assert Enum.any?(sent_claims(), fn claims -> content_of(claims) == "tick-ack" end)

    # ...while NO watcher.tick claim ever lands in the store — not now, and
    # not after the daemon's ticker has run (the pulse never reaches the log)
    assert tick_claims() == []
    ticks_then = Kyber.Daemon.stats(pid).ticks
    assert_poll(fn -> Kyber.Daemon.stats(pid).ticks >= ticks_then + 3 end, 2_000)
    assert tick_claims() == []

    # the door is never weakened: an unsigned claim is refused, never pulsed
    assert {:error, :unsigned} = Kyber.Gather.notify(Map.delete(wire, "sig"))

    assert {:error, :bad_signature} =
             Kyber.Gather.notify(%{wire | "sig" => String.duplicate("0", 128)})

    assert tick_claims() == []

    assert :ok = GenServer.stop(pid)
  end

  defp tick_claims do
    Kyber.Harness.view()
    |> Enum.filter(fn claims ->
      case List.first(claims.pointers) do
        %{role: "tick"} -> true
        _ -> false
      end
    end)
  end

  defp sign_wire(seed, pointers) do
    claims = %{
      timestamp: 1.0 * System.system_time(:millisecond),
      author: Kyber.Keys.author_for_seed(seed),
      pointers: pointers
    }

    with {:ok, claims} <- Rhizomatic.Delta.validate(claims),
         {:ok, sig} <- Kyber.Keys.sign(claims, seed) do
      {:ok, Kyber.Wire.envelope({claims, sig})}
    end
  end

  test "AC6: the admission knob tunes a shape down to pulse-only; the door is never weakened",
       %{log: log, keyring: keyring} do
    {:ok, pid} =
      Kyber.Daemon.start_link(
        log: log,
        keyring: keyring,
        tick_interval: 20,
        pulse_only: ["tick"]
      )

    agent_seed = Path.join(keyring, "agent.seed") |> File.read!() |> String.trim()

    match = fn claims ->
      case List.first(claims.pointers) do
        %{role: "tick"} -> true
        _ -> false
      end
    end

    handler = fn [tick | _rest] ->
      tick_id = Rhizomatic.Delta.id_hex(tick)

      case Kyber.Events.message_sent(
             agent_seed,
             1.0 * System.system_time(:millisecond),
             tick_id,
             "tick-out-knob",
             "watcher",
             "tick-ack"
           ) do
        {:ok, signed} -> [signed]
        {:error, _reason} -> []
      end
    end

    :ok = Kyber.Gather.subscribe(Kyber.Gather, :watcher_tick, match, handler)

    # the knob turned: a door-valid claim of the tuned shape routed through
    # the LOG channel fires its handler but is NOT persisted
    {:ok, wire} =
      sign_wire(agent_seed, [%{role: "tick", target: {:entity, "watcher:main", "ticks"}}])

    assert {:ok, report} = Kyber.Gather.route(Kyber.Gather, wire)
    assert report.persisted == false
    assert :watcher_tick in report.fired
    assert tick_claims() == []
    assert Enum.any?(sent_claims(), fn claims -> content_of(claims) == "tick-ack" end)

    # persist-everything default: an UNTUNED shape routed through the same
    # channel lands in the store
    {:ok, note_wire} =
      sign_wire(agent_seed, [%{role: "note", target: {:string, "remember me"}}])

    assert {:ok, note_report} = Kyber.Gather.route(Kyber.Gather, note_wire)
    assert note_report.persisted == true

    assert Enum.any?(Kyber.Harness.view(), fn claims ->
             match?(%{role: "note"}, List.first(claims.pointers))
           end)

    # the knob never weakens the door: malformed/unsigned claims are
    # refused, NOT pulsed — and a refused claim fires nothing
    sent_before = length(sent_claims())
    assert {:error, :unsigned} = Kyber.Gather.route(Kyber.Gather, Map.delete(note_wire, "sig"))

    assert {:error, :bad_signature} =
             Kyber.Gather.route(Kyber.Gather, %{note_wire | "sig" => String.duplicate("0", 128)})

    assert {:error, {:unknown_key, :envelope, "bogus"}} =
             Kyber.Gather.route(Kyber.Gather, %{"bogus" => true})

    assert {:error, :malformed_envelope} = Kyber.Gather.route(Kyber.Gather, ["not", "a", "map"])
    assert length(sent_claims()) == sent_before

    assert :ok = GenServer.stop(pid)
  end

  defp os_alive?(pid_str) do
    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  defp assert_poll(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "assert_poll timed out"
      else
        receive do
        after
          10 -> do_poll(fun, deadline)
        end
      end
    end
  end
end
