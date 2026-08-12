defmodule Kyber.Channel.Socket do
  # T15c: a re-sent operator message is collapsed only if the matching
  # unanswered MessageReceived is RECENT (within this window). A stale
  # unanswered one (inference failed / timed out — no ResponseDelta) is NOT
  # treated as a duplicate, so the operator can re-send and retry. See ADLC
  # P5 (PR #5).
  @dup_window_ms 30_000

  @moduledoc """
  The daemon-owned channel socket (T14i D6): a stdlib UNIX-domain socket
  `{:local, <log>.sock}` with a PINNED JSONL line frame, owned by the daemon
  (started under the held lock after the stale-sock reclaim, H2). The
  discovery file IS the socket — no port file exists.

  **The verb set (M7/M8, pinned):** `tail` / `send` / `status` / `tick`.
  Requests are `{"verb":"tail"}`, `{"verb":"send","content":"<text>"}`,
  `{"verb":"status"}`, `{"verb":"tick"}`; responses are `{"ok":true}` or
  `{"error":"<spelling>"}` with error spellings `no_operator_seed` /
  `unknown_profile` / `malformed`. `tail` is NOT a content stream: the
  socket carries only NEW-LINE NOTIFICATIONS (`{"newline": n}` as the log's
  line count grows); the rendered content always comes from the log FILE
  (the pinned stream source). `status` rides the ok response:
  `{"ok":true,"status":{...}}` — the minimal schema extended with the
  status payload, documented here so two builds speak one wire.

  **The frame discipline (H1): RECV-ACCUMULATE until the trailing `\n` on
  BOTH socket arms** — never one-recv-per-request. Packets are accumulated
  until a complete JSONL line is present (safe for JSON — raw newlines
  never appear inside JSON strings); a >64KB line (delivered as many
  fragments at `{:packet, :raw}`) is reconstructed by concatenation alone.

  **Send signing (M5, daemon-side, fail-closed):** a `send` verb mints a
  `message_received` delta signed with the daemon's boot `:operator_seed` —
  an EXPLICIT nil check BEFORE any mint answers `{"error":"no_operator_seed"}`
  (never a raise: `Events.message_received(nil, ...)` raises
  FunctionClauseError). The received ts is DAEMON-stamped at admission
  (never the client's clock); the TUI message id carries a daemon-side
  monotonic per-ms seq (M10): `message:tui:<ts_ms>:<seq>` — two identical
  sends in the same millisecond mint distinct claims.

  **Mode 0600 at bind (M1):** `File.chmod(0o600)` IMMEDIATELY after
  `listen`, before the accept loop serves (UDS binds 0755 by default and
  `:gen_tcp` has no mode option — the residual pre-chmod queue window is
  recorded). With daemon-side signing the client holds zero key material,
  so the filesystem permission IS the auth boundary.

  **Stale-sock reclaim (H2):** the DAEMON removes a stale `<log>.sock`
  under the held lock before this server binds (a kill -9 leaves the file
  behind and the next bind fails `:eaddrinuse` — only `File.rm` unblocks),
  and removes it again in its own `terminate/2`.
  """

  use GenServer

  alias Kyber.{DurableStore, Events, Log, Wire}

  @accept_timeout 100
  @recv_timeout 5_000
  @tick_ms 250

  # ------------------------------------------------------------------- api

  @doc """
  Start the channel socket server. Options: `:socket_path` (required — the
  `{:local, path}` bind address), `:log_path` (the tail source), and
  `:operator_seed` (hex or nil — the send-signing key).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :socket_path)

    case :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, packet: :raw, active: false]) do
      {:ok, listen} ->
        # M1: chmod IMMEDIATELY after listen, before the accept loop serves
        File.chmod(path, 0o600)
        GenServer.start_link(__MODULE__, Map.merge(Map.new(opts), %{listen: listen, path: path}))

      {:error, reason} ->
        {:error, {:bind_failed, reason}}
    end
  end

  @doc "Stop the server (the daemon's terminate removes the socket file, H2)."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :accept)
    {:ok,
     %{
       listen: opts.listen,
       path: opts.path,
       log_path: opts.log_path,
       operator_seed: opts.operator_seed,
       tui_ts: nil,
       tui_seq: 0,
       handlers: 0
     }}
  end

  @impl true
  def handle_info(:accept, %{listen: listen} = state) do
    case :gen_tcp.accept(listen, @accept_timeout) do
      {:ok, socket} ->
        {pid, _ref} = spawn_monitor(fn -> await_socket() end)

        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            send(pid, {:socket, socket, state.log_path, state.operator_seed, self()})
            send(self(), :accept)
            {:noreply, %{state | handlers: state.handlers + 1}}

          {:error, _reason} ->
            :gen_tcp.close(socket)
            send(self(), :accept)
            {:noreply, state}
        end

      # the accept timeout is the yield point that lets stop/1 run
      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | handlers: max(state.handlers - 1, 0)}}
  end

  @impl true
  def handle_call({:mint_tui_send, content}, _from, state) when is_binary(content) do
    # M5: the EXPLICIT nil check BEFORE any mint — never a raise
    case state.operator_seed do
      nil ->
        {:reply, {:error, :no_operator_seed}, state}

      seed ->
        # T15c: collapse a re-sent operator message whose content matches a
        # RECENT (within @dup_window_ms) UNANSWERED MessageReceived already in
        # the store. A bare retry / double-tap would otherwise mint a distinct
        # claim (M10) and spawn a fresh turn — the "triple-send" artifact. An
        # answered message (Wisp has replied) is NOT a duplicate, so a
        # legitimate re-ask still works.
        #
        # ADLC P5 (PR #5) catch: the dedup must be time-bounded. An unanswered
        # MessageReceived whose inference FAILED (network error / timeout /
        # rate-limit — no ResponseDelta ever lands) must not block identical
        # re-sends forever. A stale (> window) unanswered one is treated as a
        # failed turn and is re-sendable; only fresh double-taps collapse.
        dup = open_duplicate?(content)
        if dup do
          {:reply, :ok, state}
        else
          mint_and_append(seed, content, state)
        end
    end
  end

  # mint a message_received delta and append it; returns {:reply, :ok, state}
  # on success, {:reply, {:error, :malformed}, state} otherwise.
  defp mint_and_append(seed, content, state) do
    ts = 1.0 * System.system_time(:millisecond)
    {message_id, state} = next_tui_id(state, ts)

    case Events.message_received(seed, ts, message_id, "channel:tui", "session:tui", content) do
      {:ok, signed} ->
        case DurableStore.append(Wire.envelope(signed)) do
          :ok -> {:reply, :ok, state}
          {:error, _reason} -> {:reply, {:error, :malformed}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :malformed}, state}
    end
  end

  # true iff a RECENT (within @dup_window_ms) MessageReceived delta with
  # `content` exists in the store and has NOT yet been answered (no
  # ResponseDelta/requestRef points at it). The window bounds the collapse:
  # a stale unanswered MessageReceived (the inference failed / timed out, so
  # no ResponseDelta ever landed) is NOT treated as a duplicate, so the
  # operator can re-send and retry. See ADLC P5 (PR #5).
  defp open_duplicate?(content) do
    set = DurableStore.set()
    now = System.system_time(:millisecond)

    Enum.any?(set, fn {id, {claims, _sig}} ->
      message_received?(claims) and content_of(claims) == content and
        recent?(claims.timestamp, now) and not message_answered?(set, id)
    end)
  end

  defp recent?(ts, now) when is_number(ts), do: now - ts <= @dup_window_ms
  defp recent?(_ts, _now), do: false

  # true iff the MessageReceived `msg_id` has been answered: an
  # InferenceRequested points back at it (promptRef) AND a ResponseDelta
  # points back at that inference (requestRef). The chain is two hops
  # (MessageReceived -> InferenceRequested -> ResponseDelta). We match by
  # pointer role+target, NOT first-pointer order — a valid delta may ship its
  # pointers in any order.
  defp message_answered?(set, msg_id) do
    with {:ok, inference_id} <- inference_for_message(set, msg_id) do
      inference_answered?(set, inference_id)
    else
      _ -> false
    end
  end

  defp inference_for_message(set, msg_id) do
    Enum.find_value(set, fn {id, {claims, _sig}} ->
      if delta_id(pointer_target(claims, "promptRef")) == msg_id do
        id
      else
        nil
      end
    end)
    |> case do
      nil -> :none
      id -> {:ok, id}
    end
  end

  defp inference_answered?(set, inference_id) do
    Enum.any?(set, fn {_id, {claims, _sig}} ->
      response_delta?(claims) and delta_id(pointer_target(claims, "requestRef")) == inference_id
    end)
  end

  defp response_delta?(claims) do
    Enum.any?(claims.pointers, fn
      %{role: "type", target: {:entity, "ResponseDelta", _ctx}} -> true
      _other -> false
    end)
  end

  # a delta pointer target decodes to {:delta, id, ctx} (or {:delta, id});
  # return just the id so callers compare order/arity-independently.
  defp delta_id({:delta, id, _ctx}), do: id
  defp delta_id({:delta, id}), do: id
  defp delta_id(_), do: nil

  defp pointer_target(claims, role) do
    case Enum.find(claims.pointers, fn %{role: r} -> r == role; _ -> false end) do
      %{target: target} -> target
      _ -> nil
    end
  end

  defp message_received?(claims) do
    Enum.any?(claims.pointers, fn
      %{role: "type", target: {:entity, "MessageReceived", _ctx}} -> true
      _other -> false
    end)
  end

  defp content_of(claims) do
    case Enum.find(claims.pointers, fn %{role: "content"} -> true; _ -> false end) do
      %{target: {:string, text}} -> text
      _ -> nil
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
    :ok
  end

  # ------------------------------------------------------------- handler

  defp await_socket do
    receive do
      {:socket, socket, log_path, operator_seed, server} ->
        serve(socket, log_path, operator_seed, server)
    after
      @recv_timeout -> :ok
    end
  end

  # the handler owns the socket: active-once receive loop with a 250ms
  # timeout that doubles as the tail poll (the no-sleep idiom — a
  # timeout-only receive never matches mailbox messages, so it cannot
  # swallow the socket data)
  defp serve(socket, log_path, operator_seed, server) do
    :inet.setopts(socket, active: :once)
    handler_loop(socket, %{buf: "", tail: false, cursor: 0, log_path: log_path, operator_seed: operator_seed, server: server})
  end

  defp handler_loop(socket, state) do
    receive do
      {:tcp, socket, data} ->
        :inet.setopts(socket, active: :once)
        handler_loop(socket, accumulate(socket, state, data))

      {:tcp_closed, _socket} ->
        :ok

      {:tcp_error, _socket, _reason} ->
        :ok
    after
      @tick_ms ->
        state =
          if state.tail do
            notify_newlines(socket, state)
          else
            state
          end

        handler_loop(socket, state)
    end
  end

  # H1: RECV-ACCUMULATE until the trailing "\n" before parsing — a packet
  # without a newline is held in the buffer; one or more complete lines are
  # processed in order (a one-shot verb answers and the connection closes;
  # a tail verb answers ok and the connection becomes a notification
  # subscriber)
  defp accumulate(socket, state, data) do
    buf = state.buf <> data

    case :binary.split(buf, "\n") do
      [line, rest] ->
        handle_request(socket, line, %{state | buf: rest})
        # one request per connection: after the first complete line the
        # handler either closes (one-shot) or tails; any further bytes are
        # ignored by the loop's tail state
        state

      [_incomplete] ->
        %{state | buf: buf}
    end
  end

  defp handle_request(socket, line, state) do
    case JSON.decode(line) do
      {:ok, %{"verb" => verb} = request} ->
        dispatch_verb(socket, verb, request, state)

      _malformed ->
        respond_and_close(socket, %{"error" => "malformed"})
    end
  end

  defp dispatch_verb(socket, "tail", _request, state) do
    respond(socket, %{"ok" => true})
    handler_loop(socket, %{state | tail: true, cursor: line_count(state.log_path)})
  end

  defp dispatch_verb(socket, "send", %{"content" => content}, state) when is_binary(content) do
    # the mint rides the daemon-owned server (M10's per-ms seq is
    # daemon-side serialized; M5's nil-seed gate lives there too)
    case GenServer.call(state.server, {:mint_tui_send, content}) do
      :ok -> respond_and_close(socket, %{"ok" => true})
      {:error, spelling} -> respond_and_close(socket, %{"error" => spelling})
    end
  end

  defp dispatch_verb(socket, "send", _request, _state) do
    respond_and_close(socket, %{"error" => "malformed"})
  end

  defp dispatch_verb(socket, "status", _request, _state) do
    status =
      if Process.whereis(Kyber.Daemon) do
        Kyber.Daemon.status()
      else
        %{error: :daemon_not_running}
      end

    respond_and_close(socket, %{"ok" => true, "status" => status})
  end

  defp dispatch_verb(socket, "tick", _request, _state) do
    if Process.whereis(Kyber.Daemon) do
      Kyber.Daemon.tick()
    end

    respond_and_close(socket, %{"ok" => true})
  end

  defp dispatch_verb(socket, _other, _request, _state) do
    respond_and_close(socket, %{"error" => "malformed"})
  end

  # M10: the daemon-side monotonic per-ms seq — two identical sends in the
  # same millisecond mint distinct message ids
  defp next_tui_id(state, ts) do
    ts_ms = trunc(ts)

    {seq, state} =
      if state.tui_ts == ts_ms do
        {state.tui_seq + 1, %{state | tui_seq: state.tui_seq + 1}}
      else
        {1, %{state | tui_ts: ts_ms, tui_seq: 1}}
      end

    {"message:tui:#{ts_ms}:#{seq}", state}
  end

  # the tail poll: notify the subscriber when the log's line count grows —
  # the socket carries ONLY the new-line notification; the rendered content
  # comes from the log file (M7)
  defp notify_newlines(socket, state) do
    count = line_count(state.log_path)

    if count > state.cursor do
      respond(socket, %{"newline" => count})
      %{state | cursor: count}
    else
      state
    end
  end

  defp line_count(log_path) do
    if File.exists?(log_path) do
      log_path |> Log.stream() |> Enum.count()
    else
      0
    end
  end

  defp respond(socket, map) do
    :gen_tcp.send(socket, JSON.encode!(map) <> "\n")
  end

  defp respond_and_close(socket, map) do
    respond(socket, map)
    :gen_tcp.close(socket)
  end
end
