defmodule Kyber.Agent.SkillBootSeamTest do
  @moduledoc """
  T14f D9/H4 — the boot seam: the memory tools were ONLY wired in the T14c
  determinism TEST boot, so production surfaces were blind. The slice fixes
  the seam at the ATTACH surface: `Agent.attach/1`'s `default_tools/1` (the
  ONLY workspace-aware surface in the repo) — a workspace attach boot
  WITHOUT explicit `:tools` now advertises `memory.read` AND the skill
  tools by default:

      Map.merge(Action.registry(), ToolExecutor.memory_tools(store_fn)) +
      ToolExecutor.skill_tools(store_fn)

  The witness binds the ATTACH surface and asserts the model's tool LIST,
  not executability (L7) — both boot paths still default to `Gate.new()`
  (fail-closed on every call). The reactor path has no workspace concept;
  its threading is a RECORDED CARRY, NOT in-slice (H4). The blind-build
  failure modes are pinned as what the build must NOT do: witness the
  reactor path (start_engine never reaches the workspace default), or patch
  only start_engine (the engine would advertise skill_set while the
  executor's registry lacks it — every call answers "unknown tool").
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys}
  alias Kyber.Agent.{LlmHandler, ToolExecutor}

  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, _state) do
      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}
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

  defp boot_app(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  defp llm do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{}}
      )

    handler
  end

  defp engine_tool_names(engine) do
    engine
    |> :sys.get_state()
    |> Map.fetch!(:tools)
    |> Enum.map(& &1["function"]["name"])
  end

  test "D9/H4 witness: a workspace attach boot WITHOUT explicit tools advertises memory.read + the skill tools in the model's tool list" do
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14f-seam-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14f-seam-log-#{uniq}")
    ws = Path.join(log_dir, "ws")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    File.mkdir_p!(ws)
    System.put_env("KYBER_SEED", @agent_seed)
    :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)

    boot_app(Path.join(log_dir, "store.jsonl"))

    try do
      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :none,
          operator_seed: @operator_seed
        )

      # a workspace boot with NO explicit :tools — the attach default rides
      {:ok, engine, _resume} =
        Kyber.Agent.attach(keyring_dir: key_dir, llm: llm(), workspace: ws)

      names = engine_tool_names(engine) |> Enum.sort()

      # the merged surface: registry actions + memory.read + the three
      # skill tools — the model sees the whole capability list
      assert "memory_read" in names
      assert "skill_read" in names
      assert "skill_set" in names
      assert "skill_retract" in names
      assert "fs_read" in names
      assert "sh_run" in names
      assert "http_get" in names

      # the tool LIST is asserted, not executability (L7): the boot still
      # defaults to Gate.new() — fail-closed on every call
      assert length(names) == length(Enum.uniq(names))

      # the registry keys map back: tool_key_map covers the merged surface
      registry_keys = Map.keys(ToolExecutor.tool_key_map(ToolExecutor.skill_tools(fn -> %{} end)))
      assert "skill_set" in registry_keys
    after
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end
  end

  test "D9: the no-workspace attach boot keeps the stub default — the merged surface is workspace-scoped" do
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14f-stub-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14f-stub-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    System.put_env("KYBER_SEED", @agent_seed)
    :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)

    boot_app(Path.join(log_dir, "store.jsonl"))

    try do
      {:ok, _pid} =
        Daemon.boot(keyring_dir: key_dir, tick_ms: :manual, loop: :none, operator_seed: @operator_seed)

      {:ok, engine, _resume} = Kyber.Agent.attach(keyring_dir: key_dir, llm: llm())

      names = engine_tool_names(engine)
      # only the stub rides — no memory/skill tools leak into a
      # workspace-less boot
      assert names == ["tool_echo"]
    after
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end
  end
end
