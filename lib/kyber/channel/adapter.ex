defmodule Kyber.Channel.Adapter do
  @moduledoc """
  The Discord channel adapter (T14i): a transport on the reactor seam —
  a process, NEVER a second engine. It connects a gateway transport,
  ingests `message_received` deltas minted from the transport's
  MESSAGE_CREATE dispatches (the same event family the reactor already
  dispatches), and delivers `message.sent` deltas back as Discord messages
  through a REST-shaped delivery seam.

  **The two `{module, state}` injections (H4).** The frame-stream transport
  (`Kyber.Channel.Transport` — `connect/send_frame/close`, inbound frames
  as `{ref, {:frame, opcode, payload}}` owner messages) AND the delivery
  seam (`Kyber.Channel.Delivery` — `post(url, headers, body, state)`,
  REST-shaped after http_client.ex:1-9). The token rides ONLY the delivery
  seam's `Authorization: Bot <token>` header — the gateway's op-2/op-6
  payloads are the protocol-required exception (they are never persisted).
  The fake's sends-equal-ResponseDelta witness SCOPES to the delivery seam
  — the frame-stream fake is never held to that equality (M3).

  **The loop.** Ingest: a MESSAGE_CREATE dispatch whose `guild_id` matches
  this adapter's server is minted as a `message_received` delta signed with
  the per-server derived seed (`Keys.derive_seed/2`, context
  `"kyber:discord-server:" <> server_id` — the M4 pinned construction),
  with the entity ids spec-prefixed and server-qualified
  (`channel:discord:<server>:<channel>`,
  `message:discord:<server>:<channel>:<snowflake>`,
  `session:discord:<server>:<channel>`). Replay dedupe is stateless: the
  claimed ts is DERIVED from the snowflake (Discord-epoch ms — the
  transport-derived clock), so a reconnect replay re-mints the SAME delta
  id and merge-is-union dedupes it — no adapter seen-set. The echo guard
  is a bot/self PRE-MINT drop: `author.bot == true` or the bot's own id
  never reaches the delta layer. Deliver: poll `DurableStore.set()`
  @250 ms (`send_after` ticker — never `Process.sleep`) plus
  `sync/1` as the tests' no-sleep drive; the reboot watermark is the
  boot-high-water-mark (history is NEVER re-delivered on reboot) and a
  within-boot delivered-id set gives exactly-once (M11: the across-restart
  residual is AT-MOST-ONCE WITH SILENT LOSS — a crash between poll-read and
  delivery loses that delta). Reply/thread context is store-derived: the
  out-id `"message:reply:" <> prompt_id` resolves in the store to the
  received delta, whose entity carries the original snowflake — the adapter
  replies in-thread with ZERO adapter-side mapping state.

  **The 2000-cap (H3).** Each chunk is ≤ 2000 CODEPOINTS (Discord's live
  cap), the cut lands ONLY at a grapheme boundary (never severing a
  grapheme), newline-first when a newline is within the chunk, and the
  concatenation of the chunks is byte-equal to the original. A single
  grapheme longer than the cap rides as its own (oversized) chunk —
  unavoidable, recorded.

  **Heartbeat-ack-resume (P3).** Heartbeat via `Process.send_after` at the
  hello interval; a missed heartbeat-ack closes and resumes (op 6) with the
  stored `(session_id, seq)`; op 9 non-resumable re-identifies; op 7 closes
  and resumes. Reconnect cadence (M2): a min backoff + jitter via
  `send_after` (a tight resume/identify loop burns Discord's ~1000-
  identifies/day budget), and the RESUME gateway URL is cached — it differs
  from the identify URL. ping→pong is auto-ponged INSIDE the transport
  impl (M3).

  **Intents 33280** = GUILD_MESSAGES (1<<<9) | MESSAGE_CONTENT (1<<<15) —
  settled; DM channels are structurally unreachable (no 1<<<12), guild-only
  consistent with one-server-per-instance. MESSAGE_CONTENT stays privileged
  — the operator enables it in the Discord portal (ops note).

  **Token hygiene (M12).** The token is held OUTSIDE inspectable state as a
  closure (`token_holder`), never an adapter state field — a crash report's
  state render shows the function, not the token; the AC5 byte scanner
  proves absence from the store/log/status bytes.
  """

  use GenServer

  alias Kyber.{DurableStore, Events, Wire}
  alias Kyber.Channel.Transport

  @default_tick_ms 250
  @intents 33_280
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @api_url "https://discord.com/api/v10"
  @min_backoff_ms 1_000
  @max_backoff_ms 60_000
  @max_codepoints 2_000
  @discord_epoch 1_420_070_400_000

  # ------------------------------------------------------------------- api

  @doc """
  Start the adapter. Options:
    - `:server` (required) — the Discord server (guild) id; ONE server per
      gateway instance (the pinned per-server mapping).
    - `:seed` (required) — the per-server signing seed
      (`Keys.derive_seed/2` on the operator seed).
    - `:transport` — `{module, state}` frame-stream injection.
    - `:delivery` (required) — `{module, state}` REST delivery seam.
    - `:token_holder` — `fn -> token end` (the M12 closure).
    - `:intents` (default #{@intents}), `:url` (default the pinned gateway URL).
    - `:store` (thunk, default the durable store), `:tick_ms` (delivery poll).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Run one delivery poll synchronously (the tests' no-sleep drive)."
  @spec sync(GenServer.server()) :: :ok
  def sync(pid), do: GenServer.call(pid, :sync_delivery)

  @doc "The operational shape (no token, no key material)."
  @spec status(GenServer.server()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @doc """
  Split content into Discord-deliverable chunks (H3): each chunk ≤
  #{@max_codepoints} CODEPOINTS, the cut lands ONLY at a grapheme boundary,
  newline-first when a newline is within the chunk, and the concatenation
  is byte-equal to the original. Deterministic — the determinism is
  witnessed in the suite. A single grapheme longer than the cap rides as
  its own (oversized) chunk — cutting it would sever a grapheme.
  """
  @spec split_content(binary()) :: [binary()]
  def split_content(content) when is_binary(content) do
    content |> String.graphemes() |> do_split([], 0, [])
  end

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    seed = Keyword.fetch!(opts, :seed)
    delivery = Keyword.fetch!(opts, :delivery)
    transport = Keyword.get(opts, :transport, {Transport.Ws, %{}})
    store = Keyword.get(opts, :store, &DurableStore.set/0)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    url = Keyword.get(opts, :url, @gateway_url)
    intents = Keyword.get(opts, :intents, @intents)
    token_holder = Keyword.get(opts, :token_holder, fn -> nil end)

    channel_prefix = "channel:discord:" <> server <> ":"
    set = store.()

    state = %{
      server: server,
      channel_prefix: channel_prefix,
      seed: seed,
      transport: transport,
      delivery: delivery,
      store: store,
      tick_ms: tick_ms,
      url: url,
      intents: intents,
      token_holder: token_holder,
      conn: nil,
      monitor: nil,
      seq: nil,
      session_id: nil,
      self_id: nil,
      resume_url: url,
      interval: nil,
      heartbeat_n: 0,
      acked: true,
      backoff: @min_backoff_ms,
      watermark: boot_watermark(set, channel_prefix),
      delivered: MapSet.new(),
      delivered_count: 0,
      identified: false,
      resume: false
    }

    # the gateway connects asynchronously (a boot-time connect failure is a
    # retry, never a boot failure — M2's cadence from the first attempt)
    Process.send_after(self(), :connect, 0)
    Process.send_after(self(), :deliver, tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync_delivery, _from, state) do
    {:reply, :ok, deliver_pending(state)}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       server: state.server,
       connected: state.conn != nil,
       identified: state.identified,
       delivered: state.delivered_count,
       watermark: state.watermark,
       session_id: state.session_id,
       seq: state.seq
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    {mod, tstate} = state.transport
    # M2: the RESUME gateway URL is cached — it differs from the identify URL
    url = if state.resume and state.session_id, do: state.resume_url, else: state.url

    # the connection URL plus the transport's own injected state
    opts = [url: url, state: tstate]

    case mod.connect(opts, self()) do
      {:ok, conn} ->
        ref = Process.monitor(conn)
        {:noreply, %{state | conn: conn, monitor: ref, backoff: @min_backoff_ms}}

      {:error, _reason} ->
        {:noreply, schedule_reconnect(state)}
    end
  end

  # inbound frames from the transport (the owner-message seam)
  def handle_info({ref, {:frame, opcode, payload}}, %{conn: ref} = state) do
    case opcode do
      0x1 -> {:noreply, handle_text(payload, state)}
      # the close frame: the connection ended — reconnect with backoff
      0x8 -> {:noreply, reconnect(state)}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, reconnect(%{state | conn: nil, monitor: nil})}
  end

  def handle_info(:heartbeat, state) do
    # `and` demands booleans — a live conn is a PID, never truthy enough
    if is_pid(state.conn) and is_integer(state.interval) do
      send_heartbeat(state)
      n = state.heartbeat_n + 1
      Process.send_after(self(), {:heartbeat_missed, n}, state.interval)
      {:noreply, %{state | acked: false, heartbeat_n: n}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:heartbeat_missed, n}, %{heartbeat_n: n} = state) do
    if state.acked do
      {:noreply, state}
    else
      # a missed heartbeat-ack ⇒ close + op-6 resume (P3's pin)
      {:noreply, reconnect(state)}
    end
  end

  def handle_info({:heartbeat_missed, _stale}, state), do: {:noreply, state}

  def handle_info(:deliver, state) do
    state = deliver_pending(state)
    Process.send_after(self(), :deliver, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ------------------------------------------------------- gateway protocol

  defp handle_text(payload, state) do
    case JSON.decode(payload) do
      {:ok, %{"op" => op} = msg} -> handle_op(op, msg, state)
      # malformed gateway payload: ignore, never crash
      _other -> state
    end
  end

  defp handle_op(0, %{"t" => t, "d" => d, "s" => s}, state) do
    state = %{state | seq: s}

    case t do
      "MESSAGE_CREATE" -> ingest_message(d, state)
      "READY" ->
        %{state | session_id: d["session_id"], self_id: get_in(d, ["user", "id"]), identified: true, resume: false}

      "RESUMED" ->
        %{state | identified: true, resume: false}

      _other -> state
    end
  end

  # a Discord-requested heartbeat: send one now
  defp handle_op(1, _msg, state) do
    send_heartbeat(state)
    state
  end

  # op 7: reconnect requested — close and resume (op 6)
  defp handle_op(7, _msg, state), do: reconnect(state)

  # op 9: invalid session — d==true ⇒ resume, d==false ⇒ re-identify
  defp handle_op(9, %{"d" => resumable}, state) do
    if resumable, do: reconnect(state), else: reidentify(state)
  end

  defp handle_op(9, _msg, state), do: reidentify(state)

  # op 10: hello — the heartbeat interval + the resume gateway URL (cached,
  # M2: it differs from the identify URL); then identify
  defp handle_op(10, %{"d" => d}, state) do
    interval = d["heartbeat_interval"]
    resume_url = d["resume_gateway_url"] || state.url
    Process.send_after(self(), :heartbeat, interval)
    state = %{state | interval: interval, resume_url: resume_url}

    # a reconnect with a stored session resumes (op 6) on the cached URL; a
    # fresh connect (or a non-resumable session) identifies (op 2)
    if state.resume and state.session_id do
      send_resume(state)
    else
      send_identify(state)
    end

    state
  end

  # op 11: heartbeat-ack
  defp handle_op(11, _msg, state), do: %{state | acked: true}

  defp handle_op(_op, _msg, state), do: state

  defp send_identify(state) do
    payload = %{
      "op" => 2,
      "d" => %{
        "token" => state.token_holder.(),
        "intents" => state.intents,
        "properties" => %{"os" => "linux", "browser" => "kyber", "device" => "kyber"}
      }
    }

    transport_send(state, payload)
  end

  defp send_resume(state) do
    payload = %{
      "op" => 6,
      "d" => %{
        "token" => state.token_holder.(),
        "session_id" => state.session_id,
        "seq" => state.seq
      }
    }

    transport_send(state, payload)
  end

  defp send_heartbeat(state) do
    transport_send(state, %{"op" => 1, "d" => state.seq})
  end

  defp transport_send(state, payload) do
    {mod, _tstate} = state.transport
    mod.send_frame(state.conn, JSON.encode!(payload))
    :ok
  end

  # -------------------------------------------------------------- the loop

  # the echo guard is a bot/self PRE-MINT drop; the server filter is the
  # one-server-per-instance pin; the claimed ts is SNOWFLAKE-DERIVED
  # (transport-derived clock — the stateless replay-dedupe re-mints the
  # same content-derived id and merge-is-union dedupes the reconnect replay)
  defp ingest_message(d, state) do
    author = d["author"] || %{}

    cond do
      d["guild_id"] != state.server ->
        state

      author["bot"] == true ->
        state

      author["id"] == state.self_id ->
        state

      true ->
        channel_id = d["channel_id"]
        snowflake = to_string(d["id"])

        message_id = "message:discord:#{state.server}:#{channel_id}:#{snowflake}"
        channel = "channel:discord:#{state.server}:#{channel_id}"
        session = "session:discord:#{state.server}:#{channel_id}"
        content = d["content"] || ""
        ts = snowflake_ts(snowflake)

        # T14j (C2): the Discord-user attribution mints at ingest — the
        # `discord:user:<id>` STRING pointer (string-kind BY PIN). A missing
        # OR whitespace-only author id mints nil (fail-closed; the /7 nil
        # arm omits the pointer entirely, byte-identical to the legacy /6).
        discord_user =
          case author["id"] do
            id when is_binary(id) ->
              if String.trim(id) == "", do: nil, else: "discord:user:" <> id

            _missing ->
              nil
          end

        case Events.message_received(state.seed, ts, message_id, channel, session, content, discord_user) do
          {:ok, signed} ->
            case DurableStore.append(Wire.envelope(signed)) do
              :ok -> state
              {:error, _reason} -> state
            end

          {:error, _reason} ->
            state
        end
    end
  end

  # the snowflake embeds the creation time: (id >>> 22) + Discord epoch, ms.
  # Deterministic per message — the stateless replay-dedupe clock (M4).
  defp snowflake_ts(snowflake) do
    case Integer.parse(snowflake) do
      {n, ""} -> 1.0 * (Bitwise.bsr(n, 22) + @discord_epoch)
      _other -> 1.0 * System.system_time(:millisecond)
    end
  end

  # ------------------------------------------------------------- delivery

  defp deliver_pending(state) do
    set = state.store.()
    sent = collect_sent(set, state.channel_prefix, state.watermark, state.delivered)

    state =
      Enum.reduce(sent, state, fn entry, st ->
        {st, _records} = deliver_entry(entry, st)
        %{st | delivered: MapSet.put(st.delivered, entry.id), delivered_count: st.delivered_count + 1}
      end)

    case sent do
      [] -> state
      _ -> %{state | watermark: List.last(sent).key}
    end
  end

  # matched message.sent deltas, ordered by {ts, id} (M11 — the sent ts is
  # engine wall-clock ms, so the order is total and a poll drains
  # deterministically)
  defp collect_sent(set, channel_prefix, watermark, delivered) do
    set
    |> Enum.flat_map(fn {id, {claims, _sig}} ->
      with "sent" <- kind(claims),
           {:entity, via, _ctx} <- pointer(claims, "via"),
           {:string, content} <- pointer(claims, "content") do
        if String.starts_with?(via, channel_prefix) do
          key = {claims.timestamp, id}

          if key > watermark and not MapSet.member?(delivered, id) do
            [%{key: key, id: id, channel: channel_tail(via, channel_prefix), content: content, snowflake: reply_snowflake(set, id)}]
          else
            []
          end
        else
          []
        end
      else
        _other -> []
      end
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp deliver_entry(entry, state) do
    {mod, dstate} = state.delivery
    token = state.token_holder.()
    headers = [{"authorization", "Bot " <> token}, {"content-type", "application/json"}]
    url = @api_url <> "/channels/" <> entry.channel <> "/messages"

    records =
      Enum.map(split_content(entry.content), fn chunk ->
        body = JSON.encode!(reply_body(chunk, entry.snowflake))
        {:ok, _response} = mod.post(url, headers, body, dstate)
        {url, headers, body}
      end)

    {state, records}
  end

  defp reply_body(chunk, nil), do: %{"content" => chunk}

  defp reply_body(chunk, snowflake),
    do: %{"content" => chunk, "message_reference" => %{"message_id" => snowflake}}

  # the boot-high-water-mark: the max {ts, id} of matched sent deltas AT BOOT
  # — history is never re-delivered on reboot (M11)
  defp boot_watermark(set, channel_prefix) do
    set
    |> Enum.flat_map(fn {id, {claims, _sig}} ->
      with "sent" <- kind(claims),
           {:entity, via, _ctx} <- pointer(claims, "via") do
        if String.starts_with?(via, channel_prefix), do: [{claims.timestamp, id}], else: []
      else
        _other -> []
      end
    end)
    |> case do
      [] -> {0.0, ""}
      keys -> Enum.max(keys)
    end
  end

  # the store-derived reply context: the out-id "message:reply:" <> prompt_id
  # resolves to the received delta, whose "received" entity carries the
  # original snowflake (zero adapter-side mapping state)
  defp reply_snowflake(set, sent_id) do
    with {sent_claims, _sig} <- Map.get(set, sent_id),
         {:entity, out_id, _ctx} <- pointer(sent_claims, "sent"),
         "message:reply:" <> prompt_id <- out_id,
         {received_claims, _sig} <- Map.get(set, prompt_id),
         {:entity, message_id, _ctx} <- pointer(received_claims, "received") do
      case String.split(message_id, ":") do
        [_prefix, _kind, _server, _channel, snowflake] -> snowflake
        _other -> nil
      end
    else
      _other -> nil
    end
  end

  defp channel_tail(via, channel_prefix), do: binary_part(via, byte_size(channel_prefix), byte_size(via) - byte_size(channel_prefix))

  # -------------------------------------------------------------- reconnect

  # close + reconnect with the min-backoff + jitter cadence (M2); the resume
  # uses the CACHED resume URL and the stored (session_id, seq) when present
  # close + reconnect with the min-backoff + jitter cadence (M2); the
  # reconnection RESUMES (op 6) with the stored (session_id, seq) on the
  # cached resume URL
  defp reconnect(state) do
    if state.conn, do: close_conn(state)
    state = %{state | conn: nil, monitor: nil, interval: nil, identified: false, resume: true}
    schedule_reconnect(state)
  end

  # a non-resumable session (op 9 d==false): drop the stored session,
  # re-identify fresh
  defp reidentify(state) do
    if state.conn, do: close_conn(state)
    state = %{state | conn: nil, monitor: nil, interval: nil, session_id: nil, seq: nil, identified: false, resume: false}
    schedule_reconnect(state)
  end

  defp schedule_reconnect(state) do
    delay = state.backoff + :rand.uniform(state.backoff)
    backoff = min(state.backoff * 2, @max_backoff_ms)
    Process.send_after(self(), :connect, delay)
    %{state | backoff: backoff}
  end

  defp close_conn(state) do
    {mod, _tstate} = state.transport
    mod.close(state.conn)
    :ok
  end

  # ---------------------------------------------------------- the 2000-cap

  # greedy grapheme walk: add graphemes while the codepoint count stays ≤
  # the cap; at the cut, newline-first (cut after the LAST newline within
  # the chunk when one exists — the chunk ends with the newline, the next
  # starts after it); a single grapheme over the cap rides alone (cutting
  # it would sever a grapheme — recorded, unavoidable)
  # the cap unit is CODEPOINTS (H3 — probed: 2000 graphemes of the family
  # emoji = 14,000 codepoints = 50,000 bytes -> API 50035); String.length/1
  # counts GRAPHEMES, so the per-grapheme codepoint count rides
  # String.to_charlist/1 (the codepoint list)
  defp codepoints(s), do: s |> String.to_charlist() |> length()

  defp do_split([], acc, _cps, chunks) do
    Enum.reverse([acc |> Enum.reverse() |> IO.iodata_to_binary() | chunks])
  end

  defp do_split([g | rest], [], 0, chunks) do
    gc = codepoints(g)

    if gc > @max_codepoints do
      do_split(rest, [], 0, [g | chunks])
    else
      do_split(rest, [g], gc, chunks)
    end
  end

  defp do_split([g | rest], acc, cps, chunks) do
    gc = codepoints(g)

    if cps + gc > @max_codepoints do
      chunk = acc |> Enum.reverse() |> IO.iodata_to_binary()

      case :binary.matches(chunk, "\n") do
        [] ->
          do_split([g | rest], [], 0, [chunk | chunks])

        matches ->
          {pos, 1} = List.last(matches)
          head = binary_part(chunk, 0, pos + 1)
          tail = binary_part(chunk, pos + 1, byte_size(chunk) - pos - 1)
          tail_graphemes = if tail == "", do: [], else: String.graphemes(tail)
          # the overflowing grapheme `g` rides the NEXT chunk after the tail
          # (never dropped — byte-equal concatenation is the H3 contract)
          do_split([g | rest], Enum.reverse(tail_graphemes), codepoints(tail), [head | chunks])
      end
    else
      do_split(rest, [g | acc], cps + gc, chunks)
    end
  end

  # -------------------------------------------------------------- machinery

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
