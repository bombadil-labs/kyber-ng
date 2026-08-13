defmodule Kyber.T15cSendDedupTest do
  @moduledoc """
  T15c — collapse re-sent operator messages (the "triple-send" artifact).

  A `ctl send` of identical content to an UNANSWERED message must not mint a
  second MessageReceived / spawn a second turn. After Wisp answers, a re-send
  of the same content IS allowed (legitimate re-ask).

  Event-driven: a gated stub freezes the first turn "unanswered" so the dedup
  window is deterministic, then signals completion (:t15c_replied) so the
  re-ask is gated on the reply event (no timers for polling).
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, Keys}
  alias Kyber.Agent.LlmHandler
  alias Kyber.CLI.TUI

  @seed String.duplicate("ab", 32)
  @content "T15C_DEDUP_MARKER"

  # module-level capture http for the retry-then-answer test (define at the
  # top so it is always compiled, unlike a defmodule nested in a test body)
  defmodule T15cCaptureHttpR do
    @behaviour Kyber.Agent.HttpClient
    @impl true
    def post(_url, _headers, _body, %{reply_to: pid}) do
      send(pid, {:t15cR_called, self()})
      receive do: (:t15cR_proceed -> :ok)
      send(pid, {:t15cR_replied, self()})
      {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "ok"}}]})}}
    end
  end

  describe "re-sent identical operator message is collapsed (AC1)" do
    test "duplicate before reply collapses; re-ask after reply is allowed" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15c-key-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t15c-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join(log_dir, "store.jsonl")
      socket_path = log_path <> ".sock"

      # gated stub: signals the test (with its own pid), then blocks until
      # :t15c_proceed before returning the canned response; after the response
      # is produced it signals :t15c_replied so the test can gate the re-ask
      # on the reply event (no timers).
      defmodule T15cCaptureHttp do
        @behaviour Kyber.Agent.HttpClient
        @impl true
        def post(_url, _headers, _body, %{reply_to: pid}) do
          send(pid, {:t15c_called, self()})
          receive do: (:t15c_proceed -> :ok)
          result = {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "wisp reply"}}]})}}
          send(pid, {:t15c_replied, self()})
          result
        end
      end

      {:ok, llm} =
        LlmHandler.new(seed: @seed, api_key: "test-key-not-real", http: {T15cCaptureHttp, %{reply_to: self()}})

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)
      Daemon.stop()

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
          loop: :reactor,
          oracle_seed: :present,
          operator_seed: @seed,
          channel_socket: :default,
          engine: [llm: llm, tools: []]
        )

      # readiness gate: wait for the channel socket to bind (one-time startup)
      Process.sleep(200)

      # three identical rapid sends while the turn is frozen unanswered
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)

      # exactly ONE engine invocation: the two duplicates produced no turns
      assert_receive {:t15c_called, stub1}, 30_000
      refute_receive :t15c_called, 1_000

      # unblock the frozen turn so Wisp "replies", then gate the re-ask on the
      # reply event (not a timer)
      send(stub1, :t15c_proceed)
      assert_receive {:t15c_replied, _}, 30_000

      # re-ask the SAME content now that it's answered -> MUST be allowed
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)
      assert_receive {:t15c_called, stub2}, 30_000
      send(stub2, :t15c_proceed)
      assert_receive {:t15c_replied, _}, 30_000

      # exactly two MessageReceived in the store: original + one collapsed
      # duplicate (before reply) + one allowed re-ask (after reply). The two
      # engine invocations (stub1, stub2 both :t15c_called + :t15c_replied
      # above) prove the re-ask spawned a real second turn.
      store = File.read!(log_path)
      assert length(Regex.scan(~r/"MessageReceived"/, store)) == 2
    end
  end

  describe "stale failed-turn MessageReceived does NOT block re-send (P5 fix)" do
    @tag :capture_log
    test "an unanswered message whose inference failed/timeout is re-sendable" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15c-key-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t15c-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join(log_dir, "store.jsonl")
      socket_path = log_path <> ".sock"

      defmodule T15cCaptureHttp2 do
        @behaviour Kyber.Agent.HttpClient
        @impl true
        def post(_url, _headers, _body, %{reply_to: pid}) do
          send(pid, {:t15c2_called, self()})
          receive do: (:t15c2_proceed -> :ok)
          send(pid, {:t15c2_replied, self()})
          {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "ok"}}]})}}
        end
      end

      {:ok, llm} =
        LlmHandler.new(seed: @seed, api_key: "test-key-not-real", http: {T15cCaptureHttp2, %{reply_to: self()}})

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)
      Daemon.stop()

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
          loop: :reactor,
          oracle_seed: :present,
          operator_seed: @seed,
          channel_socket: :default,
          engine: [llm: llm, tools: []]
        )

      Process.sleep(200)

      # Simulate a FAILED prior turn: a stale (> window) unanswered
      # MessageReceived with identical content, as if the inference crashed /
      # timed out and never wrote a ResponseDelta. ADLC P5 flagged that the
      # old dedup would swallow all future identical re-sends forever.
      stale_ts = System.system_time(:millisecond) - 60_000
      {:ok, signed} = Kyber.Events.message_received(@seed, stale_ts, "msg:stale-t15c", "channel:tui", "session:tui", @content)
      :ok = Kyber.DurableStore.append(Kyber.Wire.envelope(signed))

      before = length(Regex.scan(~r/"MessageReceived"/, File.read!(log_path)))

      # the re-send MUST NOT be collapsed (the stale one is not "open")
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)
      assert_receive {:t15c2_called, _}, 30_000

      after_count = length(Regex.scan(~r/"MessageReceived"/, File.read!(log_path)))
      assert after_count == before + 1, "stale failed-turn message must be re-sendable (not collapsed)"
    end
  end

  describe "retry-then-answer does NOT drop a re-send (P5 round-4 high fix)" do
    @tag :capture_log
    test "a message with a failed inference + a succeeded retry is answered (not collapsed)" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15c-key-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t15c-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join(log_dir, "store.jsonl")
      socket_path = log_path <> ".sock"

      {:ok, llm} =
        LlmHandler.new(seed: @seed, api_key: "test-key-not-real",
          http: {T15cCaptureHttpR, %{reply_to: self()}})

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)
      Daemon.stop()

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
          loop: :reactor,
          oracle_seed: :present,
          operator_seed: @seed,
          channel_socket: :default,
          engine: [llm: llm, tools: []]
        )

      Process.sleep(200)

      ts = System.system_time(:millisecond)
      msg_id = "msg:retry-R"
      inf1 = "inf:retry-1"
      inf2 = "inf:retry-2"

      {:ok, signed_msg} =
        Kyber.Events.message_received(@seed, ts, msg_id, "channel:tui", "session:tui", @content)
      wire_msg = Kyber.Wire.envelope(signed_msg)
      msg_real_id = wire_msg["id"]
      :ok = Kyber.DurableStore.append(wire_msg)

      {:ok, signed_inf1} =
        Kyber.Agent.Events.inference_requested(@seed, ts, "deepseek", "session:tui", "conv:1", msg_real_id, [])
      :ok = Kyber.DurableStore.append(Kyber.Wire.envelope(signed_inf1))

      {:ok, signed_inf2} =
        Kyber.Agent.Events.inference_requested(@seed, ts, "deepseek", "session:tui", "conv:1", msg_real_id, [])
      # capture the content-derived delta id from the wire envelope so the
      # ResponseDelta's requestRef can point at it
      wire_inf2 = Kyber.Wire.envelope(signed_inf2)
      inf2_id = wire_inf2["id"]
      :ok = Kyber.DurableStore.append(wire_inf2)

      {:ok, signed_resp} =
        Kyber.Agent.Events.response_delta(@seed, ts, inf2_id, 1, "the answer", [])
      :ok = Kyber.DurableStore.append(Kyber.Wire.envelope(signed_resp))

      before = length(Regex.scan(~r/"MessageReceived"/, File.read!(log_path)))
      assert {:ok, %{"ok" => true}} = TUI.send_message(socket_path, @content)
      after_count = length(Regex.scan(~r/"MessageReceived"/, File.read!(log_path)))
      assert after_count == before + 1,
             "message with failed-then-succeeded inference must be treated as answered (re-send allowed)"
    end
  end
end
