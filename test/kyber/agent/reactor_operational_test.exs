defmodule Kyber.Agent.ReactorOperationalTest do
  @moduledoc """
  T14a AC4 — the live gate (pin 22): the AC4 choreography runs WITHOUT
  ticks — a real model turn answers end-to-end through the reactor (loop:
  :reactor, no Daemon.tick anywhere), recording preserved. @moduletag
  :operational — `mix test` never executes it; set KYBER_OPERATIONAL=1 and
  MOONSHOT_API_KEY to run it live.

  Machine-checked, request-body side ONLY (never the answer content):
    (a) the seeded prompt marker verbatim in `body["messages"]`;
    (b) `body["model"]` == the configured id;
    (c) exactly one recorded request (a tool-less turn — the model sees no
        tools, so no tool loop can re-plan a second call);
    (d) answer-delta EXISTENCE via bounded sleep-free store polling;
    (e) recording-file existence ("recording preserved");
    (f) store-count monotonicity — nothing deleted (P3).

  The ordered five-kind chain topology is a logged observation, never an
  assertion (a tool-less turn legitimately skips hops — A3/R16). The gate
  configuration never produces an allow-verdict GateDecision reaching the
  engine's decides path (tool-less turn + default-deny with no
  explicit-allow policy), so the M5 verdict string-vs-atom crash is not
  tripped (recorded contradiction, not silently fixed here).
  """
  use ExUnit.Case, async: false

  @moduletag :operational
  @moduletag timeout: 300_000

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Schema}
  alias Kyber.Agent.LlmHandler

  @prompt_marker "AC4 reactor live run: reply with exactly the words 'reactor live ok' and use no tools."
  @model_id "kimi-k3"

  defmodule RecordingHttp do
    @moduledoc "The real :httpc adapter with the request body teed to the test."
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(url, headers, body, %{reply_to: pid}) do
      send(pid, {:llm_request_body, body})
      Kyber.Agent.HttpClient.Httpc.post(url, headers, body, nil)
    end
  end

  test "AC4: a real model turn answers end-to-end without ticks, recording preserved" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts("skipped: set KYBER_OPERATIONAL=1 (and MOONSHOT_API_KEY) to run the live gate")
    else
      api_key = System.fetch_env!("MOONSHOT_API_KEY")

      # tmp keyring + tmp store (the agent_daemon_test choreography); the
      # real ~/.kyber is never touched
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t14a-keyring-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t14a-log-#{uniq}")
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

      # the recording is preserved (e): copied to a stable path before the
      # tmp dirs are removed
      recording_path =
        Path.join(
          System.tmp_dir!(),
          "kyber-t14a-ac4-record-#{System.unique_integer([:positive])}.jsonl"
        )

      # H6: the ONLY way an LLM enters the reactor — the recording adapter +
      # real key through the engine boot opt
      {:ok, llm} =
        LlmHandler.new(
          seed: agent_seed,
          api_key: api_key,
          http: {RecordingHttp, %{reply_to: self()}},
          model: @model_id
        )

      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          # a tool-less turn by construction: the model sees no tools
          engine: [llm: llm, tools: []]
        )

      # a real turn — NO ticks anywhere in this file: the reactor fires on
      # the store's post-commit ingest cast
      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:reactor:ac4",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" => @prompt_marker,
            "ts" => 1_754_600_000_000
          },
          key_dir
        )

      size_before = map_size(DurableStore.set())

      # (a)/(b): the machine-checked property targets the request body —
      # the seeded prompt marker verbatim, the configured model id
      assert_receive {:llm_request_body, body}, 60_000
      %{"messages" => messages, "model" => model} = JSON.decode!(body)
      assert model == @model_id
      assert Enum.any?(messages, &match?(%{"role" => "user", "content" => @prompt_marker}, &1))

      # (c): exactly one recorded request (the tool-less turn cannot re-plan)
      refute_receive {:llm_request_body, _body}, 300

      # (d): answer-delta EXISTENCE via bounded sleep-free store polling
      # (assert_receive/3-style receive-after, never Process.sleep)
      answered =
        Enum.reduce_while(1..120, false, fn _, _ ->
          if Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               case Schema.resolve(claims) do
                 %{type: "ResponseDelta"} -> true
                 _other -> false
               end
             end) do
            {:halt, true}
          else
            receive do
            after
              2_000 -> :timeout
            end

            {:cont, false}
          end
        end)

      assert answered, "the live turn never produced a ResponseDelta"

      # the chain topology: logged observation, never an assertion (a
      # tool-less turn legitimately skips hops)
      kinds =
        DurableStore.set()
        |> Enum.map(fn {_id, {claims, _sig}} -> hd(claims.pointers).role end)
        |> Enum.sort()

      IO.puts("AC4 chain observed (kinds): #{inspect(kinds)}")

      # (f): store-count monotonicity — nothing deleted (P3)
      size_after = map_size(DurableStore.set())
      assert size_after >= size_before

      # the answer content is a recorded observation, never asserted (AC4:
      # "targets the request body, never the answer content")
      answer =
        Enum.find_value(DurableStore.set(), fn {_id, {claims, _sig}} ->
          case Schema.resolve(claims) do
            %{type: "ResponseDelta", content: content} -> content
            _other -> nil
          end
        end)

      IO.puts("AC4 recorded answer: #{inspect(answer)}")

      # (e): the recording is preserved
      File.cp!(Path.join(log_dir, "store.jsonl"), recording_path)
      assert File.exists?(recording_path)
      IO.puts("AC4 recording preserved at: #{recording_path}")
    end
  end
end
