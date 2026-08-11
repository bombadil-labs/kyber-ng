defmodule Kyber.Channel.Transport.Ws do
  @moduledoc """
  The real gateway transport (T14i D1 — the live edge): a hand-rolled RFC
  6455 client over stdlib `:gen_tcp`/`:ssl`, ZERO new deps. The adapter
  injects it as `{module, state}`; tests always inject the frame-stream
  fake instead.

  `connect/2` performs the TCP connect, the TLS upgrade (with the M13
  code-path repair shared from `Kyber.Agent.HttpClient.Httpc` —
  `ensure_http_apps/0` + `otp_ebin_on_path/1`), and the HTTP/1.1 Upgrade
  handshake (the `Sec-WebSocket-Accept` is verified against the key —
  reject, never repair), then hands the owner the frame stream. Frames are
  decoded with the pure `Kyber.Channel.Codec`; a WS ping (op 9) is
  auto-ponged internally (M3 — the pure codec cannot send); text/binary
  frames and the close frame arrive at the owner as
  `{pid, {:frame, opcode, payload}}`. Client frames are masked with a
  crypto-random key (the codec's mask is an argument — random only at the
  live edge, deterministic in tests).
  """

  use GenServer

  @behaviour Kyber.Channel.Transport

  alias Kyber.Channel.Codec

  @opcode_text 0x1
  @opcode_close 0x8
  @opcode_ping 0x9
  @opcode_pong 0xA
  @connect_timeout 10_000
  @handshake_timeout 10_000
  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # ------------------------------------------------------------------- api

  @impl true
  def connect(opts, owner_pid) do
    url = Keyword.fetch!(opts, :url)

    with {:ok, host, port, tls?, path} <- parse_url(url),
         {:ok, socket} <- open_socket(host, port, tls?),
         {:ok, socket, excess} <- handshake(socket, host, path, tls?) do
      state = %{socket: socket, owner: owner_pid, buf: excess, tls: tls?, stop: false}

      case GenServer.start(__MODULE__, state) do
        {:ok, pid} -> transfer(pid, socket, tls?)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # the socket was opened in the CALLER's process — ownership must transfer
  # to the transport process before it can receive (the Peer precedent);
  # the transfer arms the active-once loop
  defp transfer(pid, socket, false) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :arm)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer(pid, socket, true) do
    case apply(:ssl, :controlling_process, [socket, pid]) do
      :ok ->
        send(pid, :arm)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def send_frame(pid, payload) when is_pid(pid) do
    GenServer.call(pid, {:send_frame, payload}, :infinity)
  end

  @impl true
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :close, 5_000)
    else
      :ok
    end
  end

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:send_frame, payload}, _from, state) do
    frame = Codec.encode_frame(payload, @opcode_text, :crypto.strong_rand_bytes(4))

    case send_bytes(state.socket, frame, state.tls) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    frame = Codec.encode_frame("", @opcode_close, :crypto.strong_rand_bytes(4))
    send_bytes(state.socket, frame, state.tls)
    close_socket(state.socket, state.tls)
    {:stop, :normal, :ok, state}
  end

  defp close_socket(socket, false), do: :gen_tcp.close(socket)
  defp close_socket(socket, true), do: apply(:ssl, :close, [socket])

  # the active-once loop is armed AFTER the socket ownership transferred; a
  # non-empty excess buffer (a server frame that landed in the same TCP
  # segment as the 101) is decoded IMMEDIATELY — never waiting for the next
  # packet
  @impl true
  def handle_info(:arm, state) do
    setopts_active(state.socket, state.tls)

    if state.buf == "" do
      {:noreply, state}
    else
      handle_data(state.buf, %{state | buf: ""})
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    handle_data(data, state)
  end

  def handle_info({:ssl, socket, data}, %{socket: socket} = state) do
    handle_data(data, state)
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    notify_closed(state)
  end

  def handle_info({:ssl_closed, socket}, %{socket: socket} = state) do
    notify_closed(state)
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    notify_closed(state)
  end

  def handle_info({:ssl_error, socket, _reason}, %{socket: socket} = state) do
    notify_closed(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_data(data, state) do
    state = process_data(data, state)

    case state.stop do
      true ->
        {:stop, :normal, state}

      _ ->
        setopts_active(state.socket, state.tls)
        {:noreply, state}
    end
  end

  defp notify_closed(state) do
    send(state.owner, {self(), {:frame, @opcode_close, ""}})
    {:stop, :normal, state}
  end

  defp setopts_active(socket, false), do: :inet.setopts(socket, active: :once)
  defp setopts_active(socket, true), do: apply(:ssl, :setopts, [socket, active: :once])

  # ------------------------------------------------------------- machinery

  defp process_data(data, state) do
    buf = state.buf <> data

    case Codec.decode_frames(buf) do
      {:ok, frames, rest} ->
        Enum.reduce(frames, %{state | buf: rest}, fn {opcode, payload}, st ->
          case opcode do
            @opcode_ping ->
              # the pinned auto-pong: answered internally, never forwarded
              # (M3 — the pure codec cannot send)
              frame = Codec.encode_frame(payload, @opcode_pong, :crypto.strong_rand_bytes(4))
              send_bytes(st.socket, frame, st.tls)
              st

            @opcode_close ->
              send(st.owner, {self(), {:frame, @opcode_close, payload}})
              %{st | stop: true}

            other ->
              send(st.owner, {self(), {:frame, other, payload}})
              st
          end
        end)

      {:error, reason} ->
        # a protocol violation on the wire: report the close, stop — the
        # adapter reconnects with backoff (never a raise)
        send(state.owner, {self(), {:frame, @opcode_close, "protocol error: " <> inspect(reason)}})
        %{state | stop: true}
    end
  end

  # ws:// -> plain TCP; wss:// -> TLS over TCP (the M13 repair first)
  defp open_socket(host, port, false) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_socket(host, port, true) do
    with {:ok, _apps} <- Kyber.Agent.HttpClient.Httpc.ensure_http_apps(),
         {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout) do
      case apply(:ssl, :connect, [socket, ssl_options(), @connect_timeout]) do
        {:ok, tls_socket} -> {:ok, tls_socket}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: apply(:public_key, :cacerts_get, []),
      depth: 3,
      customize_hostname_check: [
        match_fun: apply(:public_key, :pkix_verify_hostname_match_fun, [:https])
      ]
    ]
  end

  # the HTTP/1.1 Upgrade handshake: send the request, accumulate until
  # "\r\n\r\n", verify the 101 + Sec-WebSocket-Accept (reject, never
  # repair)
  defp handshake(socket, host, path, tls?) do
    key = :base64.encode(:crypto.strong_rand_bytes(16))

    request =
      "GET " <> path <> " HTTP/1.1\r\n" <>
        "Host: " <> host <> "\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: " <> key <> "\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    with :ok <- send_bytes(socket, request, tls?),
         {:ok, response, excess} <- recv_until(socket, "\r\n\r\n", "", tls?) do
      case verify_accept(response, key) do
        :ok -> {:ok, socket, excess}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_bytes(socket, data, false), do: :gen_tcp.send(socket, data)

  defp send_bytes(socket, data, true) do
    case apply(:ssl, :send, [socket, data]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # accumulate until the terminator; the EXCESS bytes past the terminator
  # (a server frame that landed in the same TCP segment as the 101) ride
  # back as the initial decode buffer — never dropped (the sibling of H1)
  defp recv_until(socket, terminator, acc, tls?) do
    data = acc

    case :binary.split(data, terminator) do
      [head, rest] ->
        {:ok, head <> terminator, rest}

      [_incomplete] ->
        case recv_bytes(socket, tls?) do
          {:ok, packet} -> recv_until(socket, terminator, data <> packet, tls?)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp recv_bytes(socket, false) do
    case :gen_tcp.recv(socket, 0, @handshake_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_bytes(socket, true) do
    case apply(:ssl, :recv, [socket, 0, @handshake_timeout]) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_accept(response, key) do
    case Regex.run(~r/^HTTP\/1\.1 (\d{3})/, response) do
      [_, "101"] ->
        expected = :base64.encode(:crypto.hash(:sha, key <> @ws_guid))

        if String.contains?(response, "sec-websocket-accept: " <> expected) or
             String.contains?(response, "Sec-WebSocket-Accept: " <> expected) do
          :ok
        else
          {:error, :bad_websocket_accept}
        end

      [_, status] ->
        {:error, {:handshake_status, status}}

      nil ->
        {:error, :malformed_handshake}
    end
  end

  # "wss://host:port/path?query" / "ws://..." — the gateway URL's default
  # port is 443 (wss) / 80 (ws); the path defaults to "/"
  defp parse_url(url) do
    case Regex.run(~r/^(wss?):\/\/([^\/:]+)(?::(\d+))?([^\s]*)$/, url) do
      [_, scheme, host, port, path] ->
        {tls?, port} =
          case scheme do
            "wss" -> {true, if(port == "", do: 443, else: String.to_integer(port))}
            "ws" -> {false, if(port == "", do: 80, else: String.to_integer(port))}
          end

        {:ok, host, port, tls?, if(path == "", do: "/", else: path)}

      nil ->
        {:error, :malformed_url}
    end
  end
end
