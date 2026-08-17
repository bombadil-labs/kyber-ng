defmodule Kyber.Agent.ReactorModelLabelTest do
  @moduledoc """
  T19 (P5) — the stamped model label. Every `InferenceRequested` names the
  model the engine actually calls, across BOTH engine-opts shapes (a built
  `%LlmHandler{}` — the daemon's; a flat keyword list — the dashboard
  task's) and ACROSS an AC10 hot-swap: the reactor hosts its own context
  builder, so a swap that reached only the engine would leave the label
  naming the pre-swap model.

  Same anti-placebo discipline as reactor_test.exs (pins 18–21): tmp store +
  tmp keyring, `tick_ms: :manual`, no `Daemon.tick/0` anywhere — the reactor
  fires on the store's post-commit ingest cast.
  """

  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Keys, Wire}
  alias Kyber.Agent.{LlmHandler, Reactor}

  @human_seed String.duplicate("cd", 32)

  defmodule StubHttp do
    @moduledoc "The injectable HTTP adapter: a canned, tool-less answer."
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request, JSON.decode!(body)})

      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "id" => "chatcmpl-stub-1",
             "object" => "chat.completion",
             "model" => "stub",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "ok"},
                 "finish_reason" => "stop"
               }
             ]
           })
       }}
    end
  end

  # ------------------------------------------------------------- lifecycle

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
      "kyber-model-label-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  setup %{keyring_dir: keyring_dir} do
    key_dir = fresh_dir(keyring_dir, "keyring")
    File.mkdir_p!(key_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")

    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed}
  end

  # ---------------------------------------------------------------- helpers

  defp stub_llm(seed, model) do
    {:ok, llm} =
      LlmHandler.new(
        seed: seed,
        api_key: "test-key-never-real",
        model: model,
        http: {StubHttp, %{reply_to: self()}}
      )

    llm
  end

  defp boot_daemon!(ctx, engine) do
    assert {:ok, pid} =
             Daemon.boot(
               keyring_dir: ctx.keyring_dir,
               tick_ms: :manual,
               loop: :reactor,
               oracle_seed: :present,
               budget_cap: 32,
               test_pid: self(),
               engine: engine
             )

    pid
  end

  defp ingest!(ts, msg_id) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:label",
        "session:label",
        "stamp the model"
      )

    wire = Wire.envelope(signed)
    assert :ok = DurableStore.append(wire)
    wire["id"]
  end

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  # bounded sleep-free store polling for the InferenceRequested raised by
  # THIS received delta; answers the model it stamped
  defp await_stamped_model(received_id, attempts \\ 200) do
    found =
      Enum.reduce_while(1..attempts, nil, fn _, _ ->
        case Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} ->
               pointer(claims, "promptRef") == {:delta, received_id, "requested"}
             end) do
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

    assert {_id, {claims, _sig}} = found
    assert {:string, model} = pointer(claims, "model")
    model
  end

  # ------------------------------------------------------------------ tests

  test "the daemon's engine shape (a built %LlmHandler{}) stamps its model", ctx do
    boot_daemon!(ctx, llm: stub_llm(ctx.agent_seed, "m-a"), tools: [])

    received_id = ingest!(1_754_600_000_000, "message:label:a")
    assert await_stamped_model(received_id) == "m-a"
  end

  test "the dashboard's flat engine shape stamps its :model opt", ctx do
    # no :llm struct — the reactor builds the handler from the flat list.
    # The base_url is an unroutable loopback port: the turn's HTTP leg
    # refuses immediately (a tagged transport error, never a crash) and the
    # label under test is stamped BEFORE the engine is reached.
    boot_daemon!(ctx,
      api_key: "test-key-never-real",
      model: "m-b",
      base_url: "http://127.0.0.1:1/v1"
    )

    received_id = ingest!(1_754_600_000_000, "message:label:b")
    assert await_stamped_model(received_id) == "m-b"
  end

  test "AC10 hot-swap: a swapped model re-stamps the label on the NEXT turn", ctx do
    boot_daemon!(ctx, llm: stub_llm(ctx.agent_seed, "m-a"), tools: [])

    first_id = ingest!(1_754_600_000_000, "message:label:swap-before")
    assert await_stamped_model(first_id) == "m-a"

    assert :ok = Reactor.swap_llm_config(%{model: "m-c"})

    # sleep-free sync: a state read serializes behind the pending cast
    state = :sys.get_state(Reactor)

    # the primary proof — the NEXT turn's label names the swapped model
    second_id = ingest!(1_754_600_000_001, "message:label:swap-after")
    assert await_stamped_model(second_id) == "m-c"

    # secondary: the swap layered onto the stored boot engine opts
    assert state.engine_opts[:model] == "m-c"
  end

  test "a swap carrying no model leaves the standing label untouched", ctx do
    boot_daemon!(ctx, llm: stub_llm(ctx.agent_seed, "m-a"), tools: [])

    assert :ok = Reactor.swap_llm_config(%{base_url: "https://example.invalid/v1"})
    assert :sys.get_state(Reactor).engine_opts[:model] == nil

    received_id = ingest!(1_754_600_000_000, "message:label:no-model")
    assert await_stamped_model(received_id) == "m-a"
  end
end
