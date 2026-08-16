defmodule Kyber.Trace.Collector do
  @moduledoc """
  T19 the span ring buffer + ETS trace index: a GenServer registered under
  its module name, supervised in the dashboard tree (KyberWeb.Application).
  It has NO store/daemon dependency — spans are one-way casts that cannot
  affect a turn's outcome; a collector crash loses only ephemeral traces
  (I7).

  **Tables** (`:named_table, :protected, read_concurrency: true`; the
  collector is the single writer, LiveView reads directly):

    * `:l19_spans` — `:ordered_set` `{trace_id, seq}` → span map (seq = the
      collector's monotonic counter at START; the ring is a bounded window
      over seq)
    * `:l19_traces` — `:set` trace_id → `%{root_seq, root_span_id, status,
      span_count, open, first_ts, truncated, start_mono_ms}`
    * `:l19_by_span` — `:set` span_id → `{trace_id, seq}` (parent/attach)
    * `:l19_by_delta` — `:set` delta_id → `[{trace_id, seq}]` (view-2
      click-through)
    * `:l19_attribution` — `:set` delta_id → trace_id (the SEPARATE
      delta→trace index fed by the reactor's `{:trace_attribution, …}`
      casts and by span refs; SURVIVES span eviction by design — it
      references trace ids, never span ids; eviction-bounded)

  **Caps.** `C = 4096` spans, `T = 256` traces, `P = 1024` spans per trace,
  `@max_trace_age_ms = 60_000` (against the root's `start_mono_ms`,
  monotonic — never `claims.timestamp`). Eviction is checked at every
  span_start/span_end: over C → whole traces oldest-first by `root_seq`,
  preferring `:complete` then `:active`; over P on one trace → that
  trace's oldest NON-ROOT spans are dropped and the row is marked
  `truncated: true` (the root survives — a runaway turn truncates itself,
  not the ring); over T → the oldest row by `root_seq` regardless of
  status, an `:active` victim force-closed `:truncated` before eviction
  (I3 whole-trace intact); a span whose admission would leave T violated
  after eviction is DROPPED — never a partial admit. Eviction deletes from
  ALL tables in the same handler (I4 — no dangling by_delta/by_span).

  **Attach (tree shape, at span START).** (1) `trace_id` given → attach;
  (2) `parent_id` → `:l19_by_span` → inherit; (3) first `refs` id in
  `:l19_by_delta` → inherit; (4) else micro-trace keyed by the first ref
  (untraced deltas — seed, attestation, probe, engine-emitted non-dispatched
  kinds; view 1 renders an "untraced" state for them). FIRST START wins
  (I5); END for unknown/closed id = no-op; refs-less unparented span =
  dropped. When the `:turn` span arrives for an existing trace it is
  RE-ROOTED (root_seq/root_span_id/start_mono_ms → the turn; the trace is
  `:active`) — the append span that created the micro-trace is a sibling,
  and the trace's age is the TURN's age, never the append's.

  **Re-parent pass (M2, mandatory).** On every successful attach (targeted:
  the attached span's refs) and on each `:sweep` (full scan), any micro-
  trace whose first ref now resolves (rule 3) to a NON-micro trace is
  merged into it: spans' `{trace_id, seq}` rewritten with fresh seqs,
  `by_span`/`by_delta`/trace rows maintained atomically in the one handler.

  **Completion/retention.** A trace is `:complete` when its last span's END
  arrives (`open` → 0). A self-sent `{:sweep}` fires every 5 s: `:forming`/
  `:active` traces whose root is older than `@max_trace_age_ms` are force-
  completed (open spans closed `:truncated`), then the re-parent pass runs.
  The sweep is the straggler/crash net only — the normal closers are the
  pinned turn-END sites (`refuse_budget/4`, engine `:answered`).

  **Read API** is guarded (rescue → empty-read, L6): every ETS access
  survives a missing table (collector not running / mid-restart) so the
  LiveView socket never dies.

  Tests drive the sweep by direct `send(Collector, :sweep)` (no
  `Process.sleep`); the `:mono_now` init opt (default
  `&System.monotonic_time/1` — arity-1 `unit -> integer`) lets a test run
  the age logic against a shifted clock.
  """

  use GenServer

  # ------------------------------------------------------------ pinned caps
  @span_cap 4096
  @trace_cap 256
  @per_trace_cap 1024
  @max_trace_age_ms 60_000
  @sweep_ms 5_000
  @attribution_cap 8192

  @spans :l19_spans
  @traces :l19_traces
  @by_span :l19_by_span
  @by_delta :l19_by_delta
  @attribution :l19_attribution

  # ------------------------------------------------------------------- api

  @doc "Start the collector (registered under the module name, node-wide)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Is the collector running on this node?"
  @spec live?() :: boolean()
  def live? do
    Process.whereis(__MODULE__) != nil
  end

  @doc "Totals: traces, spans, by_span, by_delta, attribution (guarded — empty when the tables are absent)."
  @spec stats() :: %{
          traces: non_neg_integer(),
          spans: non_neg_integer(),
          by_span: non_neg_integer(),
          by_delta: non_neg_integer(),
          attribution: non_neg_integer()
        }
  def stats do
    %{
      traces: table_size(@traces),
      spans: table_size(@spans),
      by_span: table_size(@by_span),
      by_delta: table_size(@by_delta),
      attribution: table_size(@attribution)
    }
  end

  @doc "The trace row for `trace_id` (or nil). Guarded."
  @spec trace(binary()) :: map() | nil
  def trace(trace_id) when is_binary(trace_id) do
    guarded_lookup(@traces, trace_id)
  end

  def trace(_), do: nil

  @doc "All live trace ids. Guarded."
  @spec trace_ids() :: [binary()]
  def trace_ids do
    try do
      :ets.tab2list(@traces)
      |> Enum.map(fn {id, _row} -> id end)
      |> Enum.sort()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  @doc "Every live span of a trace, in seq (start) order. Guarded."
  @spec spans_for(binary()) :: [map()]
  def spans_for(trace_id) when is_binary(trace_id) do
    try do
      :ets.select(@spans, [{{{trace_id, :_}, :_}, [], [:"$_"]}])
      |> Enum.map(fn {{_t, _seq}, span} -> span end)
      |> Enum.sort_by(& &1.seq)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  def spans_for(_), do: []

  @doc """
  The spans whose activity referenced `delta_id` (view-2 click-through via
  `:l19_by_delta`), in by_delta order. Guarded.
  """
  @spec spans_for_delta(binary()) :: [map()]
  def spans_for_delta(delta_id) when is_binary(delta_id) do
    try do
      case :ets.lookup(@by_delta, delta_id) do
        [{^delta_id, entries}] ->
          Enum.flat_map(entries, fn {t, s} ->
            case :ets.lookup(@spans, {t, s}) do
              [{_, span}] -> [span]
              [] -> []
            end
          end)

        [] ->
          []
      end
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  def spans_for_delta(_), do: []

  @doc "The attribution-seeded trace for a delta id (post-eviction click-through), or nil."
  @spec attribution(binary()) :: binary() | nil
  def attribution(delta_id) when is_binary(delta_id) do
    guarded_lookup(@attribution, delta_id)
  end

  def attribution(_), do: nil

  @doc """
  Is `delta_id` the id of a traced activity? True when its trace row exists
  with a `:turn` root (it IS a trace root) or a live span of kind
  `:turn`/`:dispatch` references it (it was dispatched). False = the
  "untraced" state view 1 renders. Guarded.
  """
  @spec traced?(binary()) :: boolean()
  def traced?(delta_id) when is_binary(delta_id) do
    try do
      case guarded_lookup(@traces, delta_id) do
        row when is_map(row) ->
          (root_span(delta_id, row) != nil and root_span(delta_id, row).kind == :turn) or
            Enum.any?(spans_for_delta(delta_id), &(&1.kind in [:turn, :dispatch]))

        nil ->
          Enum.any?(spans_for_delta(delta_id), &(&1.kind in [:turn, :dispatch]))
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  def traced?(_), do: false

  @doc "The fan-out counts (delivered/pruned) of the NEWEST fan_out span referencing `delta_id`."
  @spec fan_out_counts(binary()) :: %{
          delivered: non_neg_integer() | nil,
          pruned: non_neg_integer() | nil
        }
  def fan_out_counts(delta_id) when is_binary(delta_id) do
    spans_for_delta(delta_id)
    |> Enum.filter(&(&1.kind == :fan_out))
    |> List.last()
    |> case do
      nil -> %{delivered: nil, pruned: nil}
      span -> %{delivered: span.data[:delivered], pruned: span.data[:pruned]}
    end
  end

  def fan_out_counts(_), do: %{delivered: nil, pruned: nil}

  @doc "The outcome of the NEWEST store_append span referencing `delta_id` (nil when none)."
  @spec append_outcome(binary()) :: atom() | nil
  def append_outcome(delta_id) when is_binary(delta_id) do
    spans_for_delta(delta_id)
    |> Enum.filter(&(&1.kind == :store_append))
    |> List.last()
    |> case do
      nil -> nil
      span -> span.data[:outcome]
    end
  end

  def append_outcome(_), do: nil

  @doc "Is `delta_id` a duplicate re-append (the newest store_append span's outcome)?"
  @spec duplicate?(binary()) :: boolean()
  def duplicate?(delta_id), do: append_outcome(delta_id) == :duplicate

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    :ets.new(@spans, [:named_table, :ordered_set, :protected, read_concurrency: true])
    :ets.new(@traces, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@by_span, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@by_delta, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@attribution, [:named_table, :set, :protected, read_concurrency: true])

    sweep = Process.send_after(self(), :sweep, @sweep_ms)

    {:ok,
     %{
       seq: 0,
       mono_now: Keyword.get(opts, :mono_now, &System.monotonic_time/1),
       sweep: sweep
     }}
  end

  @impl true
  def handle_cast({:span_start, span}, state), do: {:noreply, admit_span(span, state)}

  def handle_cast({:span_end, span_id, payload}, state) do
    {:noreply, close_span(span_id, payload, state)}
  end

  def handle_cast({:trace_attribution, delta_id, turn_id}, state) do
    put_attribution(delta_id, turn_id)
    {:noreply, state}
  end

  # sleep-free test determinism: the call is queued behind every prior cast
  # from this sender, so a returned :sync means those casts were processed
  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:sweep, state) do
    sweep_ref = Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, do_sweep(%{state | sweep: sweep_ref})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # the dynamics contract lists :shutdown as an event — nothing else mutates
  # state; the tables die with the owner (ephemeral by design, I7)
  @impl true
  def terminate(_reason, _state), do: :ok

  # ----------------------------------------------------------- span admit

  defp admit_span(span, state) do
    span_id = span.span_id

    if is_binary(span_id) and :ets.member(@by_span, span_id) do
      # I5: FIRST START wins — a crash-window replay merges into the first
      state
    else
      refs = List.wrap(span[:refs])

      if refs == [] and is_nil(span[:trace_id]) and is_nil(span[:parent_id]) do
        # refs-less unparented span = dropped
        state
      else
        seq = state.seq + 1
        now = state.mono_now.(:millisecond)

        # rules 1-3 resolve an inherited trace; rule 4 falls back to the
        # micro-trace keyed by the first ref
        trace_id = resolve_trace(span, refs) || List.first(refs)

        span_map = %{
          span_id: span_id,
          trace_id: trace_id,
          kind: span.kind,
          parent_id: span[:parent_id],
          refs: refs,
          start_ts: span[:ts],
          start_mono_ms: now,
          end_mono_ms: nil,
          status: :pending,
          data: Map.get(span, :data, %{}),
          seq: seq
        }

        upsert_trace(trace_id, span_map)
        :ets.insert(@spans, {{trace_id, seq}, span_map})
        :ets.insert(@by_span, {span_id, {trace_id, seq}})
        update_by_delta(refs, trace_id, seq, :add)
        put_attribution_for_refs(refs, trace_id)

        state = %{state | seq: seq}

        state =
          if span.kind == :turn and span_id == "turn:" <> trace_id do
            reroot_trace(trace_id, span_map)
            state
          else
            state
          end

        # M2: on every successful attach, merge any micro-trace whose first
        # ref the attached span now resolves (the merged spans consume fresh
        # seqs — the returned state carries the advanced counter)
        state = re_parent_on_attach(refs, trace_id, state)

        state = evict(state)

        # never a partial admit: if T is STILL violated after eviction the
        # new span is dropped (defensive — eviction always restores)
        if table_size(@traces) > @trace_cap do
          drop_span(trace_id, seq)
          state
        else
          state
        end
      end
    end
  end

  # the attach rules, in pinned order (1) trace_id given; (2) parent_id →
  # by_span; (3) first refs id in by_delta. Returns the resolved trace_id
  # (nil => rule 4, micro-trace keyed by the first ref, applied by the
  # caller).
  defp resolve_trace(span, refs) do
    cond do
      is_binary(span[:trace_id]) ->
        span.trace_id

      is_binary(span[:parent_id]) ->
        case guarded_lookup(@by_span, span.parent_id) do
          {t, _s} -> t
          nil -> resolve_by_refs(refs)
        end

      true ->
        resolve_by_refs(refs)
    end
  end

  defp resolve_by_refs(refs) do
    Enum.find_value(refs, fn r ->
      case guarded_lookup(@by_delta, r) do
        [{t, _s} | _] -> t
        nil -> nil
      end
    end)
  end

  # trace row lifecycle: created :forming by the first span; the second
  # span_start flips :forming → :active (the pinned transition); span_count/
  # open maintained here and on close
  defp upsert_trace(trace_id, span_map) do
    case guarded_lookup(@traces, trace_id) do
      nil ->
        :ets.insert(@traces, {trace_id, new_trace_row(span_map)})

      row ->
        row = %{row | span_count: row.span_count + 1, open: row.open + 1}
        row = if row.status == :forming, do: %{row | status: :active}, else: row
        :ets.insert(@traces, {trace_id, row})
    end
  end

  defp new_trace_row(span_map) do
    %{
      root_seq: span_map.seq,
      root_span_id: span_map.span_id,
      status: :forming,
      span_count: 1,
      open: 1,
      first_ts: span_map.start_ts,
      truncated: false,
      start_mono_ms: span_map.start_mono_ms
    }
  end

  # the turn span is the semantic root: when it arrives for an existing
  # trace, re-root (root_seq/root_span_id/start_mono_ms -> the turn, status
  # :active). The trace's age is the TURN's age, never the append's.
  defp reroot_trace(trace_id, turn_span) do
    case guarded_lookup(@traces, trace_id) do
      nil ->
        :ok

      row ->
        :ets.insert(
          @traces,
          {trace_id,
           %{
             row
             | root_seq: turn_span.seq,
               root_span_id: turn_span.span_id,
               status: :active,
               start_mono_ms: turn_span.start_mono_ms
           }}
        )
    end
  end

  defp update_trace_open(trace_id, delta) do
    case guarded_lookup(@traces, trace_id) do
      nil ->
        :ok

      row ->
        open = max(row.open + delta, 0)
        row = %{row | open: open}

        row =
          if open == 0 and row.status in [:forming, :active],
            do: %{row | status: :complete},
            else: row

        :ets.insert(@traces, {trace_id, row})
    end
  end

  # ----------------------------------------------------------- span close

  defp close_span(span_id, payload, state) do
    case guarded_lookup(@by_span, span_id) do
      {trace_id, seq} ->
        case guarded_lookup(@spans, {trace_id, seq}) do
          nil ->
            state

          span ->
            if span.status != :pending or is_integer(span.end_mono_ms) do
              # I5: END for an unknown/closed id = no-op (re-fires coherent)
              # — EXCEPT the one pinned exception: a duplicate store_append
              # re-fires the SAME deterministic span id, and AC1 requires
              # the re-append to surface via the span's :duplicate outcome.
              # The outcome attr is merged latest-wins; status/duration are
              # untouched (the span stays closed, I5 intact).
              if span.kind == :store_append and Map.has_key?(payload, :data) do
                merged = Map.merge(span.data, Map.get(payload, :data, %{}))
                :ets.insert(@spans, {{trace_id, seq}, %{span | data: merged}})
              end

              state
            else
              now = state.mono_now.(:millisecond)
              status = Map.get(payload, :status, :closed)
              data = Map.merge(span.data, Map.get(payload, :data, %{}))
              span = %{span | status: status, end_mono_ms: now, data: data}
              :ets.insert(@spans, {{trace_id, seq}, span})
              update_trace_open(trace_id, -1)
              evict(state)
            end
        end

      nil ->
        state
    end
  end

  # -------------------------------------------------------------- eviction

  # checked at every span_start/span_end (I1): over C -> whole traces
  # oldest-first by root_seq, preferring :complete then :active; over T ->
  # same ordering (the over-T fallback "oldest by root_seq regardless" is
  # the same sort — complete first, then active, then forming). Whole-trace
  # eviction is invariant (I3) — the delete touches all tables per victim.
  defp evict(state) do
    victims = eviction_order()

    Enum.reduce_while(victims, state, fn trace_id, acc ->
      if table_size(@spans) > @span_cap or table_size(@traces) > @trace_cap do
        evict_trace(trace_id)
        {:cont, acc}
      else
        {:halt, acc}
      end
    end)

    # per-trace over-P: drop the trace's oldest NON-ROOT spans (root
    # preserved; row marked truncated) — a runaway turn truncates itself
    for {trace_id, row} <- guarded_tab2list(@traces),
        row.span_count > @per_trace_cap do
      drop_over_p(trace_id, row)
    end

    state
  end

  # complete (0) > active (1) > forming (2); oldest root_seq first within
  # each class
  defp eviction_order do
    @traces
    |> guarded_tab2list()
    |> Enum.sort_by(fn {_id, row} ->
      {eviction_class(row.status), row.root_seq}
    end)
    |> Enum.map(fn {id, _row} -> id end)
  end

  defp eviction_class(:complete), do: 0
  defp eviction_class(:active), do: 1
  defp eviction_class(_forming), do: 2

  # whole-trace eviction: ALL tables in the same handler — no orphan spans,
  # no dangling by_delta/by_span (I3/I4)
  defp evict_trace(trace_id) do
    spans = :ets.select(@spans, [{{{trace_id, :_}, :_}, [], [:"$_"]}])

    Enum.each(spans, fn {{t, seq}, span} ->
      :ets.delete(@spans, {t, seq})
      :ets.delete(@by_span, span.span_id)
      update_by_delta(span.refs, t, seq, :remove)
    end)

    :ets.delete(@traces, trace_id)
  end

  defp drop_over_p(trace_id, row) do
    excess = row.span_count - @per_trace_cap
    root_seq = row.root_seq

    spans =
      :ets.select(@spans, [{{{trace_id, :_}, :_}, [], [:"$_"]}])
      |> Enum.sort_by(fn {{_t, seq}, _s} -> seq end)

    drops =
      spans
      |> Enum.filter(fn {{_t, seq}, _s} -> seq != root_seq end)
      |> Enum.take(excess)

    Enum.each(drops, fn {{t, seq}, span} ->
      :ets.delete(@spans, {t, seq})
      :ets.delete(@by_span, span.span_id)
      update_by_delta(span.refs, t, seq, :remove)
    end)

    open = row.open - Enum.count(drops, fn {_k, span} -> span.status == :pending end)

    :ets.insert(
      @traces,
      {trace_id, %{row | span_count: row.span_count - length(drops), open: open, truncated: true}}
    )
  end

  # roll back a just-admitted span (the "never a partial admit" fallback)
  defp drop_span(trace_id, seq) do
    case guarded_lookup(@spans, {trace_id, seq}) do
      nil ->
        :ok

      span ->
        :ets.delete(@spans, {trace_id, seq})
        :ets.delete(@by_span, span.span_id)
        update_by_delta(span.refs, trace_id, seq, :remove)

        case guarded_lookup(@traces, trace_id) do
          nil ->
            :ok

          row ->
            :ets.insert(
              @traces,
              {trace_id, %{row | span_count: row.span_count - 1, open: max(row.open - 1, 0)}}
            )
        end
    end
  end

  # --------------------------------------------------------------- indexes

  defp update_by_delta(refs, trace_id, seq, op) do
    Enum.each(refs || [], fn r ->
      case guarded_lookup(@by_delta, r) do
        nil ->
          if op == :add, do: :ets.insert(@by_delta, {r, [{trace_id, seq}]})

        entries ->
          entries =
            if op == :add,
              do: entries ++ [{trace_id, seq}],
              else: List.delete(entries, {trace_id, seq})

          if entries == [] do
            :ets.delete(@by_delta, r)
          else
            :ets.insert(@by_delta, {r, entries})
          end
      end
    end)
  end

  defp put_attribution_for_refs(refs, trace_id) do
    Enum.each(refs || [], &put_attribution(&1, trace_id))
  end

  # the SEPARATE delta -> trace index (M3): survives span eviction (its rows
  # reference trace ids, never span ids); eviction-bounded (L10) — at cap,
  # one arbitrary row is deleted per insert
  defp put_attribution(delta_id, trace_id) do
    :ets.insert(@attribution, {delta_id, trace_id})

    if table_size(@attribution) > @attribution_cap do
      # eviction-bounded (L10): drop ONE arbitrary row per over-cap insert
      case :ets.first(@attribution) do
        :"$end_of_table" -> :ok
        key -> :ets.delete(@attribution, key)
      end
    end

    :ok
  end

  # --------------------------------------------------------------- re-parent

  # targeted (attach-time): the attached span's refs may now resolve a
  # micro-trace keyed by that ref — merge it into the attached (non-micro)
  # trace
  defp re_parent_on_attach(refs, attached_trace, state) do
    if non_micro?(attached_trace) do
      Enum.reduce(refs || [], state, fn r, acc ->
        if is_binary(r) and r != attached_trace and micro_trace?(r) do
          merge_trace(r, attached_trace, acc)
        else
          acc
        end
      end)
    else
      state
    end
  end

  # full-scan (sweep-time): every micro-trace whose first ref now resolves
  # (rule 3) to a non-micro trace is merged
  defp re_parent_scan(state) do
    Enum.reduce(guarded_tab2list(@traces), state, fn {trace_id, row}, acc ->
      if micro_trace?(trace_id) do
        key =
          case root_span(trace_id, row) do
            %{refs: refs} -> List.first(refs)
            nil -> nil
          end

        if is_binary(key) do
          case guarded_lookup(@by_delta, key) do
            nil ->
              acc

            entries ->
              case Enum.find(entries, fn {t, _s} -> t != trace_id and non_micro?(t) end) do
                {target, _s} -> merge_trace(trace_id, target, acc)
                nil -> acc
              end
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp micro_trace?(trace_id) do
    case guarded_lookup(@traces, trace_id) do
      nil ->
        false

      row ->
        root = root_span(trace_id, row)
        root != nil and root.kind != :turn
    end
  end

  defp non_micro?(trace_id) do
    case guarded_lookup(@traces, trace_id) do
      nil ->
        false

      row ->
        root = root_span(trace_id, row)
        root != nil and root.kind == :turn
    end
  end

  defp root_span(trace_id, row) do
    guarded_lookup(@spans, {trace_id, row.root_seq})
  end

  # merge a micro trace INTO a non-micro trace: every span rewritten with a
  # fresh seq, by_span/by_delta/trace rows maintained atomically in this
  # one handler (M2 — I2/I4 hold throughout)
  defp merge_trace(from, to, state) do
    spans = :ets.select(@spans, [{{{from, :_}, :_}, [], [:"$_"]}])

    {state, _} =
      Enum.reduce(spans, {state, 0}, fn {{_t, old_seq}, span}, {acc, moved} ->
        seq = acc.seq + 1
        span = %{span | trace_id: to, seq: seq}
        :ets.delete(@spans, {from, old_seq})
        :ets.insert(@spans, {{to, seq}, span})
        :ets.insert(@by_span, {span.span_id, {to, seq}})
        update_by_delta(span.refs, from, old_seq, :remove)
        update_by_delta(span.refs, to, seq, :add)
        put_attribution_for_refs(span.refs, to)
        {%{acc | seq: seq}, moved + 1}
      end)

    # trace rows: delete the micro row, fold its counts into the target
    case guarded_lookup(@traces, from) do
      nil ->
        :ok

      from_row ->
        :ets.delete(@traces, from)

        case guarded_lookup(@traces, to) do
          nil ->
            :ok

          to_row ->
            to_row = %{
              to_row
              | span_count: to_row.span_count + from_row.span_count,
                open: to_row.open + from_row.open,
                truncated: to_row.truncated or from_row.truncated
            }

            to_row =
              if to_row.open == 0 and to_row.status == :forming,
                do: %{to_row | status: :complete},
                else: to_row

            :ets.insert(@traces, {to, to_row})
        end
    end

    # the micro key now resolves into the target trace
    put_attribution(from, to)
    state
  end

  # ------------------------------------------------------------------ sweep

  defp do_sweep(state) do
    now = state.mono_now.(:millisecond)

    # force-complete stragglers/crashes: :forming/:active traces whose root
    # is older than @max_trace_age_ms (against the root's start_mono_ms —
    # monotonic, never claims.timestamp)
    for {trace_id, row} <- guarded_tab2list(@traces),
        row.status in [:forming, :active],
        now - row.start_mono_ms > @max_trace_age_ms do
      force_complete(trace_id, row, now)
    end

    # M2: the sweep-time re-parent pass
    re_parent_scan(state)
  end

  defp force_complete(trace_id, row, now) do
    spans = :ets.select(@spans, [{{{trace_id, :_}, :_}, [], [:"$_"]}])

    Enum.each(spans, fn {{t, seq}, span} ->
      if span.status == :pending do
        closed = %{
          span
          | status: :closed,
            end_mono_ms: now,
            data: Map.put(span.data, :truncated, true)
        }

        :ets.insert(@spans, {{t, seq}, closed})
      end
    end)

    :ets.insert(@traces, {trace_id, %{row | status: :complete, open: 0}})
  end

  # ---------------------------------------------------------------- guards

  # every ETS read is guarded (L6): a missing table (collector not running,
  # mid-restart) reads empty instead of raising ArgumentError
  defp guarded_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp guarded_tab2list(table) do
    :ets.tab2list(table)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp table_size(table) do
    case :ets.info(table, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end
end
