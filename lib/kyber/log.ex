defmodule Kyber.Log do
  @moduledoc """
  The append-only wire log (spec/04-persistence.md §2): one signed envelope's
  JSON text per line, newline-terminated. This is a DUMB serializer — it
  cannot verify signatures (that is the door, `Kyber.DurableStore`) and it
  refuses only transport-level failures: non-map input, or a map Elixir's
  stdlib `JSON` cannot encode. In practice that is a value with no
  `JSON.Encoder` implementation (a PID, a tuple, a reference) — NaN/Infinity
  are not representable as Elixir floats at all (see `Rhizomatic.Delta`), so
  that half of the pinned error case is unreachable on the BEAM.

  Torn-write tolerant: `stream/1` hands back whatever bytes are on disk,
  including a truncated final (or mid-file) line, without raising and
  without ever rewriting or deleting anything. Classifying a torn line
  (reported, skipped, never repaired) is the door's job on replay
  (`Kyber.DurableStore`), not this module's.
  """

  @doc "Open the log in append+create mode. Never truncates an existing file."
  @spec open(Path.t()) :: {:ok, File.io_device()} | {:error, term()}
  def open(path) do
    File.open(path, [:append, :binary])
  end

  @doc """
  Append one wire envelope as a single JSON line. Refuses non-map input and
  input `JSON` cannot encode — refusal never touches the file, since the
  whole line is encoded in memory before any write is attempted.
  """
  @spec append(File.io_device(), map()) :: :ok | {:error, term()}
  def append(io, wire) when is_map(wire) do
    case encode(wire) do
      {:ok, json} -> write(io, json)
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  def append(_io, _wire), do: {:error, {:encode, :not_a_map}}

  @doc """
  Lazy stream of raw lines (trailing newline stripped) for replay. Zero
  lines for a missing path — first boot on a nonexistent log is not an
  error (spec/04-persistence.md §2).
  """
  @spec stream(Path.t()) :: Enumerable.t()
  def stream(path) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Stream.map(&strip_eol/1)
    else
      []
    end
  end

  # ------------------------------------------------------------- machinery

  # JSON has no non-raising encode/1 (only encode!/1); a value without a
  # JSON.Encoder implementation raises, so this is the one place that
  # rescues to keep the transport-level refusal a tagged tuple, not a crash.
  defp encode(wire) do
    {:ok, JSON.encode!(wire)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # a single IO.binwrite of the whole line: either the full line lands, or
  # nothing does (torn writes are a caller-side crash artifact, never ours)
  defp write(io, json) do
    case IO.binwrite(io, json <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  rescue
    e -> {:error, {:write, Exception.message(e)}}
  end

  defp strip_eol(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
