defmodule Kyber.AgentDaemonTest do
  @moduledoc """
  T11b integration through the REAL daemon: the LLM stack attached with
  `loop: :none`, the stub HTTP adapter behind the handler, manual ticks.

  AC3 — re-boot idempotence WITH the LLM handler: kill between the answer
  and the checkpoint (the manufactured crash window), re-boot, and the
  exchange does NOT duplicate — the byte-identical `InferenceRequested`
  re-fire dedupes at the sink, the engine counts a skip instead of calling
  the model, and the answer persists exactly once.

  Carried addition 1 — the door/schema seam: a delta DECLARING a known
  lifecycle type is validated at the daemon's admission (ill-shaped refused,
  never repaired); unknown and undeclared deltas are raw admissions.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request, JSON.decode!(body)})

      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "choices" => [
               %{"index" => 0, "message" => %{"role" => "assistant", "content" => state.answer}}
             ]
           })
       }}
    end
  end

  setup_all do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)
    assert is_binary(keyring_dir)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
    end)

    {:ok, keyring_dir: keyring_dir}
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

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp fresh_dir(base, tag) do
    Path.join(base, "kyber-agent-#{tag}-#{System.unique_integer([:positive])}")
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  defp boot_stack!(ctx, answer) do
    assert {:ok, _pid} = Daemon.boot(keyring_dir: ctx.keyring_dir, tick_ms: :manual, loop: :none)

    {:ok, llm} =
      Kyber.Agent.LlmHandler.new(
        seed: ctx.agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: self(), answer: answer}}
      )

    assert {:ok, engine, resume_report} =
             Kyber.Agent.attach(keyring_dir: ctx.keyring_dir, llm: llm, notify: self())

    {engine, resume_report}
  end

  defp ingest!(ctx, content) do
    source = %{
      "message_id" => "message:cli:t11b:1",
      "channel_id" => "channel:cli:t11b",
      "session_id" => "session:cli:t11b",
      "content" => content,
      "ts" => 1_754_600_000_000
    }

    assert {:ok, id} = Harness.ingest(source, ctx.keyring_dir)
    id
  end

  defp claims_with_kind(kind) do
    DurableStore.set()
    |> Enum.filter(fn {_id, {claims, _sig}} -> hd(claims.pointers).role == kind end)
  end

  defp drop_checkpoints!(log_path) do
    kept =
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(fn line ->
        case JSON.decode(line) do
          {:ok, %{"claims" => %{"pointers" => [%{"role" => "checkpoint"} | _rest]}}} -> true
          _other -> false
        end
      end)

    File.write!(log_path, Enum.join(kept, "\n") <> "\n")
  end

  # -------------------------------------------------------------------- AC3

  test "AC3: the crash window with an in-flight LLM exchange dedupes on re-boot", ctx do
    {engine, %{resumed: 0, waiting: 0}} = boot_stack!(ctx, "The cap is a lens.")
    ingest!(ctx, "What is the cap?")

    # tick 1 dispatches the prompt: the builder fires, the request persists
    assert {:ok, %{fired: 1}} = Daemon.tick()
    assert [_request] = claims_with_kind("promptRef")

    # tick 2 dispatches the request: the engine answers asynchronously
    assert {:ok, _status} = Daemon.tick()
    assert_receive {:engine, {:answered, request_id}}, 2_000
    assert_receive {:llm_request, _body}

    assert [{^request_id, _element}] = claims_with_kind("promptRef")
    assert [_response] = claims_with_kind("requestRef")
    assert [_sent] = claims_with_kind("sent")

    # the crash: daemon and engine die; the checkpoints are LOST (the ack-
    # persisted / checkpoint-lost artifact, manufactured on the log)
    assert :ok = Daemon.stop()
    GenServer.stop(engine)
    stop_app()
    drop_checkpoints!(ctx.log_path)

    # re-boot on the same log with a FRESH stack (empty engine state)
    boot_on(ctx.log_path)
    {_engine2, %{resumed: 0, waiting: 0}} = boot_stack!(ctx, "A different answer entirely.")

    # one tick replays everything from cursor 0: the builder re-fires the
    # BYTE-IDENTICAL request (content-address skip at the sink), the engine
    # sees the persisted answer (a counted skip), the model is never called
    assert {:ok, status} = Daemon.tick()
    assert status.skipped >= 1
    assert_receive {:engine, {:skipped, ^request_id}}, 2_000
    refute_receive {:llm_request, _body}, 100

    # exactly one request, one response, one delivery — no duplicates
    assert [{^request_id, _element}] = claims_with_kind("promptRef")
    assert [{_id, {response_claims, _sig}}] = claims_with_kind("requestRef")
    assert [_sent] = claims_with_kind("sent")

    # and the ORIGINAL answer persists, not the re-booted stub's
    assert %{target: {:string, "The cap is a lens."}} =
             Enum.find(response_claims.pointers, &(&1.role == "content"))
  end

  # ------------------------------------------------- carried addition 1: door

  test "the door: a DECLARED ill-shaped delta is refused at admission, never repaired", ctx do
    boot_stack!(ctx, "unused")

    # declares MessageSent but misses its required roles — witness-valid,
    # schema-ill-shaped: the door refuses it
    raw = %{
      timestamp: 1_754_600_000_000.0,
      author: Keys.author_for_seed(ctx.agent_seed),
      pointers: [
        %{role: "content", target: {:string, "shaped wrong"}},
        %{role: "type", target: {:entity, "MessageSent", "instances"}}
      ]
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, ctx.agent_seed)
    wire = Wire.envelope({claims, sig})

    before = Kyber.DeltaSet.size(DurableStore.set())
    assert {:error, {:schema_refused, {:missing_role, _role}}} = Daemon.emit(wire)
    assert Kyber.DeltaSet.size(DurableStore.set()) == before
  end

  test "the door: unknown and undeclared types are raw admissions", ctx do
    boot_stack!(ctx, "unused")

    unknown = %{
      timestamp: 1_754_600_000_000.0,
      author: Keys.author_for_seed(ctx.agent_seed),
      pointers: [
        %{role: "whatever", target: {:string, "novel shape"}},
        %{role: "type", target: {:entity, "NoSuchType", "instances"}}
      ]
    }

    undeclared = %{
      timestamp: 1_754_600_000_001.0,
      author: Keys.author_for_seed(ctx.agent_seed),
      pointers: [%{role: "note", target: {:string, "an old-school raw delta"}}]
    }

    for raw <- [unknown, undeclared] do
      {:ok, claims} = Delta.validate(raw)
      {:ok, sig} = Keys.sign(claims, ctx.agent_seed)
      assert {:ok, :persisted} = Daemon.emit(Wire.envelope({claims, sig}))
    end
  end
end
