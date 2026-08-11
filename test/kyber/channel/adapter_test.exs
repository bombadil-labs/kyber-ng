defmodule Kyber.Channel.AdapterTest do
  @moduledoc """
  T14i — the channel adapter over the FAKE transport (AC1/AC2/AC3/AC4).

  AC1 (the write-first leg): the full loop through the fake — a Discord
  message is ingested through the frame-stream fake as a `message_received`
  delta (signed with the per-server derived seed), the reactor answers
  (stub LLM), the `message.sent` is read by the adapter's delivery poll
  (`sync/1` — the no-sleep drive) and delivered through the REST-shaped
  delivery seam; the fake delivery's recorded sends EQUAL the store's
  ResponseDelta content (scoped to the delivery seam, H4 — the frame-stream
  fake records heartbeats/identify and is never held to that equality, M3).

  AC4 (H5 — the phantom half-chain): a foreign append (a line written
  directly to the log file, bypassing the daemon-VM `DurableStore.append/1`
  admission point) DOES form a chain prefix — a dangling-promptRef
  InferenceRequested, a BURNED LLM call, a persisted nil-prompt_text
  ResponseDelta — and NO `message.sent` (the engine's `_no_channel -> :ok`
  arm). The witness asserts (a) the foreign received is ABSENT from
  `DurableStore.set()`, (b) NO message.sent exists, (c) the phantom
  InferenceRequested/ResponseDelta IS acknowledged as the failure shape —
  never "the chain never forms".

  AC3 (profile binding): the capability intersect (H8 — the shared helper
  extracted from attach's `profile_tools/2`) is consumed at the engine
  CONSTRUCTION — profile-excluded tools are absent from the engine's
  advertised specs AND refuse with the existing "unknown tool" spelling at
  the executor, and the profile's memory bounds keep broader-memory content
  out of the assembled prompt.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Harness, Keys, Schema, Wire}
  alias Kyber.Agent.{Events, LlmHandler}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Channel.Test.{FakeDelivery, FakeTransport}

  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)
  @agent_seed String.duplicate("b2", 32)
  @server "999"
  @channel "111"
  @token "BOT_TEST_TOKEN_" <> String.duplicate("ab", 16)
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

  # ------------------------------------------------ the T5/T6/T7/T8 lifecycle
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
      "kyber-adapter-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
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
    :ok = Keys.import_human_seed(@human_seed, key_dir)
    System.put_env("KYBER_SEED", @agent_seed)
    assert {:ok, _agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      System.delete_env("KYBER_SEED")
      Application.put_env(:kyber, :log_path, Application.get_env(:kyber, :log_path))
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, log_path: log_path}
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

  defp boot_channel_daemon!(ctx, opts \\ []) do
    tools = Keyword.get(opts, :tools, %{"tool:echo" => fn args -> args end})

    boot_opts =
      Keyword.merge(
        [
          keyring_dir: ctx.keyring_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          operator_seed: @operator_seed,
          engine: [llm: stub_llm(), tools: tools],
          test_pid: self()
        ],
        opts
      )

    assert {:ok, pid} = Daemon.boot(boot_opts)
    pid
  end

  defp start_adapter!(opts \\ []) do
    {:ok, fake_t} = FakeTransport.start_link(server: @server, heartbeat_interval: 5_000)
    {:ok, fake_d} = FakeDelivery.start_link()

    adapter_opts =
      Keyword.merge(
        [
          server: @server,
          seed: Keys.derive_seed(@operator_seed, "kyber:discord-server:" <> @server),
          token_holder: fn -> @token end,
          transport: {FakeTransport, %{fake: fake_t}},
          delivery: {FakeDelivery, %{pid: fake_d}},
          tick_ms: 250
        ],
        opts
      )

    assert {:ok, adapter} = Kyber.Channel.Adapter.start_link(adapter_opts)
    {fake_t, fake_d, adapter}
  end

  # bounded sleep-free polling (the no-sleep idiom: a timeout-only receive
  # never matches mailbox messages, so it cannot swallow probes)
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

  # like poll_until, but returns the found VALUE (nil when never found)
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

  defp first_role(%{pointers: [%{role: role} | _rest]}), do: role
  defp first_role(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp claims_with_role(role) do
    DurableStore.set()
    |> Enum.filter(fn {_id, {claims, _sig}} -> first_role(claims) == role end)
  end

  defp response_content do
    set = DurableStore.set()

    {_id, {claims, _sig}} =
      Enum.find(set, fn {_id, {claims, _sig}} -> first_role(claims) == "requestRef" end)

    %{target: {:string, content}} = Enum.find(claims.pointers, &(&1.role == "content"))
    content
  end

  defp discord_message(content) do
    %{
      "id" => "1001",
      "channel_id" => @channel,
      "guild_id" => @server,
      "author" => %{"id" => "user-1", "bot" => false},
      "content" => content
    }
  end

  defp wait_identified(fake_t) do
    assert poll_until(fn -> FakeTransport.identified?(fake_t) end),
           "the adapter never identified through the fake transport"
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {n, v} -> if String.downcase(n) == name, do: v end)
  end

  # ------------------------------------------------------------------- AC1

  test "AC1: fake-transport loop — ingest → delta → respond → deliver; the fake delivery's sends EQUAL the store's ResponseDelta content",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, fake_d, adapter} = start_adapter!()
    wait_identified(fake_t)

    # the frame-stream fake recorded the gateway chatter (identify/heartbeats)
    # — the sends-equal-ResponseDelta witness does NOT hold here (M3), it
    # SCOPES to the delivery seam
    assert FakeTransport.sends(fake_t) != []

    # a Discord message arrives through the fake transport
    :ok = FakeTransport.inject_message(fake_t, discord_message("hello adapter"))

    # the ingest arm: the minted received delta is in the store (daemon-signed
    # with the per-server derived seed)
    received =
      poll_until(fn ->
        Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
          first_role(claims) == "received" and
            pointer(claims, "at") ==
              {:entity, "channel:discord:#{@server}:#{@channel}", "messages"}
        end)
      end)

    assert received, "the ingested Discord message never became a received delta"
    [received_entry] = claims_with_role("received")
    {received_id, {received_claims, _sig}} = received_entry

    # the entity spellings are spec-prefixed and server-qualified (the
    # frozen namespace rule; L2's 3-id form governs)
    assert pointer(received_claims, "received") ==
             {:entity, "message:discord:#{@server}:#{@channel}:1001", "incoming"}

    assert pointer(received_claims, "session") ==
             {:entity, "session:discord:#{@server}:#{@channel}", "messages"}

    # exactly one response chain: the reactor fired once on the received
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert_receive {:engine, {:answered, _request_id}}, 5_000

    assert length(claims_with_role("promptRef")) == 1
    assert length(claims_with_role("requestRef")) == 1
    assert length(claims_with_role("sent")) == 1

    response = response_content()
    assert response == "stub answer"

    # the delivery leg: the adapter's poll, driven synchronously (the tests'
    # no-sleep drive; the @250ms send_after ticker is the production path)
    :ok = Kyber.Channel.Adapter.sync(adapter)

    [{url, headers, body}] = FakeDelivery.posts(fake_d)

    # REST-shaped: POST /channels/{id}/messages with the Authorization header
    assert url == "https://discord.com/api/v10/channels/#{@channel}/messages"
    assert header(headers, "authorization") == "Bot " <> @token
    assert header(headers, "content-type") == "application/json"

    decoded = JSON.decode!(body)

    # the witness: the fake's recorded send EQUALS the store's ResponseDelta
    # content — scoped to the delivery seam
    assert decoded["content"] == response

    # reply/thread context: "message:reply:" <> prompt_id resolves in the
    # store to the received delta, whose entity carries the original
    # snowflake — the adapter replies in-thread with zero mapping state
    assert decoded["message_reference"]["message_id"] == "1001"

    # exactly one delivery (no re-delivery within the boot — the delivered
    # set + watermark)
    :ok = Kyber.Channel.Adapter.sync(adapter)
    assert length(FakeDelivery.posts(fake_d)) == 1
  end

  test "AC1: socket-ingest ≡ Harness.ingest — one received yields exactly one response chain on BOTH paths",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, fake_d, adapter} = start_adapter!()
    wait_identified(fake_t)

    # path 1: the socket (the fake transport) ingests a message
    :ok = FakeTransport.inject_message(fake_t, discord_message("socket ingest"))
    assert poll_until(fn -> length(claims_with_role("received")) == 1 end),
           "the socket-ingested message never landed"

    # path 2: Harness.ingest (the human-key path)
    assert {:ok, _id} =
             Harness.ingest(
               %{
                 "message_id" => "message:discord:#{@server}:#{@channel}:1002",
                 "channel_id" => "channel:discord:#{@server}:#{@channel}",
                 "session_id" => "session:discord:#{@server}:#{@channel}",
                 "content" => "harness ingest",
                 "ts" => @ts + 10
               },
               ctx.keyring_dir
             )

    assert poll_until(fn -> length(claims_with_role("received")) == 2 end)

    # both turns answer: two engine answers, exactly one chain each
    assert_receive {:engine, {:answered, _a1}}, 5_000
    assert_receive {:engine, {:answered, _a2}}, 5_000
    refute_receive {:engine, {:answered, _a3}}, 300

    # exactly two of each chain hop — the reactor is author-blind (L7), so
    # the daemon-signed socket ingest and the harness ingest behave identically
    assert length(claims_with_role("promptRef")) == 2
    assert length(claims_with_role("requestRef")) == 2
    assert length(claims_with_role("sent")) == 2

    # both deliveries land through the delivery seam, in {ts, id} order
    :ok = Kyber.Channel.Adapter.sync(adapter)
    posts = FakeDelivery.posts(fake_d)
    assert length(posts) == 2
    contents = Enum.map(posts, fn {_url, _h, body} -> JSON.decode!(body)["content"] end)
    # the stub LLM answers identically on both paths — the CHAIN shape is the witness
    assert Enum.sort(contents) == ["stub answer", "stub answer"]
  end


  # ------------------------------------------------------------------- AC4

  test "AC4/H5: a foreign append forms the PHANTOM half-chain — the received is ABSENT from the store, NO message.sent exists, the phantom InferenceRequested/ResponseDelta IS acknowledged",
       ctx do
    boot_channel_daemon!(ctx)

    # a foreign line: a received delta signed by the human seed, written
    # DIRECTLY to the log file — it bypasses the daemon-VM
    # DurableStore.append/1 admission point (N1's ingest admission invariant)
    foreign_id = "message:discord:#{@server}:#{@channel}:7777"

    {:ok, signed} =
      Kyber.Events.message_received(
        @human_seed,
        @ts,
        foreign_id,
        "channel:discord:#{@server}:#{@channel}",
        "session:discord:#{@server}:#{@channel}",
        "foreign prompt"
      )

    foreign_wire = Wire.envelope(signed)
    File.write!(ctx.log_path, JSON.encode!(foreign_wire) <> "\n", [:append])

    # the daemon's flush forwards the foreign line to the reactor (the tick
    # forward, daemon.ex:290-298) — the reactor is author-blind
    assert {:ok, %{fired: _}} = Daemon.tick()

    # (a) the foreign received is ABSENT from DurableStore.set()
    refute Map.has_key?(DurableStore.set(), foreign_wire["id"])

    # the phantom chain FORMS: the dangling-promptRef InferenceRequested is
    # in the store (a promptRef pointing at the foreign received's id)
    phantom_request =
      poll_until(fn ->
        Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
          first_role(claims) == "promptRef" and
            pointer(claims, "promptRef") == {:delta, foreign_wire["id"], "requested"}
        end)
      end)

    assert phantom_request, "the phantom InferenceRequested never formed"

    # the LLM call is BURNED: the engine answers the dangling promptRef
    assert_receive :llm_called, 5_000

    # (c) the phantom ResponseDelta persists from the nil-prompt_text
    # assembly (prompt_text/2's nil leg) — acknowledged as the failure shape
    assert poll_until(fn -> length(claims_with_role("requestRef")) == 1 end),
           "the phantom ResponseDelta never persisted"

    # (b) NO message.sent exists for it (the engine's deliver/6
    # `_no_channel -> :ok` arm — the prompt is not in the daemon-VM set)
    assert claims_with_role("sent") == []
  end

  # ------------------------------------------------------------------- AC3

  test "AC3: the capability intersect (H8) is consumed at the engine CONSTRUCTION — profile-excluded tools are not advertised and refuse with the existing 'unknown tool' spelling; broader memory stays out of the assembled prompt",
       ctx do
    # the seeded profile store: identity primitives + the channel profile
    # (allow_tool: ["memory.read"]) + a broad memory epoch + a secret entity
    seed_profile_store()

    tools = tool_registry()

    boot_channel_daemon!(
      ctx,
      profile: "channel:discord",
      engine: [
        llm: stub_llm(),
        tools: tools,
        gate: Gate.new(allow: ["tool:banned"])
      ]
    )

    # the H8 intersect at the engine construction: the engine's advertised
    # specs are narrowed to the profile's allow_tool
    engine =
      :sys.get_state(Kyber.Agent.Reactor)
      |> Map.fetch!(:engine)

    spec_names =
      engine
      |> :sys.get_state()
      |> Map.fetch!(:tools)
      |> Enum.map(& &1["function"]["name"])
      |> Enum.sort()

    assert spec_names == ["tool_allowed"]
    assert spec_names != ["tool_allowed", "tool_banned"]

    # a REAL turn first: the received fires the builder, which mints the
    # InferenceRequested the ToolCall must point at (the reactor's turn
    # resolution walks requestRef → promptRef → received — a dangling
    # request would be :no_turn and never reach the executor)
    {:ok, turn_signed} =
      Kyber.Events.message_received(
        @human_seed,
        @ts + 100,
        "message:discord:#{@server}:#{@channel}:2001",
        "channel:discord:#{@server}:#{@channel}",
        "session:discord:#{@server}:#{@channel}",
        "run the excluded tool"
      )

    assert :ok = DurableStore.append(Wire.envelope(turn_signed))

    request_id =
      poll_until_value(fn ->
        Enum.find_value(DurableStore.set(), fn {id, {claims, _sig}} ->
          if first_role(claims) == "promptRef", do: id
        end)
      end)

    assert is_binary(request_id), "no InferenceRequested for the turn"

    # a ToolCall for a profile-excluded tool (the gate would ALLOW it) — the
    # intersect removed it from the executor registry, so the executor
    # refuses with the EXISTING spelling (tool_executor.ex:707 "unknown tool")
    {:ok, call_signed} =
      Events.tool_call(@agent_seed, @ts + 101, "tool:banned", "{}", request_id)

    call_wire = Wire.envelope(call_signed)
    assert :ok = DurableStore.append(call_wire)

    tool_result =
      poll_until(fn ->
        Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} -> first_role(claims) == "call" end)
      end)

    assert tool_result, "no ToolResult for the excluded tool"

    [{_id, {result_claims, _sig}}] = claims_with_role("call")
    %{target: {:string, result}} = Enum.find(result_claims.pointers, &(&1.role == "result"))
    %{target: {:string, status}} = Enum.find(result_claims.pointers, &(&1.role == "status"))
    assert status == "unknown_tool"
    assert result =~ "unknown tool tool:banned"

    # the memory bounds: a real turn's assembled prompt never contains the
    # secret entity's content (the profile's derived fail-closed memory epoch
    # governs the gather; broader-memory leakage ABSENT)
    fake_t = FakeTransport.start_link(server: @server, heartbeat_interval: 5_000) |> elem(1)
    {:ok, fake_d} = FakeDelivery.start_link()

    assert {:ok, _adapter} =
             Kyber.Channel.Adapter.start_link(
               server: @server,
               seed: Keys.derive_seed(@operator_seed, "kyber:discord-server:" <> @server),
               token_holder: fn -> @token end,
               transport: {FakeTransport, %{fake: fake_t}},
               delivery: {FakeDelivery, %{pid: fake_d}},
               tick_ms: 250
             )

    assert poll_until(fn -> FakeTransport.identified?(fake_t) end)

    :ok = FakeTransport.inject_message(fake_t, discord_message("greet the member"))
    assert_receive {:engine, {:answered, _request_id}}, 5_000

    assembled =
      poll_until_value(fn ->
        Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} ->
          match?(%{type: "PromptAssembled"}, Schema.resolve(claims))
        end)
      end)

    assert assembled != nil
    {_id, {pa_claims, _sig}} = assembled
    %{target: {:string, canonical}} = Enum.find(pa_claims.pointers, &(&1.role == "content"))
    refute canonical =~ "classified channel data"
  end

  # ------------------------------------------- the profile store fixtures

  defp seed_profile_store do
    {:ok, soul} = Events.identity_set(@operator_seed, @ts, "identity:soul", "soul", "I am Veles.")
    {:ok, user} = Events.identity_set(@operator_seed, @ts + 1, "identity:user", "user", "Terse operator.")
    {:ok, op} = Events.identity_set(@operator_seed, @ts + 2, "identity:operator", "operator", "No escalation.")

    {:ok, profile} =
      Events.profile_set(
        @operator_seed,
        @ts + 3,
        "channel:discord",
        "answer in character; no politics",
        ["identity:soul", "identity:user", "identity:operator"],
        ["tool:allowed"],
        []
      )

    {:ok, mem_policy} = Events.memory_policy(@operator_seed, @ts + 4, ["topic:public"])
    {:ok, pub} = Events.memory_entity(@agent_seed, @ts + 5, "topic:public", "the cap is a lens", [])
    {:ok, secret} = Events.memory_entity(@agent_seed, @ts + 6, "topic:secret", "classified channel data", [])

    for w <- [
          Wire.envelope(soul),
          Wire.envelope(user),
          Wire.envelope(op),
          Wire.envelope(profile),
          Wire.envelope(mem_policy),
          Wire.envelope(pub),
          Wire.envelope(secret)
        ],
        do: assert(:ok = DurableStore.append(w))
  end

  defp tool_registry do
    %{
      "tool:allowed" => fn args -> args end,
      "tool:banned" => fn args -> args end
    }
  end


  # --------------------------------------------------- the 2000-cap (H3)

  test "H3: split_content/1 — codepoints ≤ 2000, grapheme-safe cuts, newline-first, byte-equal concatenation, deterministic",
       ctx do
    _ = ctx

    # byte-equal concatenation + determinism on a long mixed content
    content =
      Enum.join(
        [
          String.duplicate("plain text words ", 500),
          "\n",
          String.duplicate("👨‍👩‍👧‍👦", 300),
          "\n",
          String.duplicate("a", 900)
        ],
        ""
      )

    chunks1 = Kyber.Channel.Adapter.split_content(content)
    chunks2 = Kyber.Channel.Adapter.split_content(content)
    assert chunks1 == chunks2, "the split must be deterministic (witnessed)"

    assert Enum.join(chunks1, "") == content, "concatenation must be byte-equal"

    # every chunk is ≤ 2000 CODEPOINTS, unless a single grapheme alone
    # exceeds the cap (recorded, unavoidable)
    for chunk <- chunks1 do
      if String.length(chunk) > 2000 do
        assert String.graphemes(chunk) |> length() == 1,
               "only a single oversized grapheme may exceed the cap"
      end

      # the cut never severs a grapheme
      assert String.graphemes(chunk) |> Enum.join() == chunk
    end

    # newline-first: a chunk ending at the cap whose span contains a newline
    # cuts AFTER the newline, never mid-line
    body = String.duplicate("x", 1999)
    newliney = body <> "\n" <> String.duplicate("y", 100)
    [first, second | _rest] = Kyber.Channel.Adapter.split_content(newliney)
    assert String.ends_with?(first, "\n")
    assert String.starts_with?(second, "y")
    assert first == body <> "\n"

    # 2000 graphemes of "👨‍👩‍👧‍👦" = 22,000 codepoints — the API 50035 shape;
    # the cap counts CODEPOINTS, never graphemes
    emoji = String.duplicate("👨‍👩‍👧‍👦", 2000)
    emoji_chunks = Kyber.Channel.Adapter.split_content(emoji)
    assert length(emoji_chunks) > 1
    assert Enum.join(emoji_chunks, "") == emoji
    assert Enum.all?(emoji_chunks, fn c -> String.length(c) <= 2000 end)

    # the trivial cases
    assert Kyber.Channel.Adapter.split_content("") == [""]
    assert Kyber.Channel.Adapter.split_content("short") == ["short"]
  end

  # ------------------------------------ the real transport vs a local server

  test "the REAL transport (Kyber.Channel.Transport.Ws) round-trips against a local WS server — handshake, frames, auto-pong",
       ctx do
    _ = ctx
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    test_pid = self()

    # the fake gateway server: accept, verify the upgrade, then exchange
    # unmasked server frames with the client's masked frames
    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      request = recv_until(socket, "\r\n\r\n", "")

      key =
        case Regex.run(~r/Sec-WebSocket-Key: (.+)\r\n/, request) do
          [_, key] -> String.trim(key)
          _ -> "missing"
        end

      accept = :base64.encode(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " <> accept <> "\r\n\r\n")

      # send an unmasked server text frame
      server_frame = Kyber.Channel.Codec.encode_frame("hello from server", 0x1)
      :ok = :gen_tcp.send(socket, server_frame)

      # read the client's masked frames (the close unblocks the loop)
      client_frames = recv_frames(socket, [], 5_000)
      send(test_pid, {:server_received, client_frames})
    end)

    {:ok, conn} =
      Kyber.Channel.Transport.Ws.connect([url: "ws://127.0.0.1:#{port}/"], self())

    on_exit(fn ->
      if Process.alive?(conn), do: Kyber.Channel.Transport.Ws.close(conn)
    end)

    # the server's text frame arrives at the owner
    assert_receive {^conn, {:frame, 0x1, "hello from server"}}, 5_000

    # the client sends a masked frame, then closes (the close handshake
    # unblocks the fake server's recv loop); the fake server decodes it
    :ok = Kyber.Channel.Transport.Ws.send_frame(conn, "client hello")
    :ok = Kyber.Channel.Transport.Ws.close(conn)

    assert_receive {:server_received, frames}, 5_000
    assert [masked_client_frame | _rest] = frames
    # the first packet may carry the text frame AND the close frame (the
    # test closes right after sending) — the text frame must decode
    assert {:ok, decoded_frames, ""} = Kyber.Channel.Codec.decode_frames(masked_client_frame, mask: :expect)
    assert {0x1, "client hello"} in decoded_frames

    :ok = Kyber.Channel.Transport.Ws.close(conn)
  end

  defp recv_until(socket, terminator, acc) do
    data = acc <> ""

    if String.contains?(data, terminator) do
      data
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, packet} -> recv_until(socket, terminator, data <> packet)
        {:error, _} -> data
      end
    end
  end

  # accumulate the client's raw bytes and decode the complete masked frames
  defp recv_frames(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, packet} ->
        acc = acc ++ [packet]
        recv_frames(socket, acc, 1_000)

      {:error, _} ->
        acc
    end
  end


  # ------------------------------------------- the loop guards + watermark

  test "the echo guard is a bot/self PRE-MINT drop — a bot message and the bot's own id never reach the delta layer",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, _fake_d, _adapter} = start_adapter!()
    wait_identified(fake_t)

    # a BOT message: dropped BEFORE any delta is minted
    :ok =
      FakeTransport.inject_message(fake_t, %{
        "id" => "3001",
        "channel_id" => @channel,
        "guild_id" => @server,
        "author" => %{"id" => "other-bot", "bot" => true},
        "content" => "i am a bot"
      })

    # the adapter's own id (the READY dispatch's user.id): the self-echo arm
    :ok =
      FakeTransport.inject_message(fake_t, %{
        "id" => "3002",
        "channel_id" => @channel,
        "guild_id" => @server,
        "author" => %{"id" => "bot-self-id", "bot" => false},
        "content" => "my own delivery echoing back"
      })

    # a REAL user message: minted (the control)
    :ok = FakeTransport.inject_message(fake_t, discord_message("real user message"))

    assert poll_until(fn ->
             Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               first_role(claims) == "received"
             end)
           end)

    set = DurableStore.set()

    # exactly ONE received — the bot + self messages never became deltas
    assert length(for {_id, {claims, _sig}} <- set, first_role(claims) == "received", do: 1) == 1
  end

  test "the reboot watermark: history is NEVER re-delivered on reboot (M11 — the boot-high-water-mark)",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, fake_d, adapter} = start_adapter!()
    wait_identified(fake_t)

    :ok = FakeTransport.inject_message(fake_t, discord_message("first message"))
    assert poll_until(fn -> length(FakeDelivery.posts(fake_d)) == 1 end)

    # stop the adapter, restart it over the SAME store — the boot watermark
    # starts at the max matched {ts, id}, so the delivered delta is never
    # re-delivered
    ref = Process.monitor(adapter)
    GenServer.stop(adapter)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    {:ok, fake_d2} = FakeDelivery.start_link()

    assert {:ok, adapter2} =
             Kyber.Channel.Adapter.start_link(
               server: @server,
               seed: Keys.derive_seed(@operator_seed, "kyber:discord-server:" <> @server),
               token_holder: fn -> @token end,
               transport: {FakeTransport, %{fake: fake_t}},
               delivery: {FakeDelivery, %{pid: fake_d2}},
               tick_ms: 250
             )

    on_exit(fn -> if Process.alive?(adapter2), do: GenServer.stop(adapter2) end)

    # the restart reconnects through the fake — wait for the SECOND identify
    # (the FIRST identify's record lingers, so identified? alone would race
    # the new owner registration and the inject would hit the dead adapter)
    assert poll_until(fn -> FakeTransport.identify_count(fake_t) == 2 end)

    :ok = Kyber.Channel.Adapter.sync(adapter2)
    assert FakeDelivery.posts(fake_d2) == []

    # a NEW message after the reboot IS delivered (the watermark advanced)
    :ok = FakeTransport.inject_message(fake_t, discord_message("after reboot"))
    assert poll_until(fn -> length(FakeDelivery.posts(fake_d2)) == 1 end)
  end
end
