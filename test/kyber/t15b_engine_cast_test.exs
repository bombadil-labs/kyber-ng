defmodule Kyber.T15bEngineCastTest do
  @moduledoc """
  T15b — the daemon-boot engine gap.

  A :reactor daemon booted through Daemon.boot (the real boot path, as Wisp
  uses) must actually run the model when a `received` delta arrives. The bug:
  Daemon.boot defaulted engine: to :none, so the reactor's delegate_to_engine
  hit a nil engine and the model was never called — the InferenceRequested
  fired but no ResponseDelta landed.

  Mirrors the AC4 operational shape: Harness.ingest a received delta, assert
  the injected (stubbed) engine is actually invoked (its HTTP adapter
  captures the request body) and a ResponseDelta is persisted.
  """
  use ExUnit.Case, async: false

  # The engine round-trip is load-sensitive: the test's own wait budget (60s
  # assert_receive + up to 60s poll) exceeds ExUnit's 60s default per-test
  # timeout, so under full-suite load a late-landing ResponseDelta would be
  # killed as an ExUnit.TimeoutError instead of failing the assertion. Same
  # pattern as the repo's other load-sensitive suites
  # (reactor_operational_test, daemon_smoke_test, memory_assoc_operational_test).
  @moduletag timeout: 300_000

  alias Kyber.{Daemon, Harness, Keys}
  alias Kyber.Agent.LlmHandler

  @seed String.duplicate("ab", 32)
  @prompt_marker "T15B_MARKER_<%= 1 + 1 %>"

  describe "daemon-boot :reactor loop runs the model (AC1)" do
    test "a received delta yields a ResponseDelta via the engine" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15b-key-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t15b-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join(log_dir, "store.jsonl")

      # a stub HTTP that records the call and answers a canned response
      defmodule T15bCaptureHttp do
        @behaviour Kyber.Agent.HttpClient
        @impl true
        def post(_url, _headers, body, %{reply_to: pid}) do
          send(pid, {:t15b_body, JSON.decode!(body)})
          {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "wisp: hi back"}}]})}}
        end
      end

      {:ok, llm} =
        LlmHandler.new(
          seed: @seed,
          api_key: "test-key-not-real",
          http: {T15bCaptureHttp, %{reply_to: self()}}
        )

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)

      on_exit(fn ->
        Daemon.stop()
        Application.stop(:kyber)
        Application.put_env(:kyber, :log_path, config_log_path)
        File.rm_rf(key_dir)
        File.rm_rf(log_dir)
      end)

      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          engine: [llm: llm, tools: []]
        )

      # the reactor fires on the store's post-commit ingest cast
      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:t15b:1",
            "channel_id" => "channel:t15b",
            "session_id" => "session:t15b",
            "content" => @prompt_marker,
            "ts" => 1_754_600_000_000
          },
          key_dir
        )

      # the engine must actually be invoked
      assert_receive {:t15b_body, _body}, 60_000

      # and the answer must land in the store as a ResponseDelta. The poll
      # RE-CHECKS until found (a one-shot halt after a timeout-only receive
      # false-negatives when the delta lands past the first ~2s window under
      # full-suite load — the repo's no-sleep idiom: `{:cont, _}` after a
      # timeout-only receive, bounded attempts).
      answered =
        Enum.reduce_while(1..120, false, fn _, _ ->
          if Enum.any?(Kyber.DurableStore.set(), fn {_id, {claims, _sig}} ->
               case Kyber.Schema.resolve(claims) do
                 %{type: "ResponseDelta"} -> true
                 _other -> false
               end
             end) do
            {:halt, true}
          else
            receive do
            after
              500 -> :timeout
            end

            {:cont, false}
          end
        end)

      assert answered
    end
  end

  describe "default-boot handler resolves non-nil LLM defaults (T15b regression)" do
    # ADLC adversarial review (P5, PR #5) caught: Reactor.llm_for/2 passed
    # `base_url: nil` etc. when opts omitted those keys, which overrode
    # LlmHandler.new's @base_url/@model/@system_prompt fallbacks — breaking
    # default `kyber daemon` boots (nil base_url/model/system_prompt).
    test "absent model/base_url/system_prompt fall back to LlmHandler defaults" do
      {:ok, handler} = Kyber.Agent.Reactor.llm_for(@seed, [api_key: "test-key-not-real"])

      refute is_nil(handler.base_url)
      refute is_nil(handler.model)
      refute is_nil(handler.system_prompt)
      # the defaults must be the kyber substrate persona, not nil/empty
      assert handler.base_url == "https://api.moonshot.ai/v1"
      assert handler.model == "kimi-k3"
      assert handler.system_prompt =~ "claims substrate"
    end

    test "explicit model/base_url override the defaults (no regression)" do
      {:ok, handler} =
        Kyber.Agent.Reactor.llm_for(@seed,
          api_key: "test-key-not-real",
          model: "deepseek/deepseek-v4-flash-0731",
          base_url: "https://inference-api.nousresearch.com/v1"
        )

      assert handler.model == "deepseek/deepseek-v4-flash-0731"
      assert handler.base_url == "https://inference-api.nousresearch.com/v1"
    end
  end
end
