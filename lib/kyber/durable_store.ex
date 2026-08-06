defmodule Kyber.DurableStore do
  @moduledoc """
  The door on disk (spec/04-persistence.md §2): THE running store — a
  GenServer that owns both the log device (`Kyber.Log`) and the in-memory
  delta set, so appends are serialized through one process and each
  line+newline is a single `IO.binwrite` (concurrent appends cannot
  interleave; two `DurableStore` instances on one log is out of scope).
  `Kyber.Store` stays the pure door (`admit/2`) that this module reuses for
  both boot replay and every stateful append — there is exactly one
  verification path.

  `start_link/1` replays the log through `Kyber.Store.admit/2` (re-verify
  every signature, re-merge by union), classifying every line exhaustively
  (empty/whitespace skipped silently; a line that fails to parse as JSON is
  torn — reported and skipped; a line that parses but the door rejects is
  refused — reported and skipped; nothing ever halts the boot and nothing on
  disk is ever rewritten or repaired). First boot on a nonexistent path
  yields an empty set — the log is created lazily on the first append, not
  at boot.

  `append/1` is WRITE-AHEAD: verify (`Store.admit/2`) → persist
  (`Kyber.Log.append/2`) → merge. A delta the door rejects is neither
  persisted nor merged and returns the door's own reason unchanged; a
  delta the door accepts but a write fails leaves the in-memory set AND the
  file unchanged, returning `{:error, :persist_failed}` — the merge is only
  ever committed once the write has actually landed.
  """

  use GenServer

  alias Kyber.{DeltaSet, Log, Store}

  @type line_no :: non_neg_integer()
  @type replay_report :: %{
          refused: [line_no()],
          torn: [line_no()],
          failed_appends: non_neg_integer()
        }
  @type import_report :: %{
          imported: non_neg_integer(),
          refused: [line_no()],
          skipped: non_neg_integer()
        }

  @doc "Boot the store: replay `log_path` through the door, then serve."
  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(log_path) do
    GenServer.start_link(__MODULE__, log_path, name: __MODULE__)
  end

  @doc "Write-ahead: verify -> persist -> merge. A rejected delta writes nothing."
  @spec append(map()) :: :ok | {:error, term()}
  def append(wire) do
    GenServer.call(__MODULE__, {:append, wire})
  end

  @doc "The current delta set."
  @spec set() :: DeltaSet.t()
  def set do
    GenServer.call(__MODULE__, :set)
  end

  @doc """
  Re-stream the log from disk and merge whatever it holds now — the daemon's
  ticker calls this so it observes claims another process appended to the same
  `--log` (the operational gate: `kyber ingest` runs in its OWN VM against the
  file the daemon watches, AC2/AC7). Merge is union, so re-reading the
  daemon's own prior appends is a harmless no-op; a concurrent partial final
  line is torn-tolerant (skipped this pass, admitted once the writer completes
  it). Returns the refreshed set. Re-verifies the whole log each call — boring
  and correct for the harness's scale; an incremental tail is a later
  optimization, never a correctness need (the store only learns).
  """
  @spec poll() :: DeltaSet.t()
  def poll do
    GenServer.call(__MODULE__, :poll)
  end

  @doc "The pinned replay observable: refused/torn line numbers from the last boot, plus the live count of failed live appends."
  @spec replay_report() :: replay_report()
  def replay_report do
    GenServer.call(__MODULE__, :replay_report)
  end

  @doc """
  The last `Kyber.Federation.import/1`'s report (rev 2): store-owned state,
  same bare-call semantics as `replay_report/0` (no whereis guard — the
  caller, `Kyber.Federation`, owns store-down handling). Zeros before any
  import has run.
  """
  @spec import_report() :: import_report()
  def import_report do
    GenServer.call(__MODULE__, :import_report)
  end

  @doc """
  Federation-owned: set the live import report, atomically, at import END.
  Internal to the `Kyber.Federation` flow — not part of the door's own
  lifecycle.
  """
  @spec put_import_report(import_report()) :: :ok
  def put_import_report(report) do
    GenServer.call(__MODULE__, {:put_import_report, report})
  end

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(log_path) do
    {set, refused, torn} = replay(log_path)

    {:ok,
     %{
       path: log_path,
       io: nil,
       set: set,
       refused: refused,
       torn: torn,
       failed_appends: 0,
       import_report: %{imported: 0, refused: [], skipped: 0}
     }}
  end

  @impl true
  def handle_call({:append, wire}, _from, state) do
    {reply, new_state} = do_append(wire, state)
    {:reply, reply, new_state}
  end

  def handle_call(:set, _from, state), do: {:reply, state.set, state}

  # re-read the file into the set (a superset of what we held: every append
  # writes the file before it merges, so disk is always >= memory — replacing
  # the set never loses). The boot report (refused/torn) is left untouched;
  # it names the boot replay, not a live poll.
  def handle_call(:poll, _from, state) do
    {set, _refused, _torn} = replay(state.path)
    {:reply, set, %{state | set: set}}
  end

  def handle_call(:replay_report, _from, state) do
    {:reply, %{refused: state.refused, torn: state.torn, failed_appends: state.failed_appends},
     state}
  end

  def handle_call(:import_report, _from, state), do: {:reply, state.import_report, state}

  def handle_call({:put_import_report, report}, _from, state) do
    {:reply, :ok, %{state | import_report: report}}
  end

  @impl true
  def terminate(_reason, %{io: nil}), do: :ok
  def terminate(_reason, %{io: io}), do: File.close(io)

  # ------------------------------------------------------------- write-ahead

  defp do_append(wire, state) do
    case Store.admit(wire, state.set) do
      {:ok, candidate_set} -> persist_then_merge(wire, candidate_set, state)
      {:error, _reason} = err -> {err, state}
    end
  end

  # the merge is only ever applied to `state.set` once the write has landed
  defp persist_then_merge(wire, candidate_set, state) do
    case ensure_open(state) do
      {:ok, io, opened_state} ->
        case Log.append(io, wire) do
          :ok ->
            {:ok, %{opened_state | set: candidate_set}}

          {:error, _reason} ->
            # best-effort close BEFORE dropping the handle: a live-device error
            # (ENOSPC/EIO) leaves the io-server alive, and an unclosed device
            # leaks an fd per failed append (P5 medium finding). A dead device
            # (closed behind our back) is skipped by the alive? guard.
            close_device(io)

            {{:error, :persist_failed},
             %{opened_state | io: nil, failed_appends: opened_state.failed_appends + 1}}
        end

      {:error, _reason} ->
        {{:error, :persist_failed}, state}
    end
  end

  defp close_device(io) when is_pid(io) do
    if Process.alive?(io), do: File.close(io)
    :ok
  end

  defp close_device(_), do: :ok

  # lazy open: the log is created on the first append, never at boot (AC11)
  defp ensure_open(%{io: nil, path: path} = state) do
    case Log.open(path) do
      {:ok, io} -> {:ok, io, %{state | io: io}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_open(%{io: io} = state), do: {:ok, io, state}

  # ------------------------------------------------------------------ replay

  defp replay(path) do
    {set, refused, torn} =
      path
      |> Log.stream()
      |> Stream.with_index(1)
      |> Enum.reduce({DeltaSet.new(), [], []}, &replay_line/2)

    {set, Enum.reverse(refused), Enum.reverse(torn)}
  end

  # exhaustive per-line classification (Req 3): blank -> skip silently;
  # unparseable JSON -> torn (final or mid-log alike — both are reported,
  # skipped, and never repaired); parseable but door-rejected -> refused;
  # door-admitted -> merge. Never halts on a bad line.
  defp replay_line({line, line_no}, {set, refused, torn}) do
    if String.trim(line) == "" do
      {set, refused, torn}
    else
      case JSON.decode(line) do
        {:ok, term} -> replay_term(term, set, refused, torn, line_no)
        {:error, _reason} -> {set, refused, [line_no | torn]}
      end
    end
  end

  defp replay_term(term, set, refused, torn, line_no) do
    case Store.admit(term, set) do
      {:ok, new_set} -> {new_set, refused, torn}
      {:error, _reason} -> {set, [line_no | refused], torn}
    end
  end
end
