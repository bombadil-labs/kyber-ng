defmodule Kyber.Peer do
  @moduledoc """
  Federation over TCP (spec/07, T9): a `:gen_tcp` listener (stdlib — ZERO
  new deps) that serves the federation wire through the SAME door every
  other path uses (`Kyber.Federation.import/1`). A client connects, sends
  the export text, and the peer imports it; every signature is re-verified
  at the door, so a peer can only ADD signed, content-addressed claims — the
  store only learns. Garbage is refused per line (never a crash); a dropped
  or idle connection is a non-event; store-down answers a clean refusal line.

  **The wire frame (PINNED, rev 2):** a frame = the federation wire text PLUS
  a blank terminator — `wire_text <> "\\n\\n"`. The T5 export byte shape has
  NO trailing newline, so a single `"\\n"` would leave no blank line and the
  first live exchange would deadlock (handler waiting for the terminator,
  sender waiting for the reply). The blank line after the final envelope IS
  the terminator — the one new grammar element.

  **The handler:** reads `:line`-delimited packets (each INCLUDES its
  trailing `"\\n"`), accumulating NON-BLANK packets only (the blank predicate
  is `String.trim(line) == ""` — CRLF-safe; the terminator packet is a
  DELIMITER, DROPPED before joining so `import/1` never counts a phantom
  `skipped`), until a blank packet arrives; joins the accumulated lines with
  `"\\n"` → `Federation.import/1` (the empty frame → `import("")` →
  `ok imported=0 skipped=0 refused=0`). The reply is ONE status line,
  newline-terminated. A recv timeout (idle client) or `:closed` (dropped
  mid-frame) just exits the handler — a non-event; the listener survives both.

  **Socket mechanics (PINNED, rev 2):** the GenServer owns the listen socket
  and loops `:gen_tcp.accept(listen, timeout)` (an accept timeout keeps
  `stop/1` from hanging on the blocking NIF) → `:gen_tcp.controlling_process`
  (THE transfer — without it the handler's first recv fails not_owner) →
  spawn (UNLINKED — a handler crash must not take the listener down) the
  handler → re-accept.
  """

  use GenServer

  alias Kyber.Federation

  # short enough that `stop/1`'s system message is honoured promptly (the
  # accept NIF blocks the loop until it returns), long enough not to spin
  @accept_timeout 100
  # a legit client sends the whole frame in one write, so the handler never
  # waits between lines; this bounds only the idle/never-terminated client
  @recv_timeout 5_000
  @connect_timeout 5_000
  @reply_timeout 5_000

  # ------------------------------------------------------------------ API

  @doc """
  Start a listener on `port` (0 = an ephemeral OS-assigned port).

  The listen socket is opened HERE (in the caller) and its ownership
  transferred to the GenServer, so a bind failure returns `{:error, reason}`
  cleanly — no linked child ever spawns to `{:stop, reason}` and take the
  caller down with it (the CLI's `serve --port <in-use>` must surface a
  one-liner, never crash the operator's shell).
  """
  @spec start_link(port: non_neg_integer()) :: GenServer.on_start()
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)

    case :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true]) do
      {:ok, listen} -> start_owner(listen)
      {:error, reason} -> {:error, reason}
    end
  end

  # start the owner GenServer, then transfer the socket to it and release it
  # to accept; any failure closes the socket so no fd leaks
  defp start_owner(listen) do
    case GenServer.start_link(__MODULE__, listen) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(listen, pid) do
          :ok ->
            send(pid, :accept)
            {:ok, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            :gen_tcp.close(listen)
            {:error, reason}
        end

      {:error, reason} ->
        :gen_tcp.close(listen)
        {:error, reason}
    end
  end

  @doc "The actual bound port (resolves an ephemeral 0 to the real number)."
  @spec port(pid()) :: :inet.port_number()
  def port(pid), do: GenServer.call(pid, :port)

  @doc "Close the listen socket and stop the GenServer."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc """
  The client contract (rev 2): connect, send `wire_text <> "\\n\\n"`, recv
  ONE status line, strip its trailing EOL. `{:error, :timeout}` on a silent
  peer; `{:error, :closed}` on a peer that closes without replying;
  `{:error, reason}` on connect failure.
  """
  @spec send_wire(String.t(), :inet.port_number(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def send_wire(host, port, wire_text) do
    opts = [:binary, packet: :line, active: false]

    case :gen_tcp.connect(to_charlist(host), port, opts, @connect_timeout) do
      {:ok, socket} ->
        result = exchange(socket, wire_text)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange(socket, wire_text) do
    case :gen_tcp.send(socket, wire_text <> "\n\n") do
      :ok ->
        case :gen_tcp.recv(socket, 0, @reply_timeout) do
          {:ok, line} -> {:ok, strip_eol(line)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strip_eol(line) do
    line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
  end

  # ------------------------------------------------------------ callbacks

  @impl true
  def init(listen) do
    # the accept loop is armed by start_owner/1's :accept message AFTER
    # ownership of `listen` has actually transferred to this process (else
    # the first accept would fail not_owner)
    {:ok, %{listen: listen, handlers: 0, refs: MapSet.new()}}
  end

  @impl true
  def handle_info({:armed, ref}, state) do
    {:noreply, %{state | refs: MapSet.put(state.refs, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refs: refs} = state) do
    # a handler died (the listener's ONLY monitors are handlers) — the
    # in-flight count decrements so the cap re-opens
    {:noreply, %{state | handlers: state.handlers - 1, refs: MapSet.delete(refs, ref)}}
  end

  # caps (P5 finding 1 — resource-exhaustion): the idle recv timeout alone
  # bounds only SILENCE, not an actively-streaming client; the accumulator and
  # the handler pool are both bounded so a broken or malicious peer cannot
  # exhaust the serve VM's heap or process table
  @max_frame_bytes 1_048_576
  @max_handlers 16

  @impl true
  def handle_info(:accept, %{listen: listen, handlers: n} = state) do
    case :gen_tcp.accept(listen, @accept_timeout) do
      {:ok, socket} ->
        if n >= @max_handlers do
          # refuse beyond the cap — close immediately, no handler spawned
          :gen_tcp.close(socket)
          send(self(), :accept)
          {:noreply, state}
        else
          hand_off(socket)
          send(self(), :accept)
          {:noreply, %{state | handlers: n + 1}}
        end

      # the accept timeout is the yield point that lets stop/1 run
      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      # the listen socket was closed under us (stop/1) — a clean shutdown
      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:port, _from, %{listen: listen} = state) do
    {:ok, port} = :inet.port(listen)
    {:reply, port, state}
  end

  @impl true
  def terminate(_reason, %{listen: listen}) do
    :gen_tcp.close(listen)
    :ok
  end

  # spawn UNLINKED but MONITORED, transfer ownership, THEN hand the socket
  # over — the handler only touches the socket after it owns it (else recv ->
  # not_owner); the monitor lets the listener track the in-flight count (the
  # P5 handler cap decrements on the DOWN)
  defp hand_off(socket) do
    {handler, ref} = spawn_monitor(fn -> await_socket() end)

    case :gen_tcp.controlling_process(socket, handler) do
      :ok ->
        send(handler, {:socket, socket})
        send(self(), {:armed, ref})

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  # ------------------------------------------------------------- handler

  defp await_socket do
    receive do
      {:socket, socket} -> serve(socket)
    after
      @recv_timeout -> :ok
    end
  end

  defp serve(socket) do
    case recv_frame(socket, [], 0) do
      {:ok, text} ->
        :gen_tcp.send(socket, status_line(text) <> "\n")
        :gen_tcp.close(socket)

      :too_large ->
        # P5 finding 1: a frame over the cap is refused with a clean status.
        # The status must actually REACH the client: the socket's receive
        # buffer holds the client's unread stream at this point, and a bare
        # close(2) with unread data answers with a RST that can eat the
        # status line in flight. shutdown(:write) flushes the status and
        # sends FIN; the bounded drain absorbs the rest of the client's
        # stream so the final close is a clean close, not a reset. A peer
        # that keeps streaming past the drain timeout gets the RST it earns.
        :gen_tcp.send(socket, "err frame_too_large\n")
        :gen_tcp.shutdown(socket, :write)
        drain(socket)
        :gen_tcp.close(socket)

      :drop ->
        :gen_tcp.close(socket)
    end
  end

  # absorb the refused client's remaining stream until it closes (or goes
  # idle for @recv_timeout) — see the :too_large branch for why
  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, _packet} -> drain(socket)
      {:error, _reason} -> :ok
    end
  end

  # accumulate NON-BLANK packets (EOL stripped) until the blank terminator;
  # the terminator packet is dropped, never joined. A recv timeout or a
  # close mid-frame is a non-event -> :drop. The accumulated BYTE COUNT is
  # bounded (@max_frame_bytes) — a frame that exceeds the cap is refused
  # (:too_large), so an actively-streaming client cannot grow the heap
  # without bound (the idle timeout alone bounds only silence).
  defp recv_frame(socket, acc, bytes) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, packet} ->
        if String.trim(packet) == "" do
          {:ok, acc |> Enum.reverse() |> Enum.join("\n")}
        else
          stripped = String.trim_trailing(packet, "\n")
          bytes = bytes + byte_size(stripped)

          if bytes > @max_frame_bytes do
            :too_large
          else
            recv_frame(socket, [stripped | acc], bytes)
          end
        end

      {:error, _reason} ->
        :drop
    end
  end

  # every import outcome renders to ONE parseable status line — never a crash,
  # never unparseable. The err renderer is pinned for every import error shape.
  defp status_line(text) do
    case Federation.import(text) do
      {:ok, report} ->
        "ok imported=#{report.imported} skipped=#{report.skipped} refused=#{length(report.refused)}"

      {:error, :store_not_running} ->
        "err store_not_running"

      {:error, {:import_failed, line_no, _reason}} ->
        "err import_failed:#{line_no}"

      {:error, {:store_exit, info}} ->
        "err store_exit:#{inspect(info)}"

      # defensive completeness (the codebase's idiom): any other tagged error
      # still renders as a clean, parseable status rather than a crash
      {:error, other} ->
        "err #{inspect(other)}"
    end
  end
end
