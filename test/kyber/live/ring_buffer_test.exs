defmodule Kyber.Live.RingBufferTest do
  @moduledoc """
  AC4 — the ring buffer under a synthetic 300-trace flood: totals never
  exceed C/T/P, eviction is whole-trace oldest-first (preferring
  `:complete`), and `:l19_by_delta`/`:l19_by_span` stay consistent (I4).
  Sleep-free: casts drained by the `:sync` barrier.
  """

  use ExUnit.Case, async: false

  import Kyber.Live.SpanFixtures

  alias Kyber.Trace.Collector

  setup do
    start_supervised!(Collector)
    :ok
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

  test "AC4: a 300-trace flood never exceeds C/T/P; whole-trace eviction; by_delta consistent" do
    # 300 traces × 15 spans = 4500 spans — over T (256) AND over C (4096);
    # every turn closed, so eviction prefers :complete, oldest root_seq first
    for i <- 1..300 do
      t = "flood-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      emit_start(turn_span(t))
      emit_start(dispatch_span(t, "flood-d#{i}-a"))
      emit_start(dispatch_span(t, "flood-d#{i}-b"))
      emit_start(dispatch_span(t, "flood-d#{i}-c"))
      emit_start(dispatch_span(t, "flood-d#{i}-d"))
      emit_start(dispatch_span(t, "flood-d#{i}-e"))
      emit_start(dispatch_span(t, "flood-d#{i}-f"))
      emit_start(dispatch_span(t, "flood-d#{i}-g"))
      emit_start(dispatch_span(t, "flood-d#{i}-h"))
      emit_start(dispatch_span(t, "flood-d#{i}-i"))
      emit_start(dispatch_span(t, "flood-d#{i}-j"))
      emit_start(dispatch_span(t, "flood-d#{i}-k"))
      emit_start(dispatch_span(t, "flood-d#{i}-l"))
      emit_start(dispatch_span(t, "flood-d#{i}-m"))
      emit_end("turn:" <> t, closed())
    end

    stats = Collector.stats()
    assert stats.traces <= 256, "T exceeded: #{stats.traces}"
    assert stats.spans <= 4096, "C exceeded: #{stats.spans}"

    for t <- Collector.trace_ids() do
      assert length(Collector.spans_for(t)) <= 1024, "P exceeded for #{t}"
    end

    # whole-trace eviction: the oldest :complete victim is FULLY gone —
    # row and spans (I3)
    refute Collector.trace("flood-001")
    assert Collector.spans_for("flood-001") == []

    # and every surviving row is exactly consistent with its span list
    for t <- Collector.trace_ids() do
      row = Collector.trace(t)
      assert length(Collector.spans_for(t)) == row.span_count
    end

    # I4: no dangling click-through — every by_span/by_delta entry points at
    # a live span
    for {_span_id, {tid, seq}} <- :ets.tab2list(:l19_by_span) do
      assert :ets.lookup(:l19_spans, {tid, seq}) != []
    end

    for {_delta, entries} <- :ets.tab2list(:l19_by_delta) do
      for {tid, seq} <- entries do
        assert :ets.lookup(:l19_spans, {tid, seq}) != []
      end
    end
  end

  test "AC4: per-trace cap P — a runaway trace truncates itself, the root survives" do
    t = "runaway"

    emit_start(turn_span(t))

    for i <- 1..1100 do
      emit_start(dispatch_span(t, "run-#{i}"))
    end

    spans = Collector.spans_for(t)
    row = Collector.trace(t)

    assert length(spans) <= 1024
    assert row.truncated == true

    # the root (the turn span) survived the truncation
    assert Enum.any?(spans, &(&1.span_id == "turn:" <> t))

    # global bounds hold
    assert Collector.stats().spans <= 4096
    assert Collector.stats().traces <= 256

    # I4 still holds after truncation
    for {_span_id, {tid, seq}} <- :ets.tab2list(:l19_by_span) do
      assert :ets.lookup(:l19_spans, {tid, seq}) != []
    end
  end
end
