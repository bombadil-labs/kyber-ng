defmodule Kyber.T15ModelAndCtlTest do
  @moduledoc """
  T15 — agent I/O surface + model configurability (the Wisp slice).

  Unit-level (no network): LlmHandler system_prompt/base_url/model override,
  Prompt.system_prompt/0 app-env override, and the `ctl` client speaking the
  channel-socket JSONL protocol end-to-end against a real daemon boot.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys}
  alias Kyber.Agent.LlmHandler
  alias Kyber.CLI.TUI

  @seed String.duplicate("ab", 32)
  @api_key "test-key-not-real"

  describe "LlmHandler model + persona configurability (AC1)" do
    test "new/1 honors base_url / model / system_prompt overrides" do
      {:ok, h} =
        LlmHandler.new(
          seed: @seed,
          api_key: @api_key,
          base_url: "https://api.deepseek.com/v1",
          model: "deepseek-chat",
          system_prompt: "You are Wisp, a twitchy scout."
        )

      assert h.base_url == "https://api.deepseek.com/v1"
      assert h.model == "deepseek-chat"
      assert h.system_prompt == "You are Wisp, a twitchy scout."
    end

    test "new/1 defaults to k3 when no override supplied (backward-compatible)" do
      {:ok, h} = LlmHandler.new(seed: @seed, api_key: @api_key)
      assert h.base_url == "https://api.moonshot.ai/v1"
      assert h.model == "kimi-k3"
      assert h.system_prompt =~ "claims substrate"
    end

    test "the handler's system_prompt reaches the model via gather/2 (AC1)" do
      # a stub HTTP that captures the request body and answers a canned response
      defmodule CaptureHttp do
        @behaviour Kyber.Agent.HttpClient
        @impl true
        def post(_url, _headers, body, %{reply_to: pid}) do
          send(pid, {:body, JSON.decode!(body)})
          {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "wisp says hi"}}]})}}
        end
      end

      {:ok, h} =
        LlmHandler.new(
          seed: @seed,
          api_key: @api_key,
          system_prompt: "WISP VOICE",
          http: {CaptureHttp, %{reply_to: self()}}
        )

      received = %{
        id: "r1",
        claims: %{pointers: [%{role: "received", target: {:string, "hello"}},
                              %{role: "content", target: {:string, "hello"}}]}
      }

      {:ok, _} = LlmHandler.gather(h, [received])
      assert_receive {:body, body}, 5_000
      messages = body["messages"]
      assert hd(messages) == %{"role" => "system", "content" => "WISP VOICE"}
      assert Enum.any?(messages, &(&1 == %{"role" => "user", "content" => "hello"}))
    end
  end

  describe "Prompt.system_prompt/0 app-env override" do
    test "honors :kyber, :system_prompt when set, restores after" do
      prev = Application.get_env(:kyber, :system_prompt)
      Application.put_env(:kyber, :system_prompt, "OVERRIDE PROMPT")
      try do
        assert Kyber.Agent.Prompt.system_prompt() == "OVERRIDE PROMPT"
      after
        if prev == nil do
          Application.delete_env(:kyber, :system_prompt)
        else
          Application.put_env(:kyber, :system_prompt, prev)
        end
      end
      refute Kyber.Agent.Prompt.system_prompt() == "OVERRIDE PROMPT"
    end

    test "Daemon.boot(system_prompt:) threads the persona into Prompt.system_prompt/0 (AC1, P5)" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15-sp-key-#{uniq}")
      File.mkdir_p!(key_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join([System.tmp_dir!(), "kyber-t15-sp-log-#{uniq}", "store.jsonl"])
      File.mkdir_p!(Path.dirname(log_path))

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      prev_sp = Application.get_env(:kyber, :system_prompt)
      {:ok, _} = Application.ensure_all_started(:kyber)
      Daemon.stop()

      on_exit(fn ->
        Daemon.stop()
        Application.stop(:kyber)
        Application.put_env(:kyber, :log_path, config_log_path)
        if prev_sp == nil, do: Application.delete_env(:kyber, :system_prompt),
          else: Application.put_env(:kyber, :system_prompt, prev_sp)
        File.rm_rf(key_dir)
        File.rm_rf(Path.dirname(log_path))
      end)

      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default,
          system_prompt: "You are Wisp, a twitchy scout."
        )

      assert Kyber.Agent.Prompt.system_prompt() == "You are Wisp, a twitchy scout."
    end

    test "a default boot after a persona boot restores the kyber default (P5 fix)" do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15-spreset-key-#{uniq}")
      File.mkdir_p!(key_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join([System.tmp_dir!(), "kyber-t15-spreset-log-#{uniq}", "store.jsonl"])
      File.mkdir_p!(Path.dirname(log_path))

      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)
      Daemon.stop()

      on_exit(fn ->
        Daemon.stop()
        Application.stop(:kyber)
        Application.put_env(:kyber, :log_path, config_log_path)
        Application.delete_env(:kyber, :system_prompt)
        File.rm_rf(key_dir)
        File.rm_rf(Path.dirname(log_path))
      end)

      # first boot: Wisp persona
      {:ok, _} =
        Daemon.boot(
          keyring_dir: key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default,
          system_prompt: "You are Wisp, a twitchy scout."
        )

      assert Kyber.Agent.Prompt.system_prompt() == "You are Wisp, a twitchy scout."

      # second boot: default (no persona) — must NOT leak the Wisp persona
      Daemon.stop()

      {:ok, _} =
        Daemon.boot(
          keyring_dir: key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default
        )

      assert Kyber.Agent.Prompt.system_prompt() =~ "claims substrate"
    end
  end

  describe "ctl client over the channel socket (AC3)" do
    setup do
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t15-key-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t15-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@seed, key_dir)
      log_path = Path.join(log_dir, "store.jsonl")
      config_log_path = Application.get_env(:kyber, :log_path)
      Application.put_env(:kyber, :log_path, log_path)
      {:ok, _} = Application.ensure_all_started(:kyber)
      socket_path = log_path <> ".sock"

      on_exit(fn ->
        Daemon.stop()
        Application.stop(:kyber)
        Application.put_env(:kyber, :log_path, config_log_path)
        File.rm_rf(key_dir)
        File.rm_rf(log_dir)
      end)

      {:ok, log_path: log_path, socket_path: socket_path, key_dir: key_dir}
    end

    test "ctl status returns the daemon's status payload", ctx do
      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: ctx.key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default
        )

      Process.sleep(200)

      assert {:ok, map} = TUI.status(ctx.socket_path)
      assert Map.has_key?(map, "ok")
    end

    test "ctl send returns ok (or no_operator_seed) without crashing", ctx do
      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: ctx.key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default
        )

      Process.sleep(200)

      result = TUI.send_message(ctx.socket_path, "hello wisp")
      assert match?({:ok, %{"error" => "no_operator_seed"}}, result) or
             match?({:ok, %{"ok" => true}}, result)
    end

    @tag :ctl_binary
    test "ctl binary exits non-zero when the daemon returns an error (AC3, P5 fix)", ctx do
      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: ctx.key_dir,
          loop: :ack,
          narrate: false,
          channel_socket: :default
        )

      Process.sleep(200)

      escript = Path.join([File.cwd!(), "kyber"])
      {_out, exit_code} = System.cmd("escript", [escript, "ctl", "--log", ctx.log_path, "send", "hello wisp"])
      # a daemon that answers no_operator_seed must make the CLI fail, not exit 0
      assert exit_code != 0
    end
  end
end
