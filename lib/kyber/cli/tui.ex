defmodule Kyber.CLI.TUI do
  @moduledoc """
  The terminal UI (T14i H6/M7/M8/M9/M10/M14): a NON-booting command class —
  the TUI never boots `:kyber` (a booting TUI is a second `DurableStore` on
  the live log, the N1 trap). It connects to a running daemon's channel
  socket (`{:local, <log>.sock}`, the discovery file IS the socket), streams
  the agent's activity, sends operator messages (daemon-signed — the client
  holds zero key material), and exposes inspect commands. The reactor stays
  the single authority — the TUI is a CLIENT, never a second engine.

  **The stream = log-file tail + a pure `render_line/1`** (M7: the socket
  carries only NEW-LINE NOTIFICATIONS; the rendered content always comes
  from the log FILE — the log is the complete record, so the tail is
  late-attach-safe and the renderer is purely testable). The render grammar
  (P1): `>` received / `<` sent / `!` refusal / `~` tool call / `=` result,
  content elided at 120 GRAPHEMES via grapheme-safe `String.slice/2`
  (M9 — never `binary_part`, which severs UTF-8); non-renderable kinds
  render nil. The tail rides the HOLD discipline (M6): invalid-JSON-at-tail
  = HOLD (the daemon's `classify_line/4` `at_tail? -> :halt` precedent),
  distinct from non-renderable-kind = SKIP.

  **The wire (M8, pinned):** requests `{"verb":"tail"}` /
  `{"verb":"send","content":"<text>"}` / `{"verb":"status"}` /
  `{"verb":"tick"}`; responses `{"ok":true}` or `{"error":"<spelling>"}`
  (`no_operator_seed` / `unknown_profile` / `malformed`). The send payload
  is content-only (no client ts) — the DAEMON stamps the received ts at
  admission; the TUI keystroke clock is display-only, never in the delta id
  (M10). The client arm rides the same RECV-ACCUMULATE frame discipline as
  the server (H1 — never one-recv-per-response; the >64KB-line fragment
  test exercises both arms).

  **Wall-clock is allowed ONLY for the operator keystroke** (R2's unargued,
  adopted): input is data, not a decision surface — everything downstream
  claims the received's ts.
  """

  alias Kyber.{Log, Store}

  @elide 120
  @connect_timeout 5_000
  @recv_timeout 5_000

  # ------------------------------------------------------------- rendering

  @doc """
  Render one raw log line to the terminal grammar. Returns:
    - a binary — the rendered line (received/sent/refusal/tool/result);
    - `:hold` — invalid JSON (a torn tail line: HELD, the cursor never
      advances past it — M6);
    - `:skip` — valid JSON that the door refuses or that has no renderable
      kind (non-renderable-kind = SKIP, distinct from HOLD).
  Pure — no IO, no wall-clock, no store.
  """
  @spec render_line(binary()) :: binary() | :hold | :skip
  def render_line(line) do
    case JSON.decode(line) do
      {:error, _reason} ->
        :hold

      {:ok, wire} ->
        case Store.verify(wire) do
          {:ok, %{claims: claims}} -> render_delta(claims)
          {:error, _reason} -> :skip
        end
    end
  end

  @doc """
  The log-tail cursor: from `cursor`, render the new lines with the HOLD
  discipline. Returns `{rendered_lines, new_cursor}` — a torn tail line is
  held (the cursor stays), a mid-log torn line is skipped (the daemon's
  own replay classification), a non-renderable line is skipped.
  """
  @spec tail_cursor(Path.t(), non_neg_integer()) :: {[binary()], non_neg_integer()}
  def tail_cursor(log_path, cursor) do
    lines = log_path |> Log.stream() |> Enum.drop(cursor)
    last_index = length(lines) - 1

    {rendered, new_cursor} =
      lines
      |> Enum.with_index()
      |> Enum.reduce_while({[], cursor}, fn {line, i}, {acc, c} ->
        case render_line(line) do
          :hold when i == last_index -> {:halt, {acc, c}}
          :hold -> {:cont, {acc, c + 1}}
          :skip -> {:cont, {acc, c + 1}}
          text when is_binary(text) -> {:cont, {[text | acc], c + 1}}
        end
      end)

    {Enum.reverse(rendered), new_cursor}
  end

  # ----------------------------------------------------------- socket client

  @doc """
  One-shot request: connect to the daemon's channel socket, send the JSONL
  request, RECV-ACCUMULATE until the trailing `\n` (H1 — the client arm),
  close. Returns `{:ok, response_map}` or `{:error, reason}`.
  """
  @spec request(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(socket_path, request_map) when is_map(request_map) do
    with {:ok, socket} <- connect(socket_path),
         :ok <- :gen_tcp.send(socket, JSON.encode!(request_map) <> "\n"),
         {:ok, line} <- recv_line(socket, ""),
         :ok <- :gen_tcp.close(socket) do
      case JSON.decode(line) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _other -> {:error, :malformed_response}
      end
    end
  end

  @doc ~S|Send an operator message: {"verb":"send","content":...}.|
  @spec send_message(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_message(socket_path, content) when is_binary(content) do
    request(socket_path, %{"verb" => "send", "content" => content})
  end

  @doc "Inspect the daemon's state."
  @spec status(Path.t()) :: {:ok, map()} | {:error, term()}
  def status(socket_path), do: request(socket_path, %{"verb" => "status"})

  @doc "Drive one daemon tick."
  @spec tick(Path.t()) :: {:ok, map()} | {:error, term()}
  def tick(socket_path), do: request(socket_path, %{"verb" => "tick"})

  @doc "Connect to the daemon's channel socket (the discovery file)."
  @spec connect(Path.t()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(socket_path) do
    :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: :raw, active: false], @connect_timeout)
  end

  # the client arm of H1: accumulate packets until the trailing "\n" before
  # parsing — a >64KB response arrives as many fragments and concatenation
  # alone reconstructs it
  defp recv_line(socket, buf) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, packet} ->
        buf = buf <> packet

        case :binary.split(buf, "\n") do
          [line, _rest] -> {:ok, line}
          [_incomplete] -> recv_line(socket, buf)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ------------------------------------------------------------- the loop

  @doc """
  The interactive loop: a tail subscriber prints rendered log lines as they
  land; the operator's stdin lines are sent as operator messages (the ONLY
  wall-clock the TUI owns is the keystroke — the daemon stamps the received
  ts at admission). Reads stdin on the group leader; thin glue over the
  pure/testable pieces. Never returns.
  """
  @spec interactive(Path.t(), Path.t()) :: no_return()
  def interactive(log_path, socket_path) do
    {_rendered, _cursor} = render_all(log_path, 0)

    spawn(fn -> tail_loop(socket_path, log_path, 0) end)

    # the operator keystroke loop (the R2 wall-clock exception)
    read_stdin(socket_path)
  end

  defp render_all(log_path, cursor) do
    {rendered, cursor} = tail_cursor(log_path, cursor)
    Enum.each(rendered, &IO.puts/1)
    {rendered, cursor}
  end

  # a tail subscriber: open the tail connection, then re-render the log from
  # the cursor on every new-line notification (the socket carries only the
  # notification — M7)
  defp tail_loop(socket_path, log_path, cursor) do
    case request(socket_path, %{"verb" => "tail"}) do
      {:ok, %{"ok" => true}} -> tail_wait(socket_path, log_path, cursor)
      _error -> :ok
    end
  end

  defp tail_wait(socket_path, log_path, cursor) do
    with {:ok, socket} <- connect(socket_path) do
      :ok = :gen_tcp.send(socket, JSON.encode!(%{"verb" => "tail"}) <> "\n")
      tail_receive(socket, log_path, cursor)
    else
      _error -> :ok
    end
  end

  defp tail_receive(socket, log_path, cursor) do
    case recv_line(socket, "") do
      {:ok, line} ->
        case JSON.decode(line) do
          {:ok, %{"newline" => _n}} ->
            {_rendered, cursor} = render_all(log_path, cursor)
            tail_receive(socket, log_path, cursor)

          _other ->
            tail_receive(socket, log_path, cursor)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp read_stdin(socket_path) do
    case IO.gets("> ") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        content = String.trim_trailing(line, "\n")

        if content != "" do
          send_message(socket_path, content)
        end

        read_stdin(socket_path)
    end
  end

  # -------------------------------------------------------------- renderer

  # the P1 grammar: > received / < sent / ! refusal / ~ tool call / =
  # result; non-renderable kinds -> nil (SKIP at the caller)
  defp render_delta(claims) do
    case first_role(claims) do
      "received" -> "> " <> elide(content(claims))
      "sent" -> "< " <> elide(content(claims))
      "decides" -> render_refusal(claims)
      "tool" -> "~ " <> elide(tool_desc(claims))
      "call" -> "= " <> elide(result(claims))
      _other -> nil
    end
  end

  defp render_refusal(claims) do
    case pointer(claims, "verdict") do
      {:string, "refuse"} ->
        policy =
          case pointer(claims, "policy") do
            {:string, p} -> p
            _other -> "?"
          end

        "! refused:" <> elide(policy)

      _other ->
        nil
    end
  end

  defp elide(nil), do: ""

  defp elide(content) when is_binary(content) do
    if String.length(content) > @elide do
      String.slice(content, 0, @elide) <> "..."
    else
      content
    end
  end

  defp content(claims) do
    case pointer(claims, "content") do
      {:string, s} -> s
      _other -> nil
    end
  end

  defp result(claims) do
    case pointer(claims, "result") do
      {:string, s} -> s
      _other -> nil
    end
  end

  defp tool_desc(claims) do
    tool =
      case pointer(claims, "tool") do
        {:entity, id, _ctx} -> id
        _other -> "?"
      end

    args =
      case pointer(claims, "args") do
        {:string, s} -> " " <> s
        _other -> ""
      end

    tool <> args
  end

  defp first_role(%{pointers: [%{role: role} | _rest]}), do: role
  defp first_role(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
