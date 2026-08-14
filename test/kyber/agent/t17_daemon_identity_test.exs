defmodule Kyber.Agent.T17DaemonIdentityTest do
  @moduledoc """
  T17 — the daemon's identity layer: hot-swap over the T16 feed (AC10),
  overrides pinned across re-folds with fold-vs-live status (AC23), the
  safety harness's explicit failure classifier and bounded agent-only
  rollback (AC12), the legible missing-key boot refusal (AC18), and
  boot-time soul minting idempotency (AC6).

  Every store is tmp-only; the operator seed is a test constant; the stub
  HTTP transport is mode-switched through a public ETS table so a live
  engine can be made to fail 401 (config-class) or 429 (transient) without
  any process restart. No `Process.sleep` — status polling rides bounded
  `Enum.reduce_while` with a timeout-only (clause-free) `receive`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # engine round-trips under full-suite load exceed ExUnit's 60s default
  # (same pattern as t15b_engine_cast_test)
  @moduletag timeout: 300_000

  alias Kyber.{CLI, Daemon, DurableStore, Harness, Keys, Schema, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.LlmHandler

  @daemon_seed String.duplicate("ab", 32)
  @operator_seed String.duplicate("7f", 32)
  @agent_seed String.duplicate("9c", 32)
  @key_value "sk-t17-super-secret-value-1234567890"
  @base_ts 1_754_700_000_000.0

  # the mode-switched stub transport: reads {:mode, _} from a public ETS
  # table on every call — {:fail, status} answers that HTTP status, anything
  # else answers a canned 200. Every request body is mirrored to the test.
  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient
    @impl true
    def post(_url, headers, body, %{reply_to: pid, table: table}) do
      # P5 r8 H1: the wire proof needs the OUTBOUND Authorization header —
      # the one surface the Redactor never touches
      {_name, auth} = List.keyfind(headers, ~c"authorization", 0)
      send(pid, {:t17_llm_auth, List.to_string(auth)})
      send(pid, {:t17_llm_body, JSON.decode!(body)})

      case :ets.lookup(table, :mode) do
        [{:mode, {:fail, status}}] ->
          {:ok, %{status: status, body: JSON.encode!(%{"error" => "stub refusal"})}}

        _ok ->
          {:ok,
           %{
             status: 200,
             body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "stub: ok"}}]})
           }}
      end
    end
  end

  # the P5 HIGH-1 stub: blocks the ENGINE process inside the HTTP call
  # until the test sends :t17_release — a config delta landing in that
  # window must never cascade a call timeout into the daemon
  defmodule SlowHttp do
    @behaviour Kyber.Agent.HttpClient
    @impl true
    def post(_url, _headers, body, %{reply_to: pid}) do
      send(pid, {:t17_slow_started, self()})

      receive do
        :t17_release -> :ok
      end

      send(pid, {:t17_llm_body, JSON.decode!(body)})

      {:ok,
       %{
         status: 200,
         body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "slow: ok"}}]})
       }}
    end
  end

  # the P5 MEDIUM-1 stub: first request answers a self_config_set tool
  # call; the resumed request (a tool-role message present) answers text
  defmodule ToolHttp do
    @behaviour Kyber.Agent.HttpClient
    @impl true
    def post(_url, _headers, body, %{reply_to: pid}) do
      decoded = JSON.decode!(body)
      send(pid, {:t17_llm_body, decoded})

      message =
        if Enum.any?(decoded["messages"], &(&1["role"] == "tool")) do
          %{"content" => "done"}
        else
          %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-t17-m1",
                "type" => "function",
                "function" => %{
                  "name" => "self_config_set",
                  "arguments" => JSON.encode!(%{"fields" => %{"model" => "kimi-self"}})
                }
              }
            ]
          }
        end

      {:ok, %{status: 200, body: JSON.encode!(%{"choices" => [%{"message" => message}]})}}
    end
  end

  setup do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t17di-key-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t17di-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    :ok = Keys.import_human_seed(@daemon_seed, key_dir)
    # P5 round-3 HIGH-1: the daemon's agent identity is DETERMINISTIC — the
    # fold's agent-admission pin derives from this seed, and the tests sign
    # the agent's own deltas with it (a random-minted seed would make every
    # agent-authored append fold-inert under the pin)
    File.write!(Path.join(key_dir, "agent.seed"), @daemon_seed)
    log_path = Path.join(log_dir, "store.jsonl")

    config_log_path = Application.get_env(:kyber, :log_path)
    Application.put_env(:kyber, :log_path, log_path)
    {:ok, _} = Application.ensure_all_started(:kyber)
    Daemon.stop()
    System.put_env("T17_DI_KEY", @key_value)

    on_exit(fn ->
      Daemon.stop()
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("T17_DI_KEY")
      System.delete_env("T17_DI_OP")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    %{key_dir: key_dir, log_path: log_path, log_dir: log_dir}
  end

  # ------------------------------------------------------------- helpers

  defp append_set!(seed, ts, fields, name \\ "wisp") do
    {:ok, signed} = AgentEvents.agent_set(seed, ts, name, fields)
    wire = Wire.envelope(signed)
    :ok = DurableStore.append(wire)
    wire["id"]
  end

  defp stub_llm(table, opts) do
    {:ok, llm} =
      LlmHandler.new(
        [
          seed: @daemon_seed,
          api_key: @key_value,
          http: {StubHttp, %{reply_to: self(), table: table}}
        ] ++ opts
      )

    llm
  end

  defp boot!(key_dir, llm, extra) do
    {:ok, _pid} =
      Daemon.boot(
        [
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          engine: [llm: llm, tools: []],
          agent: "wisp",
          operator_seed: @operator_seed,
          api_key: @key_value
        ] ++ extra
      )
  end

  defp ingest!(key_dir, n) do
    {:ok, _id} =
      Harness.ingest(
        %{
          "message_id" => "message:t17di:#{n}",
          "channel_id" => "channel:t17di",
          "session_id" => "session:t17di",
          "content" => "hello #{n}",
          "ts" => 1_754_710_000_000 + n
        },
        key_dir
      )
  end

  # the no-sleep poll: bounded attempts, clause-free receive (consumes
  # nothing from the mailbox), re-checks until the condition holds
  defp eventually(fun, attempts \\ 240) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        receive do
        after
          250 -> :timeout
        end

        {:cont, false}
      end
    end)
  end

  defp live_model, do: get_in(Daemon.status(), [:config, :live, :model])

  defp retract_targets do
    for {_id, {claims, _sig}} <- DurableStore.set(),
        %{type: "AgentRetract", negates: {:delta, target, _ctx}} <- [Schema.resolve(claims)],
        do: target
  end

  defp rollback_claims do
    for {_id, {claims, _sig}} <- DurableStore.set(),
        %{type: "ConfigRollback"} = resolved <- [Schema.resolve(claims)],
        do: resolved
  end

  defp soul_mints do
    for {id, {claims, _sig}} <- DurableStore.set(),
        %{type: "IdentitySet", kind: "soul"} <- [Schema.resolve(claims)],
        do: {id, claims}
  end

  # ------------------------------------------------------------- the tests

  test "an AgentSet delta hot-swaps the live engine mid-session (AC10)", %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})
    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    append_set!(@operator_seed, @base_ts + 10, %{model: "kimi-hot"})

    assert eventually(fn -> live_model() == "kimi-hot" end),
           "the live engine never swapped to kimi-hot (status: #{inspect(Daemon.status())})"

    # the NEXT inference cycle runs the rederived config — no reboot
    ingest!(key_dir, 1)
    assert_receive {:t17_llm_body, body}, 60_000
    assert body["model"] == "kimi-hot"
  end

  test "a hot-swap landing mid-LLM-call never kills the daemon (P5 HIGH-1)", %{
    key_dir: key_dir
  } do
    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    {:ok, llm} =
      LlmHandler.new(
        seed: @daemon_seed,
        api_key: @key_value,
        model: "kimi-base",
        http: {SlowHttp, %{reply_to: self()}}
      )

    boot!(key_dir, llm, model: "kimi-base")
    daemon = Process.whereis(Kyber.Daemon)
    ref = Process.monitor(daemon)

    # the engine goes busy: the stub blocks the engine process mid-HTTP-call
    ingest!(key_dir, 1)
    assert_receive {:t17_slow_started, in_flight}, 60_000

    # the config delta lands while the engine is blocked — pre-fix the
    # daemon->reactor->engine call chain timed out at 5s and the exit
    # cascaded through the links into the daemon
    append_set!(@operator_seed, @base_ts + 10, %{model: "kimi-hot"})

    refute_receive {:DOWN, ^ref, :process, _, _}, 7_000
    assert Process.alive?(daemon)
    assert eventually(fn -> live_model() == "kimi-hot" end)

    # release the in-flight call: it completes under the config it started
    # with — the queued swap applies only after it returns
    send(in_flight, :t17_release)
    assert_receive {:t17_llm_body, first}, 60_000
    assert first["model"] == "kimi-base"

    # the NEXT inference runs the rederived config
    ingest!(key_dir, 2)
    assert_receive {:t17_slow_started, next}, 60_000
    send(next, :t17_release)
    assert_receive {:t17_llm_body, second}, 60_000
    assert second["model"] == "kimi-hot"
  end

  test "a CLI override survives the hot-swap; status shows fold AND live (AC23)", %{
    key_dir: key_dir
  } do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    boot!(key_dir, stub_llm(table, model: "kimi-k3"),
      model: "kimi-k3",
      overrides: [model: "kimi-k3"]
    )

    # hot-swap an UNRELATED field
    append_set!(@operator_seed, @base_ts + 10, %{soul: "I am wisp, re-souled."})

    assert eventually(fn ->
             get_in(Daemon.status(), [:config, :fold, :soul]) == "I am wisp, re-souled."
           end)

    status = Daemon.status()
    # the override is re-applied after the re-fold: live stays kimi-k3
    assert get_in(status, [:config, :live, :model]) == "kimi-k3"
    # ...and status exposes the fold value DISTINCTLY (never silently agrees)
    assert get_in(status, [:config, :fold, :model]) == "kimi-base"

    ingest!(key_dir, 1)
    assert_receive {:t17_llm_body, body}, 60_000
    assert body["model"] == "kimi-k3"
  end

  test "N consecutive config-class failures retract the agent's delta (AC12)", %{
    key_dir: key_dir
  } do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # the agent self-configures a broken model (granted by the operator;
    # signed with the daemon's OWN pinned seed — P5 round-3 HIGH-1)
    agent_delta = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    # first inference after the self-config delta fails config-class (401)
    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    # the harness auto-appends the retraction + the ConfigRollback claim
    assert eventually(fn -> agent_delta in retract_targets() end),
           "the offending agent delta was never retracted"

    assert [rollback | _rest] = rollback_claims()
    assert Enum.any?(rollback.offends, &match?({:delta, ^agent_delta, _ctx}, &1))

    # the fold steps back and the LIVE engine follows
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1
  end

  test "transient failures (429) never retract — a brownout destroys no deltas (AC12)", %{
    key_dir: key_dir
  } do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    :ets.insert(table, {:mode, {:fail, 429}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 429, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 429, _body}}}, 60_000

    # the status call serializes AFTER the daemon processed both engine
    # events (the reactor forwards to the daemon BEFORE the test observer)
    status = Daemon.status()
    assert status.rollbacks == 0
    assert retract_targets() == []
    assert live_model() == "kimi-broken"
  end

  test "a granted agent delta naming api_key_env is FOLD-INERT — the operator key stays on the wire (P5 r8 H1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    # the exfiltration target: a daemon-readable env var whose VALUE must
    # never reach the provider's Authorization header
    System.put_env("T17_DI_EXFIL", "sk-exfil-planted-secret-0987654321")
    on_exit(fn -> System.delete_env("T17_DI_EXFIL") end)

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 1
    )

    folds = Daemon.status().folds_since_boot

    # the granted agent points api_key_env at an env var of its choosing —
    # pre-r8 the hot-swap resolved it and shipped the value on the wire
    append_set!(@daemon_seed, @base_ts + 10, %{api_key_env: "T17_DI_EXFIL"})

    # the delta is processed and INERT: nothing armed, nothing failed,
    # nothing retracted — a non-event, not a rollback
    assert eventually(fn -> Daemon.status().folds_since_boot > folds end)
    status = Daemon.status()
    assert status.rollbacks == 0
    assert status.failures == 0
    assert retract_targets() == []

    # the wire proof: the next request's Authorization header carries the
    # OPERATOR-attested key, never the agent-named env var's value
    ingest!(key_dir, 1)
    assert_receive {:t17_llm_auth, auth}, 60_000
    assert auth == "Bearer " <> @key_value
    refute auth =~ "sk-exfil"
  end

  test "the operator CAN still hot-swap api_key_env — the new env's value rides the auth header (P5 r8 H1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    System.put_env("T17_DI_KEY2", "sk-t17-rotated-value-abcdefghij")
    on_exit(fn -> System.delete_env("T17_DI_KEY2") end)

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})
    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    folds = Daemon.status().folds_since_boot
    append_set!(@operator_seed, @base_ts + 10, %{api_key_env: "T17_DI_KEY2"})
    assert eventually(fn -> Daemon.status().folds_since_boot > folds end)

    ingest!(key_dir, 1)
    assert_receive {:t17_llm_auth, auth}, 60_000
    assert auth == "Bearer sk-t17-rotated-value-abcdefghij"
  end

  test "an OPERATOR swap-time key failure is detection-only — the engine keeps the old key (P5 r8)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      rollback_threshold: 1
    )

    folds = Daemon.status().folds_since_boot

    # post-r8 only the operator can name the key source, so a swap-time
    # key failure is always operator-headed: detection-only, no retract
    append_set!(@operator_seed, @base_ts + 10, %{api_key_env: "T17_DI_MISSING"})
    assert eventually(fn -> Daemon.status().folds_since_boot > folds end)

    assert Daemon.status().rollbacks == 0
    assert retract_targets() == []

    # the failed swap never replaced the live credential
    ingest!(key_dir, 1)
    assert_receive {:t17_llm_auth, auth}, 60_000
    assert auth == "Bearer " <> @key_value
  end

  test "the operator seed is redacted from the wire even when leaked into content (P5 M1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})
    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    # a hot-swap pushes the daemon's redact list (api key + operator seed)
    # into the live handler
    append_set!(@operator_seed, @base_ts + 10, %{model: "kimi-hot"})
    assert eventually(fn -> live_model() == "kimi-hot" end)

    # the seed value leaks into ordinary channel content — the wire must
    # carry the marker, never the value (the shape scan deliberately skips
    # bare 64-hex, so only the exact-value redact list can catch this)
    {:ok, _id} =
      Harness.ingest(
        %{
          "message_id" => "message:t17di:seedleak",
          "channel_id" => "channel:t17di",
          "session_id" => "session:t17di",
          "content" => "psst, the operator seed is #{@operator_seed}",
          "ts" => 1_754_710_000_000
        },
        key_dir
      )

    assert_receive {:t17_llm_body, body}, 60_000
    encoded = JSON.encode!(body)
    refute encoded =~ @operator_seed
    assert encoded =~ "[REDACTED]"
  end

  test "a live agent boot SERVES self_config.set and a granted call folds (P5 MEDIUM-1)", %{
    key_dir: key_dir
  } do
    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    {:ok, llm} =
      LlmHandler.new(
        seed: @daemon_seed,
        api_key: @key_value,
        model: "kimi-base",
        http: {ToolHttp, %{reply_to: self()}}
      )

    # deliberately NO :tools in the engine opts — the boot path itself must
    # wire the tool into what the reactor serves
    {:ok, _pid} =
      Daemon.boot(
        keyring_dir: key_dir,
        tick_ms: :manual,
        loop: :reactor,
        oracle_seed: :present,
        engine: [llm: llm],
        agent: "wisp",
        operator_seed: @operator_seed,
        api_key: @key_value
      )

    ingest!(key_dir, 1)

    # the FIRST request already advertises the tool
    assert_receive {:t17_llm_body, first}, 60_000
    names = for %{"function" => %{"name" => name}} <- first["tools"] || [], do: name
    assert "self_config_set" in names

    # the model's call mints an AGENT-authored AgentSet that folds live
    assert eventually(fn ->
             get_in(Daemon.status(), [:config, :fold, :model]) == "kimi-self"
           end),
           "the self_config.set call never folded (status: #{inspect(Daemon.status())})"

    # the minted delta is AGENT-sourced (the daemon's boot signing key),
    # never operator-attested
    minted =
      for {_id, {claims, _sig}} <- DurableStore.set(),
          match?(%{type: "AgentSet", model: "kimi-self"}, Schema.resolve(claims)),
          do: claims.author

    assert [author] = minted
    refute author == Keys.author_for_seed(@operator_seed)

    # the turn resumes over the ToolResult and completes
    assert_receive {:t17_llm_body, second}, 60_000
    assert Enum.any?(second["messages"], &(&1["role"] == "tool"))
  end

  test "an operator-attested bad delta is detection-only — never auto-retracted (AC12)", %{
    key_dir: key_dir
  } do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # the OPERATOR ships the bad config
    append_set!(@operator_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    status = Daemon.status()
    assert status.rollbacks == 0
    assert retract_targets() == []
    # no silent operator undo: the operator's config stays live
    assert live_model() == "kimi-broken"
  end

  test "boot with the key env unset refuses with the legible repair (AC18)" do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    registry = Path.join(System.tmp_dir!(), "kyber-t17di-reg-#{uniq}")
    File.mkdir_p!(registry)
    on_exit(fn -> File.rm_rf(registry) end)

    System.put_env("T17_DI_OP", @operator_seed)
    # genesis validation needs the key env present at new-time
    System.put_env("DEEPSEEK_API_KEY", "test-key-not-real")

    assert {:ok, _msg} =
             CLI.run([
               "agent",
               "new",
               "wisp",
               "--soul",
               "I am wisp.",
               "--operator-seed-env",
               "T17_DI_OP",
               "--registry",
               registry
             ])

    System.delete_env("DEEPSEEK_API_KEY")

    assert {:error, message} = CLI.run(["daemon", "--agent", "wisp", "--registry", registry])
    # agent name, the env var NAME, an exact repair — never the key value
    assert message =~ "wisp"
    assert message =~ "DEEPSEEK_API_KEY"
    assert message =~ "export"
    refute message =~ "sk-"
  end

  test "boot with a rotated-away operator seed refuses loudly (P5 M2)", %{key_dir: key_dir} do
    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    # the pointer chain says authority moved to another author; the boot
    # seed still derives the OLD author — refuse, never sign with dead
    # authority
    current = Keys.author_for_seed(@agent_seed)
    old = Keys.author_for_seed(@operator_seed)

    assert {:error, {:not_operator, ^old, ^current}} =
             Daemon.boot(
               keyring_dir: key_dir,
               tick_ms: :manual,
               agent: "wisp",
               operator_seed: @operator_seed,
               operator_authors: [old, current]
             )
  end

  test "boot mints identity:soul from the fold exactly once (AC6)", %{key_dir: key_dir} do
    append_set!(@operator_seed, @base_ts, %{
      soul: "I am wisp, the quiet sibling.",
      model: "kimi-base",
      api_key_env: "T17_DI_KEY"
    })

    {:ok, _pid} =
      Daemon.boot(
        keyring_dir: key_dir,
        tick_ms: :manual,
        agent: "wisp",
        operator_seed: @operator_seed
      )

    assert [{first_id, claims}] = soul_mints()
    assert claims.author == Keys.author_for_seed(@operator_seed)

    # a second boot over the same store NEVER re-mints
    Daemon.stop()

    {:ok, _pid} =
      Daemon.boot(
        keyring_dir: key_dir,
        tick_ms: :manual,
        agent: "wisp",
        operator_seed: @operator_seed
      )

    assert [{^first_id, _claims}] = soul_mints()
  end

  test "a third-party delta under a live grant is fold-inert; the pinned agent author folds (P5 r3 HIGH-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    # the PINNED agent author (the daemon's own boot seed) folds under the grant
    append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-own"})
    assert eventually(fn -> live_model() == "kimi-own" end)

    # a leaked/rotated-away seed's delta at a LATER timestamp under the same
    # grant — pre-fix last-set-wins admitted any author and it would seize
    # the model; pinned it must never fold
    append_set!(@agent_seed, @base_ts + 20, %{model: "kimi-evil"})

    # no-sleep choreography: a later operator delta proves the daemon's FIFO
    # mailbox processed the feed PAST the intruder delta
    append_set!(@operator_seed, @base_ts + 30, %{soul: "post-intruder marker"})

    assert eventually(fn ->
             get_in(Daemon.status(), [:config, :fold, :soul]) == "post-intruder marker"
           end)

    assert get_in(Daemon.status(), [:config, :fold, :model]) == "kimi-own"
    assert live_model() == "kimi-own"
  end

  test "rollback retracts ONLY the failing field's setter — a benign soul delta survives (P5 r3 MEDIUM-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # the agent breaks the model, THEN ships a benign soul delta — the soul
    # delta is the NEWEST AgentSet when the failures land (pre-fix the
    # single-slot harness blamed it and the broken model survived rollback)
    broken = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    benign = append_set!(@daemon_seed, @base_ts + 20, %{soul: "agent-souled"})

    assert eventually(fn ->
             get_in(Daemon.status(), [:config, :fold, :soul]) == "agent-souled"
           end)

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    assert eventually(fn -> broken in retract_targets() end),
           "the broken model delta was never retracted"

    # blame is PER FIELD: the newest (benign) delta is not the offender
    refute benign in retract_targets()
    assert get_in(Daemon.status(), [:config, :fold, :soul]) == "agent-souled"
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1
  end

  test "a fold-inert AgentSet never erases blame — the broken delta still rolls back (P5 r4 HIGH-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # the agent breaks the model...
    broken = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    # ...then a FOLD-INERT AgentSet lands (an unadmitted author's delta —
    # not the operator, not the pinned agent author). Pre-fix it clobbered
    # the armed model slot with its own non-live id AND reset the counter:
    # every later failure blamed :none, silently, forever.
    inert = append_set!(@agent_seed, @base_ts + 20, %{model: "kimi-hijack"})

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    # blame survived the inert delta: the LIVE broken setter is retracted
    assert eventually(fn -> broken in retract_targets() end),
           "the inert delta erased blame — the broken model was never retracted " <>
             "(status: #{inspect(Daemon.status())})"

    refute inert in retract_targets()
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1
  end

  test "a config-class failure with NO armed slot is loud and counted, never swallowed (P5 r4 HIGH-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    # the broken config predates the boot: nothing ever arms the harness
    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    log =
      capture_log(fn ->
        :ets.insert(table, {:mode, {:fail, 401}})
        ingest!(key_dir, 1)
        assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

        assert eventually(fn -> Daemon.status().failures == 1 end),
               "the unarmed config-class failure was silently swallowed " <>
                 "(status: #{inspect(Daemon.status())})"
      end)

    assert log =~ "no armed config delta"
    # no-retraction semantics kept: nothing to retract, but LOUD
    assert retract_targets() == []
    assert Daemon.status().rollbacks == 0
  end

  test "re-applying the SAME broken value hits the counter immediately (P5 r4 HIGH-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    first = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    assert eventually(fn -> first in retract_targets() end)
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1

    # the agent retries the SAME broken value — the re-arm must preserve
    # the counter (pre-fix it reset to zero and the retry bought itself N
    # fresh failures before the harness could act again)
    retry = append_set!(@daemon_seed, @base_ts + 20, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    ingest!(key_dir, 3)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    # ONE fresh failure suffices: the second rollback fires immediately
    assert eventually(fn -> retry in retract_targets() end),
           "the retry restarted the counter — no second rollback " <>
             "(status: #{inspect(Daemon.status())})"

    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 2
  end

  test "interleaved benign deltas never defer the rollback — only a CONFIG change opens a new window (P5 r7 MEDIUM-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    broken = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    # failure #1 lands (counter 1)...
    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    assert eventually(fn -> Daemon.status().failures == 1 end)

    # ...then the agent interleaves a BENIGN soul delta. Pre-fix ANY
    # fold-live delta reset the counter to 0 — an agent alternating
    # soul-tweak / failing-inference kept the broken model live forever.
    # The soul field is not LLM config: the measurement window continues.
    benign = append_set!(@daemon_seed, @base_ts + 20, %{soul: "still me, softly"})

    assert eventually(fn ->
             get_in(Daemon.status(), [:config, :fold, :soul]) == "still me, softly"
           end)

    assert Daemon.status().failures == 1,
           "the benign soul delta reset the failure counter (P5 r7 MEDIUM-1 regression)"

    # failure #2 reaches the threshold: the broken model rolls back
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    assert eventually(fn -> broken in retract_targets() end),
           "the interleaved benign delta deferred the rollback forever " <>
             "(status: #{inspect(Daemon.status())})"

    refute benign in retract_targets()
    assert get_in(Daemon.status(), [:config, :fold, :soul]) == "still me, softly"
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1
  end

  test "a genuinely NEW operator config value resets the window — and stays detection-only (P5 r7 MEDIUM-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    broken = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken"})
    assert eventually(fn -> live_model() == "kimi-broken" end)

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    assert eventually(fn -> Daemon.status().failures == 1 end)

    # the OPERATOR sets a genuinely new model value: a real config change
    # opens a NEW measurement window — the counter resets...
    operator_delta = append_set!(@operator_seed, @base_ts + 20, %{model: "kimi-operator-pick"})
    assert eventually(fn -> live_model() == "kimi-operator-pick" end)
    assert Daemon.status().failures == 0

    # ...and failures under the operator's head are detection-only: no
    # auto-retract, ever (the armed model slot is operator-sourced now)
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 3)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    status = Daemon.status()
    assert status.rollbacks == 0
    refute operator_delta in retract_targets()
    refute broken in retract_targets()
    assert live_model() == "kimi-operator-pick"
  end

  test "a chained broken config is walked PAST the first rollback — the prior broken delta is blamed too (P5 r5 MEDIUM-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # the agent chains TWO broken deltas on the same field
    broken_a = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-broken-a"})
    assert eventually(fn -> live_model() == "kimi-broken-a" end)
    broken_b = append_set!(@daemon_seed, @base_ts + 20, %{model: "kimi-broken-b"})
    assert eventually(fn -> live_model() == "kimi-broken-b" end)

    :ets.insert(table, {:mode, {:fail, 401}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    # rollback #1 retracts B and the fold steps back to A — still broken
    assert eventually(fn -> broken_b in retract_targets() end),
           "the newest broken delta was never retracted"

    assert eventually(fn -> live_model() == "kimi-broken-a" end)

    # ONE more failure suffices: the rollback re-armed on A (the surviving
    # agent-sourced head) and PRESERVED the counter — pre-fix armed.model
    # was simply dropped, so every later failure blamed :none and the
    # still-broken A stayed live forever
    ingest!(key_dir, 3)
    assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

    assert eventually(fn -> broken_a in retract_targets() end),
           "the rollback stranded the prior broken delta — A was never re-armed " <>
             "(status: #{inspect(Daemon.status())})"

    # the chain is fully walked: the fold returns to the pre-A good model
    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 2
  end

  test "403 and 422 are CONFIG-CLASS: an unauthorized key or rejected request retracts (P5 r5 LOW-1)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      self_config: "true"
    })

    boot!(key_dir, stub_llm(table, model: "kimi-base"),
      model: "kimi-base",
      test_pid: self(),
      rollback_threshold: 2
    )

    # 403: "this key is not authorized for this model" — pre-fix it fell to
    # the transient default and the broken agent delta survived forever
    broken_403 = append_set!(@daemon_seed, @base_ts + 10, %{model: "kimi-unauthorized"})
    assert eventually(fn -> live_model() == "kimi-unauthorized" end)

    :ets.insert(table, {:mode, {:fail, 403}})
    ingest!(key_dir, 1)
    assert_receive {:engine, {:llm_error, {:llm_http, 403, _body}}}, 60_000
    ingest!(key_dir, 2)
    assert_receive {:engine, {:llm_error, {:llm_http, 403, _body}}}, 60_000

    assert eventually(fn -> broken_403 in retract_targets() end),
           "403 never counted as config-class — the unauthorized-key config survived"

    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 1

    # 422: request semantics rejected — likewise config-class (a genuinely
    # NEW broken value resets the counter, so two failures are needed again)
    broken_422 = append_set!(@daemon_seed, @base_ts + 20, %{model: "kimi-invalid"})
    assert eventually(fn -> live_model() == "kimi-invalid" end)

    :ets.insert(table, {:mode, {:fail, 422}})
    ingest!(key_dir, 3)
    assert_receive {:engine, {:llm_error, {:llm_http, 422, _body}}}, 60_000
    ingest!(key_dir, 4)
    assert_receive {:engine, {:llm_error, {:llm_http, 422, _body}}}, 60_000

    assert eventually(fn -> broken_422 in retract_targets() end),
           "422 never counted as config-class"

    assert eventually(fn -> live_model() == "kimi-base" end)
    assert Daemon.status().rollbacks == 2
  end

  test "boot without the operator seed is LOUD: harness :dead, failures narrated, no crash (P5 r4 M2)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{
      model: "kimi-base",
      api_key_env: "T17_DI_KEY",
      operator_seed_env: "T17_DI_OP"
    })

    boot_log =
      capture_log(fn ->
        {:ok, _pid} =
          Daemon.boot(
            keyring_dir: key_dir,
            tick_ms: :manual,
            loop: :reactor,
            oracle_seed: :present,
            engine: [llm: stub_llm(table, model: "kimi-base")],
            agent: "wisp",
            api_key: @key_value,
            model: "kimi-base",
            test_pid: self(),
            rollback_threshold: 1
          )
      end)

    # the dead harness is announced at BOOT, naming the env var to set
    assert boot_log =~ "harness is DEAD"
    assert boot_log =~ "T17_DI_OP"
    assert Daemon.status().harness == :dead

    daemon = Process.whereis(Kyber.Daemon)

    failure_log =
      capture_log(fn ->
        :ets.insert(table, {:mode, {:fail, 401}})
        ingest!(key_dir, 1)
        assert_receive {:engine, {:llm_error, {:llm_http, 401, _body}}}, 60_000

        assert eventually(fn -> Daemon.status().failures == 1 end),
               "the seedless config-class failure was silently swallowed"
      end)

    # the failure narrates the cannot-roll-back state and never raises
    assert failure_log =~ "cannot roll back"
    assert Process.alive?(daemon)
    assert retract_targets() == []
    assert Daemon.status().rollbacks == 0
  end

  test "the feed folds ONCE per delta and the daemon's fold never diverges from a direct resolve (P5 r6 LOW-2)",
       %{key_dir: key_dir} do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})
    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    base = Daemon.status().folds_since_boot

    # N chained AgentSet deltas ride the feed
    append_set!(@operator_seed, @base_ts + 10, %{model: "kimi-1"})
    append_set!(@operator_seed, @base_ts + 20, %{soul: "chained soul"})
    append_set!(@operator_seed, @base_ts + 30, %{model: "kimi-3"})

    # FIFO: the third delta's swap landing proves all three were processed
    assert eventually(fn -> live_model() == "kimi-3" end)

    status = Daemon.status()

    # ONE fold per delta: N deltas move the counter by exactly N — pre-fix
    # the hot-swap re-folded after the arming fold (2N full-store walks in
    # the daemon's serialized loop)
    assert status.folds_since_boot == base + 3

    # and no divergence: the daemon's fold agrees with a direct pinned
    # resolve over the same store
    {:ok, view} =
      Kyber.Agent.Config.resolve(
        DurableStore.set(),
        "wisp",
        [Keys.author_for_seed(@operator_seed)],
        Keys.author_for_seed(@daemon_seed)
      )

    assert get_in(status, [:config, :fold, :model]) == view.model
    assert get_in(status, [:config, :fold, :soul]) == view.soul
  end

  test "GenServer state dumps redact the seeds and key material (P5 r3 MEDIUM-3)", %{
    key_dir: key_dir
  } do
    table = :ets.new(:t17_stub, [:public])
    :ets.insert(table, {:mode, :ok})

    append_set!(@operator_seed, @base_ts, %{model: "kimi-base", api_key_env: "T17_DI_KEY"})
    boot!(key_dir, stub_llm(table, model: "kimi-base"), model: "kimi-base")

    # the reactor hosts its engine anonymously — the pid rides its state
    engine = :sys.get_state(Kyber.Agent.Reactor).engine
    assert is_pid(engine)

    # :sys.get_status runs the same format_status/1 a crash report uses —
    # the dump must carry the marker and never a secret byte
    for server <- [Kyber.Daemon, Kyber.Agent.Reactor, engine] do
      dump =
        server
        |> :sys.get_status()
        |> inspect(limit: :infinity, printable_limit: :infinity)

      refute dump =~ @daemon_seed, "#{inspect(server)} leaks the agent seed"
      refute dump =~ @operator_seed, "#{inspect(server)} leaks the operator seed"
      refute dump =~ @key_value, "#{inspect(server)} leaks the api key"
      assert dump =~ "<redacted>", "#{inspect(server)} shows no redaction marker"
    end
  end
end
