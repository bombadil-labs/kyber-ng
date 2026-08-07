defmodule Kyber.ApplicationTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, DurableStore, Events, Store, Wire}

  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  # the config/test.exs tmp log_path for THIS `mix test` run, captured at
  # runtime before any test mutates the env (AC4/AC5 use it; AC8/AC9 install
  # their own per-test paths and setup restores the baseline before each test)
  setup_all do
    {:ok, config_log_path: Application.get_env(:kyber, :log_path)}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  setup %{config_log_path: config_log_path} do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kyber-application-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)

    # belt and braces: nothing from a previous test may leak into this one —
    # the app is stopped, the config/test.exs log path restored, and the
    # SHARED log file itself reset (any app-booting sibling test — harness,
    # federation, peer — appends to it; AC4 asserts its exact content)
    stop_app()
    File.rm(config_log_path)
    Application.put_env(:kyber, :log_path, config_log_path)

    on_exit(fn ->
      stop_app()
      File.rm_rf(dir)
    end)

    {:ok, tmp_dir: dir, config_log_path: config_log_path}
  end

  defp signed_message(message_id) do
    assert {:ok, signed} =
             Events.message_received(
               @human_seed,
               @ts,
               message_id,
               "channel:discord:111111111111111111",
               "session:discord:111111111111111111",
               "hello " <> message_id
             )

    signed
  end

  # explicit state polling (the T3-sanctioned wait: assert_receive/3 or
  # state polling, never a timer) — bounded yield between whereis polls
  defp await_respawn(old_pid, attempts \\ 10_000) do
    case Process.whereis(DurableStore) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts <= 0 ->
        flunk("DurableStore was not respawned by the supervisor")

      _ ->
        receive do
          _ -> :ok
        after
          1 -> :ok
        end

        await_respawn(old_pid, attempts - 1)
    end
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: the app boots the durable store; a Wire-built envelope persists and replays across a supervised restart",
       %{config_log_path: log_path} do
    assert is_binary(log_path)

    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))

    # the wire chain: the appended envelope is built via Kyber.Wire, not TestWire
    envelope = Wire.envelope(signed_message("message:discord:111111111111111111:1"))
    assert :ok = DurableStore.append(envelope)
    assert DeltaSet.member?(DurableStore.set(), envelope["id"])

    {:ok, json} = Wire.encode(envelope)
    assert File.read!(log_path) == json <> "\n"

    # supervised restart: Application.stop + start again
    :ok = stop_app()
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    # the decoded line re-admits and is present in the set
    assert DeltaSet.member?(DurableStore.set(), envelope["id"])
    assert {:ok, decoded} = Wire.decode(json)
    assert decoded == envelope
    assert {:ok, _set} = Store.admit(decoded, DeltaSet.new())
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: exactly one running store — Kyber.Store is nil, Kyber.DurableStore is a pid" do
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    assert Process.whereis(Store) == nil
    assert is_pid(Process.whereis(DurableStore))
  end

  # ------------------------------------------------------------------ AC8

  test "AC8: fresh-HOME default path — the parent dir is created at boot and the first append works",
       %{tmp_dir: tmp_dir, config_log_path: config_log_path} do
    # System.user_home/0 reads :init.get_argument(:home), fixed at VM boot, so
    # the pinned parenthetical's Application.put_env variant is used: a log
    # path whose parent does not exist — a fresh account has no ~/.kyber/ yet
    default_path = Path.join(tmp_dir, ".kyber/store.jsonl")
    refute File.exists?(Path.dirname(default_path))

    Application.put_env(:kyber, :log_path, default_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    # Kyber.Application owns the side effect: mkdir_p BEFORE the child starts
    assert File.dir?(Path.dirname(default_path))

    envelope = Wire.envelope(signed_message("message:discord:888888888888888888:8"))
    assert :ok = DurableStore.append(envelope)
    assert DeltaSet.member?(DurableStore.set(), envelope["id"])

    # replay presence across a supervised restart
    :ok = stop_app()
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert DeltaSet.member?(DurableStore.set(), envelope["id"])

    # baseline restored for the next test
    Application.put_env(:kyber, :log_path, config_log_path)
  end

  # ------------------------------------------------------------------ AC9

  test "AC9: killing the DurableStore pid makes the supervisor respawn it and replay rebuilds the set",
       %{tmp_dir: tmp_dir, config_log_path: config_log_path} do
    path = Path.join(tmp_dir, "log.jsonl")
    Application.put_env(:kyber, :log_path, path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    envelope = Wire.envelope(signed_message("message:discord:999999999999999999:9"))
    assert :ok = DurableStore.append(envelope)
    id = envelope["id"]
    assert DeltaSet.member?(DurableStore.set(), id)

    pid = Process.whereis(DurableStore)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5000

    # restart: :permanent — the supervisor respawns the child
    new_pid = await_respawn(pid)
    assert is_pid(new_pid)
    refute new_pid == pid

    # the delta set is rebuilt via replay
    assert DeltaSet.member?(DurableStore.set(), id)
    assert DurableStore.replay_report() == %{refused: [], torn: [], failed_appends: 0}

    # baseline restored for the next test
    Application.put_env(:kyber, :log_path, config_log_path)
  end

  # ------------------------------------------------------------------ P5

  test "P5: the durable path refuses non-conforming envelopes at the door and writes nothing",
       %{tmp_dir: tmp_dir, config_log_path: config_log_path} do
    path = Path.join(tmp_dir, "log.jsonl")
    Application.put_env(:kyber, :log_path, path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    # hand-built maps that BYPASS Wire.encode (a caller could construct
    # them): the door's Profile validation is the persist-time strictness
    # line — both must be refused with nothing written (P5 low finding 3)
    atom_keyed_claims = %{"id" => "x", "claims" => %{timestamp: 1.0}, "sig" => "y"}

    malformed_target =
      %{
        "id" => "x",
        "claims" => %{
          "timestamp" => 1.0,
          "author" => "ed25519:abc",
          "pointers" => [%{"role" => "r", "target" => %{"bad" => 1}}]
        },
        "sig" => "y"
      }

    assert {:error, _} = DurableStore.append(atom_keyed_claims)
    assert {:error, _} = DurableStore.append(malformed_target)

    # nothing was persisted — the lazy-open log was never created
    refute File.exists?(path)

    :ok = stop_app()
    Application.put_env(:kyber, :log_path, config_log_path)
  end
end
