defmodule Kyber.Agent.T19OracleSeedBootTest do
  @moduledoc """
  T19 round-3 — the boot-time oracle seed assertion (`oracle_seed: :present`).

  Two properties, both read off store state: the assert is idempotent (a
  second boot against a store that already holds a live seed claim appends
  nothing), and it re-opens after a retraction (a store whose only seed
  claim is retracted gets a NEW claim at a fresh timestamp, so the
  retraction cannot absorb it and the reactor's gate is open again).

  Same discipline as reactor_test: tmp store + tmp keyring per test,
  `tick_ms: :manual`, no `Process.sleep`.
  """

  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Keys, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @oracle_seed_ts 1_700_000_000_000.0

  setup do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)

    uniq = "#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    key_dir = Path.join(keyring_dir, "kyber-t19os-key-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t19os-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    stop_app()
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp boot!(ctx) do
    assert {:ok, _pid} =
             Daemon.boot(
               keyring_dir: ctx.keyring_dir,
               tick_ms: :manual,
               loop: :reactor,
               oracle_seed: :present,
               budget_cap: 32,
               test_pid: self()
             )
  end

  defp seed_claims do
    for {id, {claims, _sig}} <- DurableStore.set(),
        match?([%{role: "seed"} | _rest], claims.pointers),
        do: {id, claims}
  end

  defp signed_wire(seed, pointers, ts) do
    raw = %{timestamp: ts, author: Keys.author_for_seed(seed), pointers: pointers}
    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, seed)
    Wire.envelope({claims, sig})
  end

  test "two boots against the same store append exactly ONE seed claim", ctx do
    boot!(ctx)
    assert [{first_id, first_claims}] = seed_claims()
    assert first_claims.timestamp == @oracle_seed_ts

    Daemon.stop()
    boot!(ctx)

    # the second boot found the live claim and appended nothing
    assert [{^first_id, _claims}] = seed_claims()
  end

  test "a retracted seed re-opens the gate with a NEW claim at a fresh ts", ctx do
    boot!(ctx)
    assert [{retracted_id, _claims}] = seed_claims()

    neg =
      signed_wire(
        ctx.agent_seed,
        [%{role: "negates", target: {:delta, retracted_id, "retracted"}}],
        1_754_600_000_000.0
      )

    assert :ok = DurableStore.append(neg)

    Daemon.stop()
    boot!(ctx)

    # the fixed-content id is taken by the retracted claim, so the re-assert
    # mints a distinct one at a fresh ts
    claims_by_id = Map.new(seed_claims())
    assert map_size(claims_by_id) == 2
    assert [live_id] = Map.keys(claims_by_id) -- [retracted_id]
    assert claims_by_id[live_id].timestamp != @oracle_seed_ts

    refute Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
             Enum.any?(
               claims.pointers,
               &match?(%{role: "negates", target: {:delta, ^live_id, _ctx}}, &1)
             )
           end)

    # the gate is open: model initiation proceeds instead of refusing
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        1_754_600_100_000,
        "message:t19os:reopen",
        "channel:reactor",
        "session:reactor",
        "gate reopened"
      )

    wire = Wire.envelope(signed)
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    assert poll_store(fn {_id, {claims, _sig}} ->
             match?(
               [%{role: "promptRef", target: {:delta, ^received_id, "requested"}} | _rest],
               claims.pointers
             )
           end)
  end

  # bounded sleep-free store polling: a timeout-only receive never matches
  # mailbox messages, so it cannot swallow reactor probes
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
end
