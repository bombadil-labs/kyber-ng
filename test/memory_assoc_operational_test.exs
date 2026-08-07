defmodule Kyber.Agent.MemoryAssocOperationalTest do
  @moduledoc """
  T13 AC4 — THE gate: the recorded operational run (Hermes's job, the T11b
  precedent — `mix test` never executes it; set `KYBER_OPERATIONAL=1` and
  `MOONSHOT_API_KEY` to run it live).

  Tmp store/keyring, REAL model, retriever `%{store: …, assoc: true}`. Two
  sessions are seeded with related memories (fixture strings pinned
  verbatim): sessA's MemoryEntity "relay deploy pinned to commit 9f2ac4",
  sessB's "relay deploy notes". The sessB prompt — "what commit is the
  relay deploy pinned to?" — must ground in sessA's memory.

  Machine-checked, both levels (post-premortem hardening — the original
  assertions were satisfiable by the T11c precision path alone, so AC4
  could not detect the associative mode being deleted):
    1. the sessB `InferenceRequested`'s memoryPointers includes sessA's
       canon head **via the ASSOCIATION channels** — `associations.divergent`
       specifically (the cross-session rare-link channel), which is empty
       by construction with `assoc: false`;
    2. the recorded request body carries a `Memory: <sessA canon content>`
       system message, byte-equal.
  The recording is preserved: the store jsonl is copied to a stable path
  before the tmp dirs are removed.

  Answer-groundedness is a recorded live-run observation, never asserted
  (the T11b C2 fix) — the model's answer is printed for the record.
  """
  use ExUnit.Case, async: false

  @moduletag :operational
  @moduletag timeout: 300_000

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Schema, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Assoc.Saturation
  alias Kyber.Agent.Memory.Retriever

  @memory_a "relay deploy pinned to commit 9f2ac4"
  @memory_b "relay deploy notes"
  @prompt "what commit is the relay deploy pinned to?"
  @session_a "session:relay:a"
  @session_b "session:relay:b"

  defmodule RecordingHttp do
    @moduledoc "The real :httpc adapter with the request body teed to the test."
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(url, headers, body, %{reply_to: pid}) do
      send(pid, {:llm_request_body, body})
      Kyber.Agent.HttpClient.Httpc.post(url, headers, body, nil)
    end
  end

  test "AC4: the associative mode surfaces the cross-session memory into a real model turn" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts("skipped: set KYBER_OPERATIONAL=1 (and MOONSHOT_API_KEY) to run the live gate")
    else
      api_key = System.fetch_env!("MOONSHOT_API_KEY")

      # ---- tmp keyring + tmp store, the agent_daemon_test choreography
      key_dir =
        Path.join(System.tmp_dir!(), "kyber-t13-keyring-#{System.unique_integer([:positive])}")

      log_dir =
        Path.join(System.tmp_dir!(), "kyber-t13-log-#{System.unique_integer([:positive])}")

      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)
      {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
      {:ok, _} = Application.ensure_all_started(:kyber)

      on_exit(fn ->
        Daemon.stop()
        Application.stop(:kyber)
        Application.put_env(:kyber, :log_path, config_log_path)
        File.rm_rf(key_dir)
        File.rm_rf(log_dir)
      end)

      # the recording is preserved (post-premortem): copy the store jsonl
      # to a stable path before on_exit removes the tmp dirs
      recording_path =
        Path.join(
          System.tmp_dir!(),
          "kyber-t13-ac4-record-#{System.unique_integer([:positive])}.jsonl"
        )

      {:ok, _pid} = Daemon.boot(keyring_dir: key_dir, tick_ms: :manual, loop: :none)

      # ---- seed BOTH sessions before attaching (no model turn fires here)
      ingest = fn n, session, content ->
        {:ok, id} =
          Harness.ingest(
            %{
              "message_id" => "message:relay:#{n}",
              "channel_id" => "channel:relay",
              "session_id" => session,
              "content" => content,
              "ts" => 1_754_600_000_000 + n
            },
            key_dir
          )

        id
      end

      recv_a = ingest.(1, @session_a, "pin the relay deploy")
      recv_b = ingest.(2, @session_b, "keep notes on the relay deploy")

      remember = fn ts, entity, content, sources ->
        {:ok, signed} = AgentEvents.memory_entity(agent_seed, ts, entity, content, sources)
        {:ok, _} = Daemon.emit(Wire.envelope(signed))
      end

      remember.(1_754_600_000_100, "mem:relay:pin", @memory_a, [recv_a])
      remember.(1_754_600_000_200, "mem:relay:notes", @memory_b, [recv_b])

      head_a = Memory.canon(DurableStore.set(), "mem:relay:pin").head

      # ---- the REAL model behind the recording adapter, assoc retriever
      {:ok, llm} =
        Kyber.Agent.LlmHandler.new(
          seed: agent_seed,
          api_key: api_key,
          http: {RecordingHttp, %{reply_to: self()}}
        )

      {:ok, _engine, _report} =
        Kyber.Agent.attach(
          keyring_dir: key_dir,
          llm: llm,
          notify: self(),
          memory: {Retriever, %{store: fn -> DurableStore.set() end, assoc: true}}
        )

      # ---- the sessB question whose answer lives in sessA's memory
      ingest.(3, @session_b, @prompt)

      assert_receive {:engine, {:answered, request_id}}, 240_000

      set = DurableStore.set()

      # level 1 — the sessB InferenceRequested's memoryPointers includes
      # sessA's canon head VIA THE ASSOCIATION CHANNELS (post-premortem:
      # the precision path alone must not satisfy this — recompute the
      # prefetch and require the head in the divergent channel, which is
      # empty by construction without the associative mode)
      {request_claims, _sig} = Map.get(set, request_id)
      request = Schema.resolve(request_claims)
      assert {:entity, @session_b, _ctx} = request.sessionId
      pointer_ids = for {:delta, id, _ctx} <- request.memoryPointers, do: id
      assert head_a in pointer_ids

      prefetch = Saturation.prefetch(set, @session_b, @prompt)
      assert head_a in prefetch.divergent
      assert prefetch.divergent != []

      # level 2 — the recorded request body carries the Memory system
      # message, byte-equal
      assert_receive {:llm_request_body, body}
      %{"messages" => messages} = JSON.decode!(body)
      assert %{"role" => "system", "content" => "Memory: " <> @memory_a} in messages

      # answer-groundedness: recorded observation, never asserted (T11b C2)
      answer =
        Enum.find_value(set, fn {_id, {claims, _sig}} ->
          case Schema.resolve(claims) do
            %{type: "ResponseDelta", requestRef: {:delta, ^request_id, _}, content: content} ->
              content

            _other ->
              nil
          end
        end)

      IO.puts("AC4 recorded answer: #{inspect(answer)}")

      # preserve the recording before on_exit cleans the tmp dirs
      File.cp!(Path.join(log_dir, "store.jsonl"), recording_path)
      IO.puts("AC4 recording preserved at: #{recording_path}")
    end
  end
end
