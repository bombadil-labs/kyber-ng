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

  alias Kyber.{DeltaSet, DurableIndex, Log, Store}

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
  T16 (F1) — is `content` an open duplicate within `window_ms`? Answered
  from the store's maintained dedup index in O(1) — the socket's
  `open_duplicate?/1` no longer scans the set (the PR #5 round-5 O(N³)
  finding). The window is passed by the caller (the socket's
  `@dup_window_ms`) so the collapse semantics are byte-identical to the
  pre-index scan.
  """
  @spec dedup_check(String.t(), non_neg_integer()) :: boolean()
  def dedup_check(content, window_ms) do
    GenServer.call(__MODULE__, {:dedup_check, content, window_ms})
  end

  @doc """
  T16 (AC1 observable) — how many times `set/0` has been served since boot.
  Lets a test prove `dedup_check/1` answers from the index without a set()
  rescan (the O(1) seam).
  """
  @spec set_calls() :: non_neg_integer()
  def set_calls do
    GenServer.call(__MODULE__, :set_calls)
  end

  @doc """
  T16 (F2) — the rhizomatic seam: register a subscriber pid. Every delta
  admitted AFTER the write-ahead commit is SENT to each subscriber as
  `{:delta, id, claims}` in commit order (plain `send/2` — a GenServer
  receives it in `handle_info`, any process in `receive`); a refused delta
  is never delivered. Subscribers are a small registered set — a dead pid
  is pruned on the next fan-out, never a crash.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc """
  T19 (FlowLive) — the live subscriber pids, newest registration first (the
  registered set's own order). Dead pids are pruned from the reply so a view
  can never render a corpse, AND from the registered set itself, so a poll
  does not re-sweep the same corpses forever; the set is still authoritatively
  pruned by the fan-out (this call changes no store semantics). `timeout` is
  the caller's own patience — a view on a 1s tick cannot afford the default.
  """
  @spec subscribers(timeout()) :: [pid()]
  def subscribers(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :subscribers, timeout)
  end

  @doc """
  T16 (F2) — remove a subscriber pid. `timeout` is the caller's own patience,
  as with `subscribers/1`: a view unsubscribing from its `terminate/2` cannot
  afford to hold a shutting-down tab for the default five seconds.
  """
  @spec unsubscribe(pid(), timeout()) :: :ok
  def unsubscribe(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unsubscribe, pid}, timeout)
  end

  @doc """
  T16 (F2, P5 fix) — ATOMIC seed+attach in ONE store call: register the
  pid AND hand it the current set snapshot, serialized inside the store.
  Because the store serializes appends, there is no gap between the seed
  and the subscription: any delta committed before this call is in the
  returned set; any delta committed after is delivered by the feed. (The
  fable-5 P5 medium: a separate seed-then-attach permanently loses deltas
  committed between the two calls.)
  """
  @spec subscribe_seeded(pid(), timeout()) :: {:ok, DeltaSet.t()}
  def subscribe_seeded(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe_seeded, pid}, timeout)
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
       # T16 (F1): the dedup index, rebuilt from the replayed set in one pass
       # (PM3 — same fold as live appends, so a fresh boot agrees with a
       # spawned IndexServer seeded from set/0)
       index: DurableIndex.build(set),
       set_calls: 0,
       subscribers: [],
       refused: refused,
       torn: torn,
       failed_appends: 0,
       import_report: %{imported: 0, refused: [], skipped: 0}
     }}
  end

  @impl true
  def handle_call({:append, wire}, _from, state) do
    # T19 (span table): one `:store_append` span per {:append, wire} — the
    # span is TOTAL (L5): built from the pre-validated envelope id/timestamp
    # only, started here and closed in every branch below (outcome known
    # after do_append), including the refused/persist_failed error returns.
    append_span_id = span_id_for_wire(wire)
    if append_span_id, do: emit_append_start(append_span_id, wire)

    {reply, new_state} = do_append(wire, state)
    if append_span_id, do: emit_append_end(append_span_id, reply, state, new_state)

    # U1 (T14a pin 1): the post-commit push cast — immediately after the
    # write-ahead commit accepts the delta, cast it into the reactor (the
    # store process serializes appends, so delivery order == commit order by
    # construction). The cast payload needs Store.verify(wire) re-derivation
    # — the append handler holds only the wire (L10). Where no reactor is
    # running the cast is a verified silent no-op (store-only contexts:
    # durable_store_test, CLI ingest, federation — unaffected). The pulse
    # admission for the ephemeral channel is unchanged.
    #
    # T16 (PM2): the index update + subscriber fan-out happen ONLY in the
    # committed branch — never on persist_failed, so the index can never
    # claim a delta the log does not have. The single Store.verify result
    # feeds BOTH the reactor push and the index/fan-out (one verify per
    # append, not two — P5 low). A RE-APPEND of an identical wire (same
    # content-derived id) is a no-op union in the set — the door deduped
    # it — so the index and subscribers are NOT updated again (P5 low:
    # duplicate inf_by_prompt entries / duplicate feed deliveries). The
    # reactor IS still notified: a re-append after a re-boot is the
    # crash-window replay discipline (pin 17 — the re-asserted fixed-content
    # seed re-dispatches so the reactor re-fires idempotently).
    case reply do
      :ok ->
        case Store.verify(wire) do
          {:ok, delta} ->
            notify_reactor(delta)

            if map_size(new_state.set) > map_size(state.set) do
              committed = %{new_state | index: DurableIndex.add(new_state.index, delta)}
              fanned = fan_out(committed, delta)
              # T19 (span table): one `:fan_out` span per COMMITTED delta —
              # counts only (the store knows pids, not names; L4). Fires
              # after the fan-out so delivered/pruned are the actual numbers.
              emit_fan_out_span(delta, state, fanned)
              {:reply, :ok, fanned}
            else
              # duplicate re-append: the log got the line (append is
              # write-ahead, the door accepted it) but the set did not grow
              # — the index/subscribers already saw this id
              {:reply, :ok, new_state}
            end

          {:error, reason} ->
            # door accepted the wire but verify disagrees (should not
            # happen — admit and verify share the door); keep the commit
            # but do not index what we cannot parse. LOUD: a silent index
            # desync is worse than a crash (P5 round 5 low).
            require Logger

            Logger.error(
              "kyber: DurableStore append committed but verify failed (#{inspect(reason)}) — index NOT updated for #{wire["id"]}"
            )

            {:reply, :ok, new_state}
        end

      _other ->
        {:reply, reply, new_state}
    end
  end

  def handle_call(:set, _from, state),
    do: {:reply, state.set, %{state | set_calls: state.set_calls + 1}}

  def handle_call({:dedup_check, content, window_ms}, _from, state) do
    # T16 (F1): O(1) answer from the maintained index; the window comes
    # from the caller (the socket's @dup_window_ms) so the collapse
    # semantics are byte-identical to the pre-index scan
    now = System.system_time(:millisecond)
    {:reply, DurableIndex.open_duplicate?(state.index, content, now, window_ms), state}
  end

  def handle_call(:set_calls, _from, state), do: {:reply, state.set_calls, state}

  def handle_call({:subscribe, pid}, _from, state) do
    # a fresh subscribe re-seeds the subscriber with the CURRENT index
    # state? No — the feed is forward-only; a late subscriber replays via
    # DurableStore.set/0 itself (IndexServer does this on start_link). The
    # registered set is deduped by pid.
    subs = if pid in state.subscribers, do: state.subscribers, else: [pid | state.subscribers]
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:subscribe_seeded, pid}, _from, state) do
    # P5 fix: the seed snapshot and the registration happen in ONE
    # serialized call, so there is no commit gap between them
    subs = if pid in state.subscribers, do: state.subscribers, else: [pid | state.subscribers]
    {:reply, {:ok, state.set}, %{state | subscribers: subs}}
  end

  def handle_call(:subscribers, _from, state) do
    # the sweep is already paid for, so the pruned list is kept: otherwise
    # every corpse is re-swept by every later poll, inside the process that
    # serializes appends
    subs = Enum.filter(state.subscribers, &Process.alive?/1)
    {:reply, subs, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
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

  # the pin-1 seam: GenServer.cast to the registered reactor name; a cast to
  # a non-existent process is dropped, never a crash. Takes the VERIFIED
  # delta (one verify per append, shared with the index — P5 low).
  defp notify_reactor(delta) do
    GenServer.cast(Kyber.Agent.Reactor, {:ingest, delta})
  end

  # ------------------------------------------------------- T19 span emitters

  # T19 (span table): `:store_append` per append — the wire is NOT
  # pre-validated at this point (the door runs inside do_append), so the
  # envelope id/timestamp are read with a guard: a garbage wire emits no
  # span (emitter calls are TOTAL — a raise here would take the write path
  # down, L5).
  defp span_id_for_wire(wire) do
    if is_binary(wire["id"]), do: "append:" <> wire["id"], else: nil
  end

  defp emit_append_start(span_id, wire) do
    Kyber.Trace.span_start(%{
      span_id: span_id,
      kind: :store_append,
      trace_id: nil,
      parent_id: nil,
      refs: [wire["id"]],
      ts: get_in(wire, ["claims", "timestamp"]),
      data: %{delta_id: wire["id"]}
    })
  end

  # the outcome is the pinned four-way: :committed | :duplicate | :refused |
  # :persist_failed. :committed = the door admitted AND the set grew (the
  # write-ahead landed and the merge is new); :duplicate = the door admitted
  # the identical wire but the set did not grow (never fanned out again —
  # AC1 surfaces it via this outcome); :persist_failed = the write did not
  # land; :refused = the door rejected.
  defp emit_append_end(span_id, reply, state, new_state) do
    outcome =
      case reply do
        :ok -> if map_size(new_state.set) > map_size(state.set), do: :committed, else: :duplicate
        {:error, :persist_failed} -> :persist_failed
        {:error, _reason} -> :refused
      end

    Kyber.Trace.span_end(span_id, %{status: :closed, data: %{outcome: outcome}})
  end

  defp emit_fan_out_span(delta, state, fanned) do
    delivered = length(fanned.subscribers)
    pruned = length(state.subscribers) - delivered

    Kyber.Trace.span_start(%{
      span_id: "fan:" <> delta.id,
      kind: :fan_out,
      trace_id: nil,
      parent_id: nil,
      refs: [delta.id],
      ts: delta.claims.timestamp,
      data: %{delta_id: delta.id, delivered: delivered, pruned: pruned}
    })

    Kyber.Trace.span_end("fan:" <> delta.id, %{status: :closed, data: %{}})
  end

  # T16 (F2/PM4): fan the committed delta out to every subscriber in commit
  # order. A dead subscriber pid is pruned (the prune keeps the registered
  # set bounded) — the fan-out never crashes the store's append path. Plain
  # `send/2`, NOT GenServer.cast: cast wraps the payload as
  # {:'$gen_cast', msg}, which a plain (non-GenServer) subscriber process
  # can never match; `send` delivers `{:delta, id, claims}` verbatim to any
  # process (a GenServer receives it in handle_info, a plain process in
  # receive — the F2 contract).
  defp fan_out(state, delta) do
    {alive, _dead} = Enum.split_with(state.subscribers, &Process.alive?/1)

    Enum.each(alive, fn pid ->
      send(pid, {:delta, delta.id, delta.claims})
    end)

    %{state | subscribers: alive}
  end

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
