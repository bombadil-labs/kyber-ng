defmodule Kyber.Agent.ReactorToolsTest do
  @moduledoc """
  T14j AC1 (C1 — the reactor workspace threading): a reactor-booted daemon
  with a workspace advertises the FULL default tool set (registry + memory +
  skill) AND EXECUTES an allowed `fs.read` through the engine's tool
  executor with a REAL result — never the arg-error-string class. The
  profile intersect NARROWS the same default (the T14i H8 witness class, on
  the reactor path). The daemon is booted DIRECTLY via the `engine:` opt
  (L4 — the CLI reactor route builds no `:engine` key and stays
  stub-tooled by construction).

  The advertise leg is the FIRST assertion of each boot; the EXECUTE leg
  binds the context-parity half of C1 (H2): threading the tuple's tools
  without the executor's context swap still answers the arg-error string
  on every fs call, so a real-content assertion is the only witness that
  catches the parity crack.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Keys, Schema, Wire}
  alias Kyber.Agent.{Events, LlmHandler}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Action.Gate

  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)
  @agent_seed String.duplicate("b2", 32)
  @ts 1_754_600_000_000.0

  defmodule StubLlm do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, %{reply_to: pid}) do
      send(pid, :llm_called)

      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "stub answer"}}
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

  # -------------------------------------------------- the T5/T6/T7/T8 lifecycle
  setup_all do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)
    assert is_binary(keyring_dir)
    assert is_binary(config_log_path)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
    end)

    {:ok, keyring_dir: keyring_dir}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp fresh_dir(base, tag) do
    Path.join(
      base,
      "kyber-reactor-tools-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
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

  # ---------------------------------------------------------------- helpers

  defp stub_llm do
    {:ok, llm} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "stub-key",
        http: {StubLlm, %{reply_to: self()}},
        model: "stub-model"
      )

    llm
  end

  defp boot_daemon!(ctx, opts \\ []) do
    boot_opts =
      Keyword.merge(
        [
          keyring_dir: ctx.keyring_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          test_pid: self()
        ],
        opts
      )

    assert {:ok, pid} = Daemon.boot(boot_opts)
    pid
  end

  # the engine's advertised tool specs (the model-visible list) through the
  # reactor's hosted engine state
  defp advertised_specs do
    engine =
      :sys.get_state(Kyber.Agent.Reactor)
      |> Map.fetch!(:engine)

    engine
    |> :sys.get_state()
    |> Map.fetch!(:tools)
    |> Enum.map(& &1["function"]["name"])
    |> Enum.sort()
  end

  defp advertised_names(spec_names), do: spec_names

  defp first_role(%{pointers: [%{role: role} | _rest]}), do: role
  defp first_role(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp poll_until(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if pred.() do
        {:halt, true}
      else
        receive do
        after
          25 -> :timeout
        end

        {:cont, false}
      end
    end)
  end

  defp poll_until_value(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
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

  defp seed_profile_store do
    {:ok, soul} = AgentEvents.identity_set(@operator_seed, @ts, "identity:soul", "soul", "I am Veles.")

    {:ok, profile} =
      AgentEvents.profile_set(
        @operator_seed,
        @ts + 1,
        "channel:discord",
        "answer in character; no politics",
        ["identity:soul"],
        # the profile's capability subset: fs.read ONLY — the full default
        # set NARROWS to this
        ["fs.read"],
        []
      )

    for w <- [Wire.envelope(soul), Wire.envelope(profile)],
        do: assert(:ok = DurableStore.append(w))
  end

  # ------------------------------------------------------------------- AC1

  test "AC1 advertise: a reactor-booted daemon with a workspace advertises the FULL default tool set (registry + memory + skill)", ctx do
    ws = Path.join(System.tmp_dir!(), "kyber-reactortools-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    boot_daemon!(ctx,
      engine: [
        llm: stub_llm(),
        workspace: ws,
        gate: Gate.new(default: :allow)
      ]
    )

    spec_names = advertised_specs()

    # the full default set: the real action registry (fs/sh/http) + the
    # memory tool + the skill tools — the T14f D9 witness class, now on the
    # REACTOR path (the reactor's engine default was stub-only before T14j)
    for name <- [
          "fs_read",
          "fs_write",
          "fs_list",
          "sh_run",
          "http_get",
          "http_post",
          "memory_read",
          "skill_set",
          "skill_retract",
          "skill_read"
        ] do
      assert name in spec_names, "the reactor advertises no #{name}"
    end

    # the stub is NOT part of the default set
    refute "tool_echo" in spec_names
  end

  test "AC1 profile intersect: the SAME workspace default NARROWS to the profile's allow_tool (the H8 witness, reactor path)", ctx do
    ws = Path.join(System.tmp_dir!(), "kyber-reactortools-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    seed_profile_store()

    boot_daemon!(ctx,
      profile: "channel:discord",
      operator_seed: @operator_seed,
      engine: [
        llm: stub_llm(),
        workspace: ws,
        gate: Gate.new(default: :allow)
      ]
    )

    # the full default set narrowed to the profile's capability subset —
    # the intersect is the ONLY narrower, never a widen
    assert advertised_specs() == ["fs_read"]
  end

  test "AC1 explicit-tools-wins (M1): an explicit :tools registry is used AS-IS — never merged with the workspace default", ctx do
    ws = Path.join(System.tmp_dir!(), "kyber-reactortools-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    boot_daemon!(ctx,
      engine: [
        llm: stub_llm(),
        workspace: ws,
        gate: Gate.new(default: :allow),
        tools: %{"tool:echo" => fn args -> args end}
      ]
    )

    assert advertised_specs() == ["tool_echo"]
  end

  test "AC1 EXECUTE: the same reactor-booted daemon EXECUTES an allowed fs.read through the engine's tool executor — REAL content, status ok, never the arg-error string", ctx do
    ws = Path.join(System.tmp_dir!(), "kyber-reactortools-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "hello.txt"), "inside")
    on_exit(fn -> File.rm_rf(ws) end)

    boot_daemon!(ctx,
      engine: [
        llm: stub_llm(),
        workspace: ws,
        gate: Gate.new(default: :allow)
      ]
    )

    # the advertise leg FIRST (H2)
    spec_names = advertised_specs()
    assert "fs_read" in spec_names

    # a real turn first: the received fires the builder, which mints the
    # InferenceRequested the ToolCall must point at (the reactor's turn
    # resolution walks requestRef -> promptRef -> received)
    {:ok, turn_signed} =
      Kyber.Events.message_received(
        @human_seed,
        @ts,
        "message:reactor-tools:1",
        "channel:reactor-tools",
        "session:reactor-tools",
        "read the file"
      )

    assert :ok = DurableStore.append(Wire.envelope(turn_signed))

    request_id =
      poll_until_value(fn ->
        Enum.find_value(DurableStore.set(), fn {id, {claims, _sig}} ->
          if first_role(claims) == "promptRef", do: id
        end)
      end)

    assert is_binary(request_id), "no InferenceRequested for the turn"

    # an ALLOWED fs.read call — the gate allows it (default :allow) and no
    # policy layer gates fs ids
    {:ok, call_signed} =
      Events.tool_call(
        @agent_seed,
        @ts + 1,
        "fs.read",
        JSON.encode!(%{"path" => "hello.txt"}),
        request_id
      )

    assert :ok = DurableStore.append(Wire.envelope(call_signed))

    assert poll_until(fn ->
             Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               first_role(claims) == "call"
             end)
           end),
           "no ToolResult for the fs.read call"

    [{_id, {result_claims, _sig}}] =
      Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} -> first_role(claims) == "call" end)

    %{target: {:string, result}} = Enum.find(result_claims.pointers, &(&1.role == "result"))
    %{target: {:string, status}} = Enum.find(result_claims.pointers, &(&1.role == "status"))

    # the REAL result — never the arg-error-string class ("fs.read: a
    # "path" string argument is required" / "error" is what an unthreaded
    # executor context answers)
    assert status == "ok"
    assert result == "inside"
    refute result =~ "string argument is required"
  end

  test "AC1 execute legs stay on the empty-MAP registry shape (M5 — a list registry crashes BadMapError on the executor path)", ctx do
    # the workspace default is a MAP by construction; explicit-tools boots
    # that feed the executor with a map keep the map contract — the witness
    # is the ToolResult arriving through a registry that IS a map
    ws = Path.join(System.tmp_dir!(), "kyber-reactortools-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "hello.txt"), "inside")
    on_exit(fn -> File.rm_rf(ws) end)

    boot_daemon!(ctx,
      engine: [
        llm: stub_llm(),
        workspace: ws,
        gate: Gate.new(default: :allow),
        tools: %{"fs.read" => %{description: "x", parameters: %{}, run: {Kyber.Agent.Action.Fs, :read}}}
      ]
    )

    {:ok, turn_signed} =
      Kyber.Events.message_received(
        @human_seed,
        @ts,
        "message:reactor-tools:2",
        "channel:reactor-tools",
        "session:reactor-tools",
        "read the file"
      )

    assert :ok = DurableStore.append(Wire.envelope(turn_signed))

    request_id =
      poll_until_value(fn ->
        Enum.find_value(DurableStore.set(), fn {id, {claims, _sig}} ->
          if first_role(claims) == "promptRef", do: id
        end)
      end)

    {:ok, call_signed} =
      Events.tool_call(
        @agent_seed,
        @ts + 1,
        "fs.read",
        JSON.encode!(%{"path" => "hello.txt"}),
        request_id
      )

    assert :ok = DurableStore.append(Wire.envelope(call_signed))

    assert poll_until(fn ->
             Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               first_role(claims) == "call"
             end)
           end)

    [{_id, {result_claims, _sig}}] =
      Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} -> first_role(claims) == "call" end)

    %{target: {:string, result}} = Enum.find(result_claims.pointers, &(&1.role == "result"))
    %{target: {:string, status}} = Enum.find(result_claims.pointers, &(&1.role == "status"))
    assert status == "ok"
    assert result == "inside"
  end
end
