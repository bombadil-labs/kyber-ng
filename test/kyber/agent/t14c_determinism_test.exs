defmodule Kyber.Agent.T14cDeterminismTest do
  @moduledoc """
  T14c AC5 — determinism: prompt assembly, memory-gate decisions, and
  attestation all derive from store state; no wall-clock in decisions. A
  DEDICATED two-sequential-cold-boot file (P1's pin): two fresh boots over
  the identical seed sequence produce the IDENTICAL `PromptAssembled` id,
  the IDENTICAL `GateDecision` id for a re-dispatched gated call, and the
  IDENTICAL `BootAttestation` id — and the delta count is unchanged.
  Non-emptiness guards on every id set (Fails-when-absent: wall-clock or
  random input makes ids differ or the count grow; a missing feature makes
  the id sets empty and the guards fail).

  Seeding (D7): tmp DurableStore dir + tmp keyring per boot (never
  `~/.kyber`); FIXED 64-hex agent seed (imported through `KYBER_SEED` on
  first load — `Keys.load_agent_seed/1`) + fixed operator seed; the oracle
  seed claim, the memory epoch, and the memory canon at fixed ts; derived
  events claim their triggering delta's timestamp; the gated call is a
  SEEDED `ToolCall` at a fixed ts (an engine-emitted call would claim
  wall-clock — the gate decision's ts rides the call's); quiescence via
  `assert_receive/3` + explicit store scans, never `Process.sleep`.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Action, Events, LlmHandler, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
  @oracle_seed_ts 1_700_000_000_000.0

  # a deterministic content-only answer — the engine never plans a call of
  # its own (the gated call is seeded with a fixed ts)
  defmodule StubLlm do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, _state) do
      body =
        JSON.encode!(%{
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "deterministic answer"}
            }
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # bounded sleep-free store polling (the no-sleep idiom: a timeout-only
  # receive never matches mailbox messages, so it cannot swallow probes)
  defp settle_store(attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      first = map_size(DurableStore.set())

      receive do
      after
        25 -> :timeout
      end

      second = map_size(DurableStore.set())

      if first == second do
        {:halt, first}
      else
        {:cont, nil}
      end
    end)
  end

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

  defp resolve({_id, {claims, _sig}}), do: Schema.resolve(claims)

  # one full cold boot: fresh store + fresh keyring (fixed seeds), the
  # complete seam sequence, and the collected deterministic ids
  defp cold_boot do
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14c-det-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14c-det-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    System.put_env("KYBER_SEED", @agent_seed)
    :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)

    stop_app()
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    {:ok, _} = Application.ensure_all_started(:kyber)

    try do
      {:ok, llm} =
        LlmHandler.new(
          seed: @agent_seed,
          api_key: "stub-key",
          http: {StubLlm, nil},
          model: "stub-model"
        )

      tools =
        Map.merge(Action.registry(), ToolExecutor.memory_tools(fn -> DurableStore.set() end))

      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          operator_seed: @operator_seed,
          budget_cap: 32,
          test_pid: self(),
          engine: [
            llm: llm,
            tools: tools,
            gate: Gate.new(allow: ["memory.read"]),
            context: Action.context(workspace: Path.join(log_dir, "ws"))
          ]
        )

      # the memory canon + the governing epoch, at fixed ts — BEFORE any
      # model turn
      {:ok, {mem_claims, mem_sig}} =
        Events.memory_entity(@agent_seed, @oracle_seed_ts + 1, "e1", "deterministic canon", [])

      mem_id = Delta.id_hex(mem_claims)
      :ok = DurableStore.append(Wire.envelope({mem_claims, mem_sig}))

      {:ok, {epoch_claims, epoch_sig}} =
        Events.memory_policy(@agent_seed, @oracle_seed_ts + 2, ["e1"])

      epoch_id = Delta.id_hex(epoch_claims)
      :ok = DurableStore.append(Wire.envelope({epoch_claims, epoch_sig}))

      # the turn: a fixed received fires the builder, then the engine
      # assembles + stores the prompt
      {:ok, {received_claims, received_sig}} =
        Kyber.Events.message_received(
          String.duplicate("cd", 32),
          @oracle_seed_ts + 3,
          "message:t14c:determinism",
          "channel:reactor",
          "session:reactor",
          "deterministic prompt"
        )

      received_id = Delta.id_hex(received_claims)
      :ok = DurableStore.append(Wire.envelope({received_claims, received_sig}))
      assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 5_000

      # the assembled prompt: wait for the PromptAssembled, recover the
      # request id from its requestRef pointer
      assembled =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(%{type: "PromptAssembled"}, Schema.resolve(claims))
        end)

      assert assembled != nil, "no PromptAssembled in boot"
      {pa_id, {pa_claims, _pa_sig}} = assembled

      %{type: "PromptAssembled", requestRef: {:delta, request_id, "prompted"}} =
        Schema.resolve(pa_claims)

      # the re-dispatched gated call: a SEEDED memory.read ToolCall at a
      # fixed ts — the decision's id rides the call's timestamp
      {:ok, {call_claims, call_sig}} =
        Events.tool_call(
          @agent_seed,
          @oracle_seed_ts + 4,
          "memory.read",
          JSON.encode!(%{"entity" => "e1"}),
          request_id
        )

      call_id = Delta.id_hex(call_claims)
      :ok = DurableStore.append(Wire.envelope({call_claims, call_sig}))

      decision =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(
            %{type: "GateDecision", decides: {:delta, ^call_id, _}},
            Schema.resolve(claims)
          )
        end)

      assert decision != nil, "no GateDecision for the seeded call in boot"
      {gd_id, {gd_claims, _gd_sig}} = decision
      assert Schema.resolve(gd_claims).verdict == "allow"

      # the operator boot attestation, emitted at reactor init
      attestation =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(%{type: "BootAttestation"}, Schema.resolve(claims))
        end)

      assert attestation != nil, "no BootAttestation in boot"
      {ba_id, {ba_claims, _ba_sig}} = attestation

      # non-emptiness guards (Fails-when-absent: empty id sets fail here)
      assert is_binary(pa_id) and byte_size(pa_id) > 0
      assert is_binary(gd_id) and byte_size(gd_id) > 0
      assert is_binary(ba_id) and byte_size(ba_id) > 0
      assert pa_id != gd_id and gd_id != ba_id and pa_id != ba_id

      %{
        pa_id: pa_id,
        gd_id: gd_id,
        ba_id: ba_id,
        count: settle_store(),
        pa_ts: pa_claims.timestamp,
        gd_ts: gd_claims.timestamp,
        ba_ts: ba_claims.timestamp
      }
    after
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end
  end

  test "AC5: two sequential cold boots — identical PromptAssembled / GateDecision / BootAttestation ids, delta count unchanged" do
    first = cold_boot()
    second = cold_boot()

    # identical content addresses: the three seam claims derive entirely
    # from store state (fixed seeds, fixed timestamps)
    assert first.pa_id == second.pa_id
    assert first.gd_id == second.gd_id
    assert first.ba_id == second.ba_id

    # delta count unchanged across the two boots
    assert first.count == second.count

    # no wall-clock in the decisions: every pinned claim's ts equals its
    # triggering delta's fixed timestamp
    assert first.pa_ts == @oracle_seed_ts + 3
    assert first.gd_ts == @oracle_seed_ts + 4
    assert first.ba_ts == @oracle_seed_ts
  end
end
