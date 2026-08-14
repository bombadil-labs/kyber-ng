defmodule Kyber.Agent.T17SocketSetConfigTest do
  @moduledoc """
  T17 AC9 — the served channel's `set-config` verb on the channel socket
  JSONL protocol. Operator-attested (the daemon's boot operator seed signs,
  exactly like `send` — M5's nil-seed gate applies) and door-validated like
  every other AgentSet write (AC17): a secret-shaped value or an unknown
  field never reaches the store.

  The socket server is started directly (its listen binds synchronously in
  start_link, so the socket file exists when start_link returns — no
  readiness sleep); the DurableStore rides the app pointed at a tmp log.
  """
  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Keys}
  alias Kyber.Agent.Config
  alias Kyber.CLI.TUI
  alias Kyber.Channel.Socket

  @operator_seed String.duplicate("7f", 32)

  setup do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    log_dir = Path.join(System.tmp_dir!(), "kyber-t17-sock-#{uniq}")
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "store.jsonl")
    socket_path = log_path <> ".sock"

    config_log_path = Application.get_env(:kyber, :log_path)
    Application.put_env(:kyber, :log_path, log_path)
    {:ok, _} = Application.ensure_all_started(:kyber)
    Kyber.Daemon.stop()

    {:ok, server} =
      Socket.start_link(
        socket_path: socket_path,
        log_path: log_path,
        operator_seed: @operator_seed
      )

    # the socket server is LINKED to the test process and traps exits, so it
    # terminates with the test — stopping it here would race its own death
    # and an on_exit exception would skip the app teardown (store leak)
    on_exit(fn ->
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(log_dir)
    end)

    %{log_path: log_path, socket_path: socket_path, log_dir: log_dir, server: server}
  end

  defp set_config(socket_path, name, fields) do
    TUI.request(socket_path, %{"verb" => "set-config", "name" => name, "fields" => fields})
  end

  test "set-config appends an operator-attested AgentSet delta that folds (AC9)", %{
    socket_path: socket_path
  } do
    assert {:ok, %{"ok" => true}} =
             set_config(socket_path, "wisp", %{"model" => "deepseek-v4", "soul" => "I am wisp."})

    assert {:ok, view} = Config.resolve(DurableStore.set(), "wisp")
    assert view.model == "deepseek-v4"
    assert view.soul == "I am wisp."

    # operator-attested: the single delta is signed by the boot operator seed
    operator = Keys.author_for_seed(@operator_seed)
    assert [{_id, {claims, _sig}}] = Enum.to_list(DurableStore.set())
    assert claims.author == operator
  end

  test "unset rides the same verb (SET semantics, field back to nil)", %{
    socket_path: socket_path
  } do
    assert {:ok, %{"ok" => true}} = set_config(socket_path, "wisp", %{"soul" => "temporary"})
    assert {:ok, %{"ok" => true}} = set_config(socket_path, "wisp", %{"unset" => ["soul"]})

    assert {:ok, view} = Config.resolve(DurableStore.set(), "wisp")
    assert view.soul == nil
  end

  test "a nil operator seed refuses set-config before any mint (M5 gate)", %{
    log_path: log_path,
    log_dir: log_dir
  } do
    bare_path = Path.join(log_dir, "bare.sock")

    {:ok, _bare} =
      Socket.start_link(socket_path: bare_path, log_path: log_path, operator_seed: nil)

    assert {:ok, %{"error" => "no_operator_seed"}} =
             set_config(bare_path, "wisp", %{"model" => "deepseek-v4"})

    assert DurableStore.set() == %{}
  end

  test "the door refuses a secret-shaped value with the repair message; NO delta (AC17)", %{
    socket_path: socket_path
  } do
    assert {:ok, %{"error" => message}} =
             set_config(socket_path, "wisp", %{"api_key_env" => "sk-abcdef1234567890abcdef"})

    assert message =~ "env NAME"
    assert DurableStore.set() == %{}
  end

  test "an unknown field name is malformed; NO delta", %{socket_path: socket_path} do
    assert {:ok, %{"error" => "malformed"}} =
             set_config(socket_path, "wisp", %{"api_key" => "anything"})

    assert DurableStore.set() == %{}
  end

  test "a request without name/fields is malformed", %{socket_path: socket_path} do
    assert {:ok, %{"error" => "malformed"}} =
             TUI.request(socket_path, %{"verb" => "set-config", "fields" => %{}})

    assert {:ok, %{"error" => "malformed"}} =
             TUI.request(socket_path, %{"verb" => "set-config", "name" => "wisp"})
  end

  describe "the ctl client speaks set-config (AC9)" do
    test "ctl --log <path> set-config <name> <json> lands the delta", %{log_path: log_path} do
      assert {:ok, _message} =
               Kyber.CLI.run([
                 "ctl",
                 "--log",
                 log_path,
                 "set-config",
                 "wisp",
                 ~s({"model":"deepseek-v4-air"})
               ])

      assert {:ok, view} = Config.resolve(DurableStore.set(), "wisp")
      assert view.model == "deepseek-v4-air"
    end

    test "a door refusal exits non-zero through ctl", %{log_path: log_path} do
      assert {:error, message} =
               Kyber.CLI.run([
                 "ctl",
                 "--log",
                 log_path,
                 "set-config",
                 "wisp",
                 ~s({"soul":"my key is sk-abcdefghij1234567890"})
               ])

      assert message =~ "env NAME"
      assert DurableStore.set() == %{}
    end

    test "argv JSON that is not an object is a usage error", %{log_path: log_path} do
      assert {:error, :usage, _usage} =
               Kyber.CLI.run(["ctl", "--log", log_path, "set-config", "wisp", "not-json"])
    end
  end
end
