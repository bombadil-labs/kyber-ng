defmodule KyberWeb.TraceLiveTest do
  @moduledoc """
  AC2/AC3 — view 2: the OTel-style trace waterfall (parent-attached spans,
  monotonic durations, statuses) and the click-through resolution in pinned
  order (traces → by_delta → attribution index). Spans are driven through
  the real emitter; collector reads are polled with the receive-timeout
  helper (no `Process.sleep`); live refreshes are driven by direct
  `:refresh` sends to the view.
  """

  use KyberWeb.Case, async: false

  import Kyber.Live.SpanFixtures

  alias Kyber.{DurableStore, Events, Wire}
  alias Kyber.Trace.Collector

  @human_seed String.duplicate("cd", 32)

  defp received_wire(ts, msg_id, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:trace",
        "session:trace",
        content
      )

    Wire.envelope(signed)
  end

  # a complete two-level trace: turn -> dispatch -> llm + tool, all closed
  defp emit_trace(trace_id, request_id, call_id) do
    Kyber.Trace.span_start(turn_span(trace_id))
    Kyber.Trace.span_start(dispatch_span(trace_id, request_id, data: %{delta_kind: "promptRef"}))
    Kyber.Trace.span_start(llm_span(trace_id, request_id, 1))
    Kyber.Trace.span_start(dispatch_span(trace_id, call_id, data: %{delta_kind: "tool"}))
    Kyber.Trace.span_start(tool_span(trace_id, call_id))

    Kyber.Trace.span_end("turn:" <> trace_id, closed())
    Kyber.Trace.span_end("dispatch:" <> request_id, closed(%{handler_result: :emit}))
    Kyber.Trace.span_end(Kyber.Trace.Span.llm_span_id(request_id, 1), closed(%{outcome: :answered}))
    Kyber.Trace.span_end("dispatch:" <> call_id, closed(%{handler_result: :emit}))
    Kyber.Trace.span_end("tool:" <> call_id, closed(%{result_status: "ok"}))
  end

  # ---------------------------------------------------------------- AC2

  test "AC2: a trace renders as an OTel-style waterfall — kinds, durations, statuses" do
    trace_id = "ac2-trace"
    request_id = "ac2-request"
    call_id = "ac2-call"

    emit_trace(trace_id, request_id, call_id)
    poll_until(fn -> Collector.trace(trace_id) != nil end)

    conn = build_conn()
    {:ok, _view, html} = live(conn, "/trace/" <> trace_id)

    # the trace header: status/span-count
    assert html =~ "ac2-trace"
    assert html =~ "complete"
    assert html =~ "5 spans"

    # all five spans render with their kinds (the kind column) and short ids
    assert html =~ ">turn<"
    assert html =~ ">dispatch<"
    assert html =~ ">llm<"
    assert html =~ ">tool_exec<"
    assert html =~ String.slice("tool:ac2-call", 0, 12)
    assert html =~ String.slice("llm:ac2-request#1", 0, 12)
    assert html =~ ">closed<"

    # monotonic durations render (end - start)
    assert html =~ "ms"
  end

  test "AC2: an open span renders as open; the END re-renders it closed with a duration" do
    trace_id = "ac2-open"
    Kyber.Trace.span_start(turn_span(trace_id))
    Kyber.Trace.span_start(dispatch_span(trace_id, "ac2-open-d"))
    poll_until(fn -> Collector.trace(trace_id) != nil end)

    conn = build_conn()
    {:ok, view, html} = live(conn, "/trace/" <> trace_id)
    assert html =~ "open"
    refute html =~ "complete"

    # the END arrives -> the view's refresh re-renders it closed with a
    # monotonic duration
    Kyber.Trace.span_end("turn:" <> trace_id, closed())
    Kyber.Trace.span_end("dispatch:ac2-open-d", closed(%{handler_result: :emit}))
    poll_until(fn -> Collector.trace(trace_id).open == 0 end)

    send(view.pid, :refresh)
    html = render_async(view, 1_000)
    assert html =~ "complete"
    assert html =~ "ms"
    refute html =~ ">open<"
  end

  # ---------------------------------------------------------------- AC3

  test "AC3: clicking a root delta in view 1 opens the full trace in view 2" do
    dir = Path.join(System.tmp_dir!(), "kyber-trace-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({DurableStore, Path.join(dir, "store.jsonl")})

    wire = received_wire(3_000.0, "ac3-root", "click me")
    assert :ok = DurableStore.append(wire)
    id = delta_id(DurableStore.set(), 3_000.0)

    # the reactor would have opened the turn trace for this received delta —
    # drive the same spans through the emitter
    emit_trace(id, id <> "-req", id <> "-call")

    conn = build_conn()
    {:ok, view, html} = live(conn, "/intake")
    assert html =~ String.slice(id, 0, 12)

    # click the row -> push_navigate to view 2 (AC3: traces first — the id
    # IS the trace key, M5); follow_redirect lands on the TraceLive page
    {:ok, _view2, html2} =
      view
      |> element(~s(a.delta[phx-value-id="#{id}"]))
      |> render_click()
      |> follow_redirect(conn)

    # the received delta's trace: the store's append + fan_out spans joined
    # the turn (attach-by-refs, rule 3) — 7 spans total
    assert html2 =~ "complete"
    assert html2 =~ "7 spans"
    assert html2 =~ "store_append"
  end

  test "AC3: a non-root delta resolves via by_delta (the spans that referenced it)" do
    trace_id = "ac3-parent"
    other_delta = "ac3-other-delta"

    Kyber.Trace.span_start(turn_span(trace_id))
    Kyber.Trace.span_start(dispatch_span(trace_id, other_delta, refs: [other_delta]))
    Kyber.Trace.span_end("turn:" <> trace_id, closed())
    Kyber.Trace.span_end("dispatch:" <> other_delta, closed(%{handler_result: :emit}))
    poll_until(fn -> Collector.spans_for_delta(other_delta) != [] end)

    conn = build_conn()
    {:ok, _view, html} = live(conn, "/trace/" <> other_delta)

    # not a trace root — the by_delta fallback renders the referencing spans
    assert html =~ "no trace is rooted"
    assert html =~ "dispatch:" <> other_delta
    assert html =~ "ac3-parent"
  end

  test "AC3: a post-eviction click resolves via the attribution index (which survived eviction)" do
    # attribute a delta to a trace, then flood the ring so the trace evicts
    Kyber.Trace.attribution("ac3-evicted-delta", "ac3-evicted-trace")

    Kyber.Trace.span_start(turn_span("ac3-evicted-trace"))
    Kyber.Trace.span_end("turn:ac3-evicted-trace", closed())

    for i <- 1..300 do
      t = "ac3-flood-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      Kyber.Trace.span_start(turn_span(t))
      Kyber.Trace.span_end("turn:" <> t, closed())
    end

    poll_until(fn -> Collector.trace("ac3-evicted-trace") == nil end)

    # the attribution index outlived the eviction (M3)
    assert Collector.attribution("ac3-evicted-delta") == "ac3-evicted-trace"

    conn = build_conn()
    {:ok, _view, html} = live(conn, "/trace/ac3-evicted-delta")
    assert html =~ "was traced"
    assert html =~ "ac3-evicted-trace"
  end

  test "AC3: an unknown id renders the no-trace banner" do
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/trace/never-seen-delta")
    assert html =~ "no trace found"
  end

  # ---------------------------------------------------------------- helpers

  defp delta_id(set, ts) do
    {id, _element} =
      Enum.find(set, fn {_id, {claims, _sig}} -> claims.timestamp == ts end)

    id
  end
end
