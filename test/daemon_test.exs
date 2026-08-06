defmodule Kyber.DaemonTest do
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Gather, Harness, Keys, Wire}

  @human_seed String.duplicate("cd", 32)

  # the cli_test lifecycle: an isolated singleton DurableStore per test on a
  # fresh tmp log, plus a tmp keyring (human + agent seeds). The daemon/gather
  # run with auto_tick DISABLED — every test drives the loop with the
  # synchronous `Daemon.tick_now/1` seam, so assertions are deterministic and
  # NOTHING waits on a timer (the no-sleep rule is structural here).
  setup do
    config_log_path = Application.get_env(:kyber, :log_path)

    key_dir = fresh(System.tmp_dir!(), "daemon-keyring")
    File.mkdir_p!(key_dir)
    :ok = Keys.import_human_seed(@human_seed, key_dir)
    {:ok, _agent} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh(System.tmp_dir!(), "daemon-log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_store(log_path)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring: key_dir, log_path: log_path}
  end

  defp fresh(base, tag) do
    Path.join(base, "kyber-#{tag}-#{System.unique_integer([:positive])}")
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp boot_store(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    Application.delete_env(:kyber, :daemon)
    {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  # start the gather + daemon as siblings (the app-supervised shape), auto_tick
  # off. Returns nothing — both are named singletons the test drives directly.
  defp start_loop(keyring) do
    start_supervised!({Gather, [pulse_only: Daemon.pulse_only()]})
    start_supervised!({Daemon, [keyring: keyring, log_path: log_path_of(), auto_tick: false]})
    :ok
  end

  defp log_path_of, do: Application.get_env(:kyber, :log_path)

  defp ingest_message(keyring, message_id) do
    {:ok, id} =
      Harness.ingest(
        %{
          "message_id" => message_id,
          "channel_id" => "channel:discord:d",
          "session_id" => "session:discord:d",
          "content" => "hello daemon",
          "ts" => 1_754_512_345_678
        },
        keyring
      )

    id
  end

  defp claims_of_flavor(flavor) do
    DurableStore.set()
    |> Map.values()
    |> Enum.map(fn {claims, _sig} -> claims end)
    |> Enum.filter(fn c -> c.pointers |> List.first() |> Map.fetch!(:role) == flavor end)
  end

  # ------------------------------------------------------------------ AC2/AC4

  test "a message.received is dispatched once: the handler emits an ack message.sent",
       %{keyring: keyring} do
    start_loop(keyring)
    received_id = ingest_message(keyring, "message:discord:d:1")

    assert %{routed: 1, fired: 1} = Daemon.tick_now()

    assert [sent] = claims_of_flavor("sent")
    # AC4: content is the pinned deterministic reply, pointer back to the received
    assert Enum.any?(sent.pointers, &(&1.target == {:string, "ack " <> received_id}))
    assert Enum.any?(sent.pointers, &(&1.target == {:delta, received_id, nil}))
    # AC4: signed by the AGENT key (not the human key)
    assert sent.author == Keys.author_for_seed(agent_seed(keyring))

    # a second tick routes the daemon's OWN sent claim but re-fires nothing (AC2)
    assert %{fired: 0} = Daemon.tick_now()
    assert [_only_one] = claims_of_flavor("sent")
  end

  test "the cursor advances — a re-tick with no new claims routes nothing",
       %{keyring: keyring} do
    start_loop(keyring)
    ingest_message(keyring, "message:discord:d:1")

    assert %{routed: 1} = Daemon.tick_now()
    assert %{routed: 0, fired: 0} = Daemon.tick_now()
  end

  # ------------------------------------------------------------------ AC3

  test "re-boot idempotence: after a kill + re-boot the daemon does NOT re-fire",
       %{keyring: keyring} do
    start_loop(keyring)
    ingest_message(keyring, "message:discord:d:1")
    assert %{fired: 1} = Daemon.tick_now()
    assert [sent_before] = claims_of_flavor("sent")

    # kill the whole loop (a fresh-VM re-boot: gather AND daemon restart)
    :ok = stop_supervised!(Daemon)
    :ok = stop_supervised!(Gather)
    refute Process.whereis(Daemon)

    # a persisted checkpoint claim must exist — the cursor is NOT in-memory-only
    assert claims_of_flavor("checkpoint") != []

    # re-boot on the SAME store: the cursor is re-derived from the checkpoint
    start_loop(keyring)
    assert %{fired: 0} = Daemon.tick_now()
    assert %{fired: 0} = Daemon.tick_now()

    assert [^sent_before] = claims_of_flavor("sent")
  end

  # ------------------------------------------------------------------ AC5

  test "a watcher.tick pulse fires its subscriber but never lands in the store",
       %{keyring: keyring} do
    start_loop(keyring)

    # a tick subscriber whose side effect is a message.sent
    Gather.subscribe(Kyber.Gather, "tick", fn deltas ->
      Enum.map(deltas, fn {claims, _sig} ->
        {:ok, signed} =
          Events.message_sent(
            agent_seed(keyring),
            claims.timestamp,
            "watcher:tick:resp",
            "message:kyber:tick",
            "channel:kyber:watcher",
            "tick observed"
          )

        signed
      end)
    end)

    {:ok, tick} = Events.watcher_tick(agent_seed(keyring), 1_754_512_345_679, "watcher:d:1")
    assert {:ok, :pulsed} = Gather.notify(Kyber.Gather, Wire.envelope(tick))

    # the side effect landed...
    assert [_sent] = claims_of_flavor("sent")
    # ...but NO watcher.tick claim ever reached the store
    assert claims_of_flavor("tick") == []
  end

  # ------------------------------------------------------------------ AC6

  test "the admission knob: a tuned shape is pulse-only; the door still refuses the unsigned",
       %{keyring: keyring} do
    start_loop(keyring)

    fired = self()

    Gather.subscribe(Kyber.Gather, "tick", fn deltas ->
      send(fired, {:fired, length(deltas)}) && []
    end)

    {:ok, tick} = Events.watcher_tick(agent_seed(keyring), 1_754_512_345_679, "watcher:d:2")
    wire = Wire.envelope(tick)

    assert {:ok, :pulsed} = Gather.notify(Kyber.Gather, wire)
    assert_received {:fired, 1}
    assert claims_of_flavor("tick") == []

    # an unsigned tick is refused by the door and never pulses
    unsigned = Map.delete(wire, "sig")
    assert {:error, _} = Gather.notify(Kyber.Gather, unsigned)
    refute_received {:fired, _}

    # persist-everything default: a NON-tuned shape pushed via notify is
    # admitted to the store (and fires later via the log-poll, not here)
    {:ok, received} =
      Events.message_received(
        @human_seed,
        1_754_512_345_680,
        "message:discord:d:knob",
        "channel:discord:d",
        "session:discord:d",
        "persist me"
      )

    assert {:ok, :persisted} = Gather.notify(Kyber.Gather, Wire.envelope(received))
    assert [_one] = claims_of_flavor("received")
    # the log-poll fires it now
    assert %{fired: 1} = Daemon.tick_now()
    assert [_ack] = claims_of_flavor("sent")
  end

  # ------------------------------------------------------------------ AC1 (lock)

  test "the lock refuses a second daemon on the same log, and reclaims a stale (dead-pid) lock",
       %{log_path: log_path} do
    assert :ok = Daemon.acquire_lock(log_path)
    # a second acquire by THIS live process is refused
    assert {:error, {:already_running, ^log_path}} = Daemon.acquire_lock(log_path)

    # simulate a stale lock from a dead daemon: a pid that cannot be alive
    File.write!(Daemon.lock_path(log_path), "999999999")
    assert :ok = Daemon.acquire_lock(log_path)

    assert :ok = Daemon.release_lock(log_path)
    refute File.exists?(Daemon.lock_path(log_path))
  end

  # ---------------------------------------------------------------- helpers

  defp agent_seed(keyring) do
    {:ok, seed} = Keys.load_agent_seed(keyring)
    seed
  end
end
