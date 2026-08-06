defmodule Kyber.DaemonTest do
  use ExUnit.Case, async: false

  alias Kyber.{AgentLoop, Daemon, DurableStore, Events, Gather, Harness, Keys, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)

  # the T5/T6/T7/T8 lifecycle pattern (test/cli_test.exs): every test gets an
  # isolated store on a fresh tmp log_path plus its own tmp keyring; the real
  # ~/.kyber is never touched (config/test.exs points both under tmp). Ticks
  # are MANUAL (tick_ms: :manual) — the suite drives the daemon with
  # synchronous Daemon.tick/0 calls, so no test ever waits on a timer.
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
      "kyber-daemon-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
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

  defp boot_daemon!(ctx, opts \\ []) do
    boot_opts = Keyword.merge([keyring_dir: ctx.keyring_dir, tick_ms: :manual], opts)
    assert {:ok, pid} = Daemon.boot(boot_opts)
    pid
  end

  defp ingest!(ctx, content \\ "hello daemon") do
    source = %{
      "message_id" => "message:discord:t10:1",
      "channel_id" => "channel:discord:t10",
      "session_id" => "session:discord:t10",
      "content" => content,
      "ts" => 1_754_600_000_000
    }

    assert {:ok, id} = Harness.ingest(source, ctx.keyring_dir)
    id
  end

  defp claims_with_role(role) do
    DurableStore.set()
    |> Enum.filter(fn {_id, {claims, _sig}} -> hd(claims.pointers).role == role end)
  end

  defp content_of({_id, {claims, _sig}}) do
    %{target: {:string, s}} = Enum.find(claims.pointers, &(&1.role == "content"))
    s
  end

  defp signed_wire(seed, pointers, ts) do
    raw = %{timestamp: ts, author: Keys.author_for_seed(seed), pointers: pointers}
    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, seed)
    Wire.envelope({claims, sig})
  end

  defp tick_wire(seed, ts \\ 1_754_600_100_000.0) do
    signed_wire(seed, [%{role: "tick", target: {:entity, "cron:daemon-ticker", "fired"}}], ts)
  end

  defp note_wire(seed, text, ts \\ 1_754_600_200_000.0) do
    signed_wire(seed, [%{role: "note", target: {:string, text}}], ts)
  end

  # -------------------------------------------------------------------- AC1

  test "AC1: boot takes the lock (pid file beside the log); stop releases it", ctx do
    lock = ctx.log_path <> ".lock"
    refute File.exists?(lock)

    boot_daemon!(ctx)
    assert File.read!(lock) == System.pid()

    assert :ok = Daemon.stop()
    refute File.exists?(lock)
  end

  test "AC1: a lock held by a LIVE process refuses the second daemon with the pinned reason",
       ctx do
    # a real live OS process the lock can point at: cat blocks on stdin until
    # the port closes (no sleep primitive anywhere)
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    on_exit(fn -> if port in Port.list(), do: Port.close(port) end)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    File.write!(ctx.log_path <> ".lock", Integer.to_string(os_pid))

    assert {:error, {:already_running, path}} = Daemon.boot(keyring_dir: ctx.keyring_dir)
    assert path == ctx.log_path
  end

  test "AC1: a STALE lock (dead pid) must not brick re-boot", ctx do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = String.trim(out)

    File.write!(ctx.log_path <> ".lock", dead_pid)

    boot_daemon!(ctx)
    assert File.read!(ctx.log_path <> ".lock") == System.pid()
  end

  test "AC1: a garbage lock is stale, never a brick", ctx do
    File.write!(ctx.log_path <> ".lock", "not a pid")
    boot_daemon!(ctx)
    assert File.read!(ctx.log_path <> ".lock") == System.pid()
  end

  test "AC1: a lock carrying our own OS pid is ours to retake (crash-restart in one VM)", ctx do
    File.write!(ctx.log_path <> ".lock", System.pid())
    boot_daemon!(ctx)
  end

  test "AC1: a second boot in the same VM refuses with the same pinned reason", ctx do
    boot_daemon!(ctx)
    assert {:error, {:already_running, path}} = Daemon.boot(keyring_dir: ctx.keyring_dir)
    assert path == ctx.log_path
  end

  test "AC1: the daemon refuses to boot with no store running" do
    stop_app()
    assert {:error, :store_not_running} = Daemon.boot(keyring_dir: System.tmp_dir!())
  end

  # -------------------------------------------------------------------- AC2

  test "AC2: a new claim routes to the gather, the handler fires, the cursor advances;
        the daemon's own output claim is routed but re-fires nothing",
       ctx do
    boot_daemon!(ctx)
    received_id = ingest!(ctx)

    # tick 1: the received claim is dispatched, the built-in handler fires,
    # the ack persists, a checkpoint lands
    assert {:ok, status} = Daemon.tick()
    assert status.cursor == 1
    assert status.fired == 1

    assert [ack] = claims_with_role("sent")
    assert content_of(ack) == "ack " <> received_id

    # tick 2: the daemon's own ack + checkpoint lines are dispatched like any
    # claim — role-matched routing makes the no-self-loop structural: nothing
    # subscribes to "sent" or "checkpoint", so nothing re-fires
    assert {:ok, status2} = Daemon.tick()
    assert status2.cursor == 3
    assert status2.fired == 1
    assert [_only_one_ack] = claims_with_role("sent")

    # tick 3: only the second checkpoint line remains; checkpoint-only ticks
    # write no further checkpoint (the cursor converges)
    assert {:ok, status3} = Daemon.tick()
    assert status3.cursor == 4
    assert {:ok, %{cursor: 4}} = Daemon.tick()
  end

  test "AC2: the ack points back at the received claim (caused_by DeltaRef)", ctx do
    boot_daemon!(ctx)
    received_id = ingest!(ctx)
    {:ok, _} = Daemon.tick()

    assert [{_id, {claims, _sig}}] = claims_with_role("sent")

    assert %{target: {:delta, ^received_id, nil}} =
             Enum.find(claims.pointers, &(&1.role == "caused_by"))
  end

  # -------------------------------------------------------------------- AC3

  test "AC3: the cursor persists as daemon.checkpoint claims — a re-boot never re-fires", ctx do
    boot_daemon!(ctx)
    ingest!(ctx)
    {:ok, _} = Daemon.tick()
    {:ok, _} = Daemon.tick()
    {:ok, %{cursor: 4}} = Daemon.tick()

    # the checkpoint claims are ordinary signed claims in the store (state as
    # data): positions 1 (after the received dispatch) and 3 (after the
    # ack+checkpoint dispatch)
    positions =
      claims_with_role("checkpoint")
      |> Enum.map(fn {_id, {claims, _sig}} ->
        %{target: {:number, n}} = Enum.find(claims.pointers, &(&1.role == "position"))
        n
      end)
      |> Enum.sort()

    assert positions == [1.0, 3.0]

    # kill + re-boot (the in-VM equivalent: stop the daemon and the app, then
    # boot both again on the same log)
    assert :ok = Daemon.stop()
    boot_on(ctx.log_path)
    boot_daemon!(ctx)

    # two ticks: the resumed cursor covers everything already dispatched —
    # no re-fire of any kind, still exactly one ack
    assert {:ok, s1} = Daemon.tick()
    assert {:ok, s2} = Daemon.tick()
    assert s1.fired == 0
    assert s2.fired == 0
    assert s2.cursor == 4
    assert [_only_one_ack] = claims_with_role("sent")
  end

  test "AC3: the crash window (output persisted, checkpoint lost) dedupes by content address",
       ctx do
    # arrange the exact crash artifact: the received claim AND its ack are in
    # the log, but no checkpoint ever landed
    received_id = ingest!(ctx)
    [{^received_id, {received_claims, _sig}}] = claims_with_role("received")

    handler = AgentLoop.handler(ctx.agent_seed)
    [ack_wire] = handler.([%{id: received_id, claims: received_claims}])
    assert :ok = DurableStore.append(ack_wire)

    boot_daemon!(ctx)

    # the re-fire produces the IDENTICAL response (deterministic timestamp +
    # derived ids), so the sink skips it — no duplicate ever persists
    assert {:ok, status} = Daemon.tick()
    assert status.fired == 1
    assert status.skipped == 1
    assert [_only_one_ack] = claims_with_role("sent")

    assert {:ok, _} = Daemon.tick()
    assert [_still_one_ack] = claims_with_role("sent")
  end

  # -------------------------------------------------------------------- AC5

  test "AC5: a watcher.tick pulse pushed via Gather.notify/1 fires its subscriber;
        the subscriber's output persists; the pulse itself never lands",
       ctx do
    boot_daemon!(ctx)
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("tick", fn [d] ->
        send(test_pid, {:tick_fired, d.id})

        {:ok, signed} =
          Events.message_sent(
            ctx.agent_seed,
            1_754_600_300_000,
            d.id,
            "message:pulse-reply:1",
            "channel:discord:t10",
            "pulse reply"
          )

        [Wire.envelope(signed)]
      end)

    pulse = tick_wire(ctx.agent_seed)
    assert {:ok, [_output]} = Gather.notify(pulse)
    assert_receive {:tick_fired, _id}

    # the subscriber's output went through the daemon's sink and persisted
    # (persist-everything default); the pulse itself is nowhere in the store
    assert [sent] = claims_with_role("sent")
    assert content_of(sent) == "pulse reply"
    assert claims_with_role("tick") == []
  end

  test "AC5: the daemon's own ticker emits a watcher.tick heartbeat pulse each tick —
        fired, door-verified, never persisted",
       ctx do
    boot_daemon!(ctx)
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("tick", fn [d] ->
        send(test_pid, {:heartbeat, d.claims.author})
        []
      end)

    assert {:ok, status} = Daemon.tick()
    assert status.pulsed >= 1

    # the heartbeat is a signed delta by shape: its author is the daemon's key
    agent_author = Keys.author_for_seed(ctx.agent_seed)
    assert_receive {:heartbeat, ^agent_author}

    assert claims_with_role("tick") == []
  end

  # -------------------------------------------------------------------- AC6

  test "AC6: persist-everything default — a door-valid emitted claim lands in the store", ctx do
    boot_daemon!(ctx)
    wire = note_wire(ctx.agent_seed, "remember this")

    assert {:ok, :persisted} = Daemon.emit(wire)
    assert [{_id, {claims, _sig}}] = claims_with_role("note")
    assert hd(claims.pointers).target == {:string, "remember this"}
  end

  test "AC6: the knob tunes a shape DOWN to pulse-only — fired, never landed", ctx do
    boot_daemon!(ctx, pulse_only: ["note"])
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn [d] ->
        send(test_pid, {:note_fired, d.id})
        []
      end)

    wire = note_wire(ctx.agent_seed, "ephemeral")
    assert {:ok, :pulsed} = Daemon.emit(wire)
    assert_receive {:note_fired, _id}
    assert claims_with_role("note") == []
  end

  test "AC6: the knob never weakens the door — an unsigned claim is refused, not pulsed", ctx do
    boot_daemon!(ctx, pulse_only: ["note"])
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn [d] ->
        send(test_pid, {:note_fired, d.id})
        []
      end)

    unsigned = Map.delete(note_wire(ctx.agent_seed, "sneaky"), "sig")
    assert {:error, :unsigned} = Daemon.emit(unsigned)
    refute_received {:note_fired, _}
    assert claims_with_role("note") == []

    # and on the persist path (untuned shape) the door refuses identically
    assert {:error, :unsigned} = Daemon.emit(Map.delete(tick_wire(ctx.agent_seed), "sig"))
  end

  # ------------------------------------------------------------------ status

  test "status carries the operational shape: cursor, author, log path", ctx do
    boot_daemon!(ctx)
    status = Daemon.status()

    assert status.cursor == 0
    assert status.log_path == ctx.log_path
    assert status.author == Keys.author_for_seed(ctx.agent_seed)
  end

  test "the daemon auto-mints its agent identity on a fresh keyring (first boot IS the mint)" do
    fresh_keyring = fresh_dir(System.tmp_dir!(), "fresh-keyring")
    on_exit(fn -> File.rm_rf(fresh_keyring) end)
    refute File.exists?(Path.join(fresh_keyring, "agent.seed"))

    assert {:ok, _pid} = Daemon.boot(keyring_dir: fresh_keyring, tick_ms: :manual)
    assert File.exists?(Path.join(fresh_keyring, "agent.seed"))
  end
end
