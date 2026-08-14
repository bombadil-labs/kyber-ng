defmodule Kyber.Agent.T17AgentBootTest do
  @moduledoc """
  T17 — the operational boot spine, end to end through the REAL CLI path:
  `kyber daemon --agent <name>` reads the registry pointer, folds the
  agent's store, and boots the daemon on the fold, then runs a live turn
  against the CONFIGURED provider with the soul in the prompt (AC2); the
  `oracle_seed` field governs refuse-only vs open at boot (AC3); and the
  key VALUE never rides the prompt body, the store, or the show/list
  output — only the env NAME does (AC19).

  The "configured provider" is a local single-purpose gen_tcp HTTP server
  (the fold's base_url points at it), so the assertion is on the actual
  bytes the stdlib `:httpc` adapter sends — no injected stub transport.
  Every store/keyring/registry is tmp-only. No `Process.sleep` — polling
  rides bounded `Enum.reduce_while` with a timeout-only (clause-free)
  `receive`.
  """
  use ExUnit.Case, async: false

  # engine round-trips under full-suite load exceed ExUnit's 60s default
  # (same pattern as t15b_engine_cast_test / t17_daemon_identity_test)
  @moduletag timeout: 300_000

  alias Kyber.{CLI, Daemon, DurableStore, Events, Schema, Wire}
  alias Kyber.Agent.Events, as: AgentEvents

  @operator_seed String.duplicate("7f", 32)
  @key_value "sk-t17ab-super-secret-value-1234567890"
  @soul "I am wisp, the quiet sibling."

  # the local "configured provider": accepts POST /v1/chat/completions,
  # mirrors headers+body to the test, answers a canned OpenAI-shaped 200,
  # and closes (connection: close keeps :httpc simple). One process, a
  # sequential accept loop — a daemon runs one inference at a time.
  defmodule StubProvider do
    def start(reply_to) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :http_bin,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listen)
      spawn(fn -> accept_loop(listen, reply_to) end)
      {port, listen}
    end

    defp accept_loop(listen, reply_to) do
      case :gen_tcp.accept(listen) do
        {:ok, sock} ->
          serve(sock, reply_to)
          accept_loop(listen, reply_to)

        {:error, _closed} ->
          :ok
      end
    end

    defp serve(sock, reply_to) do
      {:ok, {:http_request, :POST, _path, _version}} = :gen_tcp.recv(sock, 0)
      headers = read_headers(sock, %{})
      :ok = :inet.setopts(sock, packet: :raw)
      {:ok, body} = :gen_tcp.recv(sock, String.to_integer(headers["content-length"]))
      send(reply_to, {:t17_provider, headers, JSON.decode!(body)})

      reply =
        JSON.encode!(%{"choices" => [%{"message" => %{"content" => "stub: turn ok"}}]})

      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(reply)}\r\nconnection: close\r\n\r\n" <> reply
      )

      :gen_tcp.close(sock)
    end

    defp read_headers(sock, acc) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, {:http_header, _len, name, _reserved, value}} ->
          key = name |> to_string() |> String.downcase()
          read_headers(sock, Map.put(acc, key, to_string(value)))

        {:ok, :http_eoh} ->
          acc
      end
    end
  end

  setup do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    registry = Path.join(System.tmp_dir!(), "kyber-t17ab-reg-#{uniq}")
    File.mkdir_p!(registry)

    config_log_path = Application.get_env(:kyber, :log_path)
    System.put_env("T17_AB_OP", @operator_seed)
    System.put_env("T17_AB_KEY", @key_value)

    on_exit(fn ->
      Daemon.stop()
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("T17_AB_OP")
      System.delete_env("T17_AB_KEY")
      File.rm_rf(registry)
    end)

    %{registry: registry}
  end

  # ------------------------------------------------------------- helpers

  defp provider!(test_pid) do
    {port, listen} = StubProvider.start(test_pid)
    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp new_agent!(registry, port, extra \\ []) do
    {:ok, _msg} =
      CLI.run(
        [
          "agent",
          "new",
          "wisp",
          "--soul",
          @soul,
          "--model",
          "kimi-fold",
          "--base-url",
          "http://127.0.0.1:#{port}/v1",
          "--api-key-env",
          "T17_AB_KEY",
          "--operator-seed-env",
          "T17_AB_OP",
          "--registry",
          registry
        ] ++ extra
      )
  end

  defp pointer!(registry) do
    %{"log_path" => log_path, "keyring_dir" => keyring} =
      JSON.decode!(File.read!(Path.join([registry, "wisp", "agent.json"])))

    {log_path, keyring}
  end

  # the daemon (and DurableStore) watch the app's :log_path — point it at
  # the agent's store BEFORE booting, or the fold and the feed desync
  defp restart_on!(log_path) do
    Application.stop(:kyber)
    Application.put_env(:kyber, :log_path, log_path)
    {:ok, _} = Application.ensure_all_started(:kyber)
    Daemon.stop()
  end

  defp boot_agent!(registry) do
    {:ok, {:daemon, _line, pid}} =
      CLI.run(["daemon", "--agent", "wisp", "--registry", registry, "--tick-ms", "3600000"])

    pid
  end

  # a human message on the live stream, signed with the ENV-held operator
  # seed — post round-7 HIGH-1 the registry keyring holds NO human.seed, so
  # the old Harness.ingest(keyring) route (which read it from disk) is gone
  defp ingest!(n) do
    {:ok, signed} =
      Events.message_received(
        @operator_seed,
        1.0 * (1_754_720_000_000 + n),
        "message:t17ab:#{n}",
        "channel:t17ab",
        "session:t17ab",
        "hello #{n}"
      )

    :ok = DurableStore.append(Wire.envelope(signed))
  end

  # AC21: no file under the registry is (or contains) the operator seed
  defp assert_no_seed_on_disk!(registry) do
    files = registry |> Path.join("**") |> Path.wildcard(match_dot: true)
    assert Enum.filter(files, &(Path.basename(&1) == "human.seed")) == []

    for file <- files, File.regular?(file) do
      refute File.read!(file) =~ @operator_seed,
             "operator seed VALUE serialized at #{file}"
    end
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

  defp oracle_refusals do
    for {_id, {claims, _sig}} <- DurableStore.set(),
        %{type: "GateDecision", verdict: "refuse", policy: "oracle_gate"} = resolved <-
          [Schema.resolve(claims)],
        do: resolved
  end

  defp response_landed?(content) do
    Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
      match?(%{type: "ResponseDelta", content: ^content}, Schema.resolve(claims))
    end)
  end

  # the operator flips the seed policy as an ordinary AgentSet delta on the
  # LIVE stream — the running daemon's feed subscription hot-swaps it
  defp flip_oracle!(value) do
    {:ok, signed} =
      AgentEvents.agent_set(
        @operator_seed,
        1.0 * System.system_time(:millisecond),
        "wisp",
        %{oracle_seed: value}
      )

    :ok = DurableStore.append(Wire.envelope(signed))
  end

  defp seed_ids do
    for {id, {claims, _sig}} <- DurableStore.set(),
        match?([%{role: "seed"} | _rest], claims.pointers),
        do: id
  end

  defp seed_negated do
    for {_id, {claims, _sig}} <- DurableStore.set(),
        %{role: "negates", target: {:delta, target, _ctx}} <- claims.pointers,
        into: MapSet.new(),
        do: target
  end

  defp live_seed? do
    negated = seed_negated()
    Enum.any?(seed_ids(), &(not MapSet.member?(negated, &1)))
  end

  defp seed_negation_count do
    seeds = MapSet.new(seed_ids())
    Enum.count(seed_negated(), &MapSet.member?(seeds, &1))
  end

  # ------------------------------------------------------------- the tests

  test "daemon --agent boots store -> fold -> boot opts; a live turn runs on the configured provider with the soul in the prompt (AC2)",
       %{registry: registry} do
    port = provider!(self())
    new_agent!(registry, port, ["--oracle-seed", "present"])

    # P5 round-7 HIGH-1 (AC21): the seed lives ONLY in the environment —
    # `agent new` serialized nothing under the registry
    assert_no_seed_on_disk!(registry)

    {log_path, _keyring} = pointer!(registry)
    restart_on!(log_path)
    boot_agent!(registry)

    # the fold reached the live engine: the model is the fold's, not a default
    assert get_in(Daemon.status(), [:config, :live, :model]) == "kimi-fold"

    ingest!(1)

    # the request arrived AT the configured provider (the stub IS the fold's
    # base_url) carrying the fold's model
    assert_receive {:t17_provider, headers, body}, 60_000
    assert body["model"] == "kimi-fold"

    # the soul rides the assembled prompt
    prompt =
      body["messages"]
      |> Enum.map(fn %{"content" => content} -> to_string(content) end)
      |> Enum.join("\n")

    assert prompt =~ "Soul:"
    assert prompt =~ @soul

    # AC19's prompt boundary: the key VALUE never rides the request body —
    # it lives ONLY in the auth header, the transport's own lane
    refute JSON.encode!(body) =~ @key_value
    assert headers["authorization"] == "Bearer " <> @key_value

    # the turn completes: the model's answer lands in the agent's store
    assert eventually(fn -> response_landed?("stub: turn ok") end),
           "no ResponseDelta landed in the agent store"
  end

  test "oracle_seed absent: refuse-only; flipped present, the same store boots open (AC3)",
       %{registry: registry} do
    port = provider!(self())
    # genesis default: oracle_seed "absent"
    new_agent!(registry, port)
    {log_path, _keyring} = pointer!(registry)
    restart_on!(log_path)
    boot_agent!(registry)

    ingest!(1)

    # the prompt is refused at the gate — an attested GateDecision, and the
    # provider is NEVER contacted
    assert eventually(fn -> oracle_refusals() != [] end),
           "no oracle_gate refusal landed in the store"

    refute_received {:t17_provider, _headers, _body}

    # the operator flips the field as an ordinary AgentSet delta on the
    # LIVE stream (through DurableStore — the file alone would desync the
    # running app), then re-boots from the SAME store
    {:ok, signed} =
      AgentEvents.agent_set(
        @operator_seed,
        1.0 * System.system_time(:millisecond),
        "wisp",
        %{oracle_seed: "present"}
      )

    :ok = DurableStore.append(Wire.envelope(signed))

    Daemon.stop()
    boot_agent!(registry)

    # the same prompt path now reaches the model
    ingest!(2)
    assert_receive {:t17_provider, _headers, body}, 60_000
    assert body["model"] == "kimi-fold"
  end

  test "oracle gate hot-flips with the fold — absent -> present -> absent -> present, no re-boot (AC3 hot-arm)",
       %{registry: registry} do
    port = provider!(self())
    # genesis default: oracle_seed "absent"
    new_agent!(registry, port)
    {log_path, _keyring} = pointer!(registry)
    restart_on!(log_path)
    boot_agent!(registry)

    # closed at boot: the prompt is refused, the provider never contacted
    ingest!(1)

    assert eventually(fn -> oracle_refusals() != [] end),
           "no oracle_gate refusal landed in the store"

    refute_received {:t17_provider, _headers, _body}

    # flip present on the LIVE stream. Daemon.status/0 is the no-sleep
    # ordering barrier: the store's fan-out lands the {:delta, ...} in the
    # daemon mailbox BEFORE append returns, so the status call queues after
    # the hot-swap — when it answers, the gate sync has run.
    flip_oracle!("present")
    Daemon.status()
    assert live_seed?(), "hot-swap appended no live seed claim"

    # the same message path now reaches the model — no re-boot anywhere
    ingest!(2)
    assert_receive {:t17_provider, _headers, body}, 60_000
    assert body["model"] == "kimi-fold"

    # flip back: the hot-swap appends the retraction, the gate closes
    flip_oracle!("absent")
    Daemon.status()
    refute live_seed?(), "hot-swap did not retract the live seed claim"

    refusals_before = length(oracle_refusals())
    ingest!(3)

    assert eventually(fn -> length(oracle_refusals()) > refusals_before end),
           "the gate did not close after the absent hot-flip"

    refute_received {:t17_provider, _headers, _body}

    # re-open AFTER a retraction: the fixed-content boot id is retracted, so
    # the hot path mints a FRESH seed claim and the gate opens again
    flip_oracle!("present")
    Daemon.status()
    assert live_seed?(), "re-open after retraction appended no live seed claim"

    ingest!(4)
    assert_receive {:t17_provider, _headers, body}, 60_000
    assert body["model"] == "kimi-fold"
  end

  test "a stale pre-fix human.seed in the keyring is IGNORED: boot pins the env seed, the turn runs (P5 r7 HIGH-1 T4)",
       %{registry: registry} do
    port = provider!(self())
    new_agent!(registry, port, ["--oracle-seed", "present"])
    {log_path, keyring} = pointer!(registry)

    # an agent created BEFORE the fix left the operator seed on disk; worse,
    # plant a DIFFERENT seed value — if any path read the file instead of
    # the environment, the operator pin (and the turn) would diverge
    File.write!(Path.join(keyring, "human.seed"), String.duplicate("9b", 32))

    restart_on!(log_path)
    boot_agent!(registry)

    assert get_in(Daemon.status(), [:config, :live, :model]) == "kimi-fold"

    ingest!(1)
    assert_receive {:t17_provider, _headers, body}, 60_000
    assert body["model"] == "kimi-fold"

    assert eventually(fn -> response_landed?("stub: turn ok") end),
           "no ResponseDelta landed with a stale human.seed present"
  end

  test "a GRANTED agent can never open the oracle gate the operator refused (P5 r10 HIGH-1)",
       %{registry: registry} do
    port = provider!(self())
    # genesis default: oracle_seed "absent" — the operator's refusal
    new_agent!(registry, port)
    {log_path, keyring} = pointer!(registry)
    restart_on!(log_path)
    boot_agent!(registry)

    ingest!(1)

    assert eventually(fn -> oracle_refusals() != [] end),
           "no oracle_gate refusal landed in the store"

    refute_received {:t17_provider, _headers, _body}

    # the operator opens the SELF-CONFIG grant — the widest standing
    # permission an agent can hold
    {:ok, granted} =
      AgentEvents.agent_set(
        @operator_seed,
        1.0 * System.system_time(:millisecond),
        "wisp",
        %{self_config: "true"}
      )

    :ok = DurableStore.append(Wire.envelope(granted))
    assert get_in(Daemon.status(), [:config, :fold, :self_config]) == true

    # ...and the agent, signing with the daemon's OWN key (the fold's
    # admission pin — this is the strongest agent-authored delta there is),
    # tries to flip its own gate open
    {:ok, agent_seed} = Kyber.Keys.load_agent_seed(keyring)

    {:ok, self_flip} =
      AgentEvents.agent_set(
        agent_seed,
        1.0 * System.system_time(:millisecond),
        "wisp",
        %{oracle_seed: "present"}
      )

    :ok = DurableStore.append(Wire.envelope(self_flip))
    Daemon.status()

    # fold-inert: the daemon appended NO seed claim, so the gate is shut
    refute live_seed?(), "a granted agent opened its own oracle gate"

    refusals_before = length(oracle_refusals())
    ingest!(2)

    assert eventually(fn -> length(oracle_refusals()) > refusals_before end),
           "the self-flipped gate let the prompt through"

    refute_received {:t17_provider, _headers, _body}

    # the control: the OPERATOR's identical flip still works, same store,
    # same running daemon — the gate is a judgment call, not a dead field
    flip_oracle!("present")
    Daemon.status()
    assert live_seed?(), "the operator's flip stopped working"

    ingest!(3)
    assert_receive {:t17_provider, _headers, body}, 60_000
    assert body["model"] == "kimi-fold"
  end

  test "oracle hot-flip is idempotent — a gate already matching the fold appends no delta",
       %{registry: registry} do
    # port 9 (discard) — no turn ever dispatches in this test
    new_agent!(registry, 9)
    {log_path, _keyring} = pointer!(registry)
    restart_on!(log_path)
    boot_agent!(registry)

    # absent boot on an absent fold: no seed claim exists
    assert seed_ids() == []

    flip_oracle!("present")
    Daemon.status()
    assert [seed_id] = seed_ids()

    # present over an already-open gate: NO extra seed claim
    flip_oracle!("present")
    Daemon.status()
    assert seed_ids() == [seed_id]

    flip_oracle!("absent")
    Daemon.status()
    refute live_seed?()
    assert seed_negation_count() == 1

    # absent over an already-closed gate: NO extra retraction
    flip_oracle!("absent")
    Daemon.status()
    assert seed_negation_count() == 1
    assert seed_ids() == [seed_id]
  end

  test "show/list print the env NAME, never the key value; the store never learns the value (AC19)",
       %{registry: registry} do
    # port 9 (discard) — no request is ever made in this test
    new_agent!(registry, 9)

    {:ok, shown} = CLI.run(["agent", "show", "wisp", "--registry", registry])
    assert shown =~ "api_key: env T17_AB_KEY"
    refute shown =~ @key_value

    {:ok, listed} = CLI.run(["agent", "list", "--registry", registry])
    assert listed =~ "wisp"
    refute listed =~ @key_value

    {log_path, _keyring} = pointer!(registry)
    refute File.read!(log_path) =~ @key_value
  end
end
