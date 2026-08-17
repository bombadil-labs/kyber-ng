defmodule Kyber.Live.SpanLifecycleTest do
  @moduledoc """
  T19 pre-impl tests: the span/trace lifecycle dynamics contract and the
  eight invariants I1–I8 (spec "Dynamics contract"). Sleep-free: casts
  from this test process are drained with a synchronous `:sync` call (queued
  behind every prior cast), the sweep is driven by direct `send`, and the
  age logic runs against an injected shifted monotonic clock.
  """

  use ExUnit.Case, async: false

  import Kyber.Live.SpanFixtures

  alias Kyber.Trace.Collector

  # ---------------------------------------------------------------- helpers

  defp start_collector(opts \\ []) do
    start_supervised!({Collector, opts})
  end

  defp sync, do: GenServer.call(Collector, :sync)

  defp emit_start(span) do
    Kyber.Trace.span_start(span)
    sync()
  end

  defp emit_end(span_id, payload) do
    Kyber.Trace.span_end(span_id, payload)
    sync()
  end

  defp live_spans(trace_id), do: Collector.spans_for(trace_id)

  # ------------------------------------------------------------ I1 — totals

  test "I1: totals never exceed C/T/P — eviction restores on span_start" do
    start_collector()

    # 300 traces × 3 spans — over T (256); every turn closed so victims are
    # preferred :complete
    for i <- 1..300 do
      t = "i1-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      emit_start(turn_span(t))
      emit_start(dispatch_span(t, "i1-d#{i}"))
      emit_end("turn:" <> t, closed())
    end

    stats = Collector.stats()
    assert stats.traces <= 256, "T violated: #{stats.traces}"
    assert stats.spans <= 4096, "C violated: #{stats.spans}"

    for t <- Collector.trace_ids() do
      assert length(live_spans(t)) <= 1024, "P violated for #{t}"
    end
  end

  # ------------------------------------------------------------ I2 — orphans

  test "I2: every live span's trace row exists; span_count/open match" do
    start_collector()

    t = "i2"
    emit_start(turn_span(t))
    emit_start(dispatch_span(t, "i2-d1"))
    emit_start(llm_span(t, "i2-r1"))
    emit_end("turn:" <> t, closed())
    emit_end("dispatch:i2-d1", closed(%{handler_result: :emit}))

    row = Collector.trace(t)
    assert row.span_count == 3
    assert row.open == 1

    for span <- live_spans(t) do
      assert Collector.trace(span.trace_id) != nil, "orphan span #{span.span_id}"
    end

    # by_span agrees with the spans table
    for {_span_id, {tid, _seq}} <- :ets.tab2list(:l19_by_span) do
      assert Collector.trace(tid) != nil
    end
  end

  # ------------------------------------------------------------ I3 — whole trace

  test "I3: whole-trace eviction — no trace row ever holds a partial span list" do
    start_collector()

    for i <- 1..300 do
      t = "i3-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      emit_start(turn_span(t))
      emit_start(dispatch_span(t, "i3-d#{i}"))
      emit_end("turn:" <> t, closed())
    end

    # the oldest :complete trace is a whole-trace victim: row AND spans gone
    refute Collector.trace("i3-001")
    assert live_spans("i3-001") == []

    # every surviving row is exactly consistent with its span list
    for t <- Collector.trace_ids() do
      row = Collector.trace(t)
      assert length(live_spans(t)) == row.span_count
    end
  end

  # ------------------------------------------------------- I4 — by_delta/by_span

  test "I4: by_span/by_delta hold exactly the live spans' entries; the attribution index survives eviction" do
    start_collector()

    for i <- 1..300 do
      t = "i4-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      d = "i4-delta-#{i}"
      emit_start(turn_span(t))
      emit_start(dispatch_span(t, d, refs: [d]))
      emit_end("turn:" <> t, closed())
      # M3: the reactor's attribution casts
      Kyber.Trace.attribution(d, t)
    end

    sync()

    # every by_span entry points at a live span
    for {_span_id, {tid, seq}} <- :ets.tab2list(:l19_by_span) do
      assert :ets.lookup(:l19_spans, {tid, seq}) != [], "dangling by_span #{tid}/#{seq}"
    end

    # every by_delta entry points at a live span (no dangling click-through)
    for {_delta, entries} <- :ets.tab2list(:l19_by_delta) do
      for {tid, seq} <- entries do
        assert :ets.lookup(:l19_spans, {tid, seq}) != [], "dangling by_delta #{tid}/#{seq}"
      end
    end

    # the attribution index SURVIVED the flood (it references trace ids,
    # never span ids — eviction never dangles it)
    assert :ets.info(:l19_attribution, :size) > 0
    assert Collector.attribution("i4-delta-1") != nil
  end

  # ------------------------------------------------------------ I5 — id rules

  test "I5: first START wins; END for unknown/closed id is a no-op" do
    start_collector()

    t = "i5"
    emit_start(turn_span(t, ts: 1_111.0))
    emit_start(turn_span(t, ts: 2_222.0))

    # first-wins: the span keeps the FIRST start's ts
    [span] = live_spans(t)
    assert span.start_ts == 1_111.0

    emit_end("turn:" <> t, closed())
    emit_end("turn:" <> t, closed(%{outcome: :refused}))
    emit_end("no-such-span", closed())

    assert length(live_spans(t)) == 1
    assert Collector.trace(t).open == 0
  end

  test "refs-less unparented span is dropped" do
    start_collector()

    Kyber.Trace.span_start(%{span_id: "dispatch:orphan", kind: :dispatch, ts: 1.0, data: %{}})
    sync()
    assert Collector.stats().spans == 0
  end

  # ------------------------------------------------------------ I6 — secrets

  test "I6: no span payload carries a seed, api_key, or raw args/results (redaction scan)" do
    start_collector()

    secret_key = "sk-live-0123456789abcdef0123456789abcdef"
    secret_seed = String.duplicate("cd", 32)
    secret_args = ~s({"command": "echo LEAKED_ARGS"})
    secret_result = "LEAKED_RESULT"

    # emit the six call-site shapes — the data maps contain ONLY the pinned
    # attrs (pre-validated fields); the secrets live in the surrounding
    # context and must never ride a span
    emit_start(turn_span("i6", data: %{gate: :open, budget_cap: 32}))
    emit_start(dispatch_span("i6", "i6-d", data: %{delta_kind: "received"}))
    emit_start(llm_span("i6", "i6-r1", 1, data: %{model: "deepseek-v4-flash"}))
    emit_start(tool_span("i6", "i6-c", data: %{tool_id: "tool:echo"}))
    emit_start(append_span("i6-a", data: %{delta_id: "i6-a", outcome: :committed}))
    emit_start(fan_span("i6-a", data: %{delta_id: "i6-a", delivered: 2, pruned: 0}))

    emit_end("turn:i6", closed())
    emit_end("dispatch:i6-d", closed(%{handler_result: :emit}))
    emit_end("llm:i6-r1#1", closed(%{outcome: :answered}))
    emit_end("tool:i6-c", closed(%{result_status: "ok"}))

    secrets = [secret_key, secret_seed, secret_args, secret_result]

    spans =
      :ets.tab2list(:l19_spans)
      |> Enum.map(fn {_k, span} -> span end)

    assert spans != []

    for span <- spans do
      refute payload_contains?(span, secrets), "secret leaked into span #{inspect(span.span_id)}"
      refute Enum.any?([:seed, :api_key, :args, :result, :author], &Map.has_key?(span.data, &1))
    end
  end

  defp payload_contains?(term, secrets) do
    case term do
      bin when is_binary(bin) -> Enum.any?(secrets, &String.contains?(bin, &1))
      map when is_map(map) ->
        Enum.any?(map, fn {k, v} -> payload_contains?(k, secrets) or payload_contains?(v, secrets) end)

      list when is_list(list) -> Enum.any?(list, &payload_contains?(&1, secrets))
      _other -> false
    end
  end

  # ------------------------------------------------------------ I7 — isolation

  test "I7: the collector never calls the store or daemon (one-way casts)" do
    # this suite runs with :kyber stopped (test_helper) — no store, no daemon
    refute Process.whereis(Kyber.DurableStore)
    refute Process.whereis(Kyber.Daemon)

    start_collector()
    emit_start(turn_span("i7"))
    assert Collector.stats().spans == 1

    # and the collector state carries no store/daemon process references
    state = :sys.get_state(Collector)
    refute Map.has_key?(state, :store)
    refute Map.has_key?(state, :daemon)
  end

  # ------------------------------------------------------------ I8 — clocks

  test "I8: end_mono >= start_mono for every closed span" do
    start_collector()

    for i <- 1..30 do
      t = "i8-#{i}"
      emit_start(turn_span(t))
      emit_start(dispatch_span(t, "i8-d#{i}"))
      emit_end("turn:" <> t, closed())
    end

    for {_k, span} <- :ets.tab2list(:l19_spans),
        is_integer(span.end_mono_ms) do
      assert span.end_mono_ms >= span.start_mono_ms
    end
  end

  # ------------------------------------------------------------ dynamics

  test "dynamics: span :pending --span_end--> :closed; collector :empty --span_start--> :serving" do
    start_collector()
    assert Collector.stats().spans == 0

    t = "dyn"
    emit_start(turn_span(t))
    assert Collector.stats().spans == 1

    [span] = live_spans(t)
    assert span.status == :pending

    emit_end("turn:" <> t, closed())
    [closed_span] = live_spans(t)
    assert closed_span.status == :closed
  end

  test "dynamics: span :pending --sweep(age>60s)--> :closed(:truncated)" do
    {:ok, clock} = Agent.start_link(fn -> 120_000 end)

    # the injected clock reads real monotonic minus the offset — at admit the
    # span's start_mono_ms is 120 s in the "past"; the sweep then runs at the
    # real clock, so now - start_mono > @max_trace_age_ms
    clock_fun = fn :millisecond ->
      System.monotonic_time(:millisecond) - Agent.get(clock, & &1)
    end

    start_collector(mono_now: clock_fun)
    emit_start(turn_span("told"))

    # bring the clock back to real time, then sweep — the trace's root is
    # now > @max_trace_age_ms old, so the sweep force-completes it
    Agent.update(clock, fn _offset -> 0 end)
    send(Collector, :sweep)
    sync()

    row = Collector.trace("told")
    assert row.status == :complete
    assert row.open == 0

    [span] = live_spans("told")
    assert span.status == :closed
    assert span.data[:truncated] == true
    assert span.end_mono_ms >= span.start_mono_ms
  end

  test "dynamics: trace :forming --span_start--> :active; :active --span_end(open==0)--> :complete" do
    start_collector()

    # a micro-trace born by the append span (rule 4) is :forming…
    emit_start(append_span("dx"))
    assert Collector.trace("dx").status == :forming

    # …the second span_start flips it :active (the pinned transition)
    emit_start(fan_span("dx"))
    assert Collector.trace("dx").status == :active

    # close everything -> :complete
    emit_end("append:dx", closed())
    emit_end("fan:dx", closed())
    assert Collector.trace("dx").status == :complete
  end

  test "dynamics: re-root — the turn span becomes the root of an append-born trace" do
    start_collector()

    # store appends the received delta first (store process -> collector),
    # the reactor's turn span follows: same trace, but the TURN is the root
    emit_start(append_span("rx"))
    emit_start(turn_span("rx"))
    emit_end("append:rx", closed())
    emit_end("turn:rx", closed())

    row = Collector.trace("rx")
    assert row.root_span_id == "turn:rx"
    assert row.status == :complete
    assert row.span_count == 2
  end

  test "dynamics: re-parent — a micro-trace whose first ref resolves merges into the non-micro trace" do
    start_collector()

    # delta Y is engine-emitted and appended (micro-trace keyed by Y)…
    emit_start(append_span("mydelta"))

    # …then dispatched inside real trace T (dispatch span refs Y) —
    # the attach-time re-parent pass merges the append span into T
    emit_start(turn_span("parent-trace"))
    emit_start(dispatch_span("parent-trace", "mydelta", refs: ["mydelta"]))
    emit_end("append:mydelta", closed())
    emit_end("turn:parent-trace", closed())
    emit_end("dispatch:mydelta", closed())

    # the micro-trace row is gone; the append span lives in T now
    refute Collector.trace("mydelta")
    assert Collector.trace("parent-trace").span_count == 3
    assert Enum.map(live_spans("parent-trace"), & &1.span_id) |> Enum.sort() ==
             ["append:mydelta", "dispatch:mydelta", "turn:parent-trace"]
  end
end
