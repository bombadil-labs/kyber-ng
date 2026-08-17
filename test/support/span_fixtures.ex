defmodule Kyber.Live.SpanFixtures do
  @moduledoc """
  Span-map fixtures for the T19 collector/live tests — the pinned emitter
  message shape `%{span_id, kind, trace_id, parent_id, refs, ts, data}`.
  """

  @doc "The turn (root) span of a trace."
  def turn_span(trace_id, opts \\ []) do
    base = %{
      span_id: "turn:" <> trace_id,
      kind: :turn,
      trace_id: trace_id,
      parent_id: nil,
      refs: [trace_id],
      ts: 1_000.0,
      data: %{gate: :open, budget_cap: 32}
    }

    Map.merge(base, Map.new(opts))
  end

  @doc "A dispatch span inside a trace."
  def dispatch_span(trace_id, delta_id, opts \\ []) do
    base = %{
      span_id: "dispatch:" <> delta_id,
      kind: :dispatch,
      trace_id: trace_id,
      parent_id: "turn:" <> trace_id,
      refs: [delta_id],
      ts: 1_000.1,
      data: %{delta_kind: "received"}
    }

    Map.merge(base, Map.new(opts))
  end

  @doc "An llm span (per-attempt id) inside a trace."
  def llm_span(trace_id, request_id, attempt \\ 1, opts \\ []) do
    base = %{
      span_id: Kyber.Trace.Span.llm_span_id(request_id, attempt),
      kind: :llm,
      trace_id: trace_id,
      parent_id: "dispatch:" <> request_id,
      refs: [request_id],
      ts: 1_000.2,
      data: %{model: "deepseek-v4-flash"}
    }

    Map.merge(base, Map.new(opts))
  end

  @doc "A tool_exec span inside a trace."
  def tool_span(trace_id, call_id, opts \\ []) do
    base = %{
      span_id: "tool:" <> call_id,
      kind: :tool_exec,
      trace_id: trace_id,
      parent_id: "dispatch:" <> call_id,
      refs: [call_id],
      ts: 1_000.3,
      data: %{tool_id: "tool:echo"}
    }

    Map.merge(base, Map.new(opts))
  end

  @doc "A store_append span (unattributed — attaches via refs/rule 4)."
  def append_span(delta_id, opts \\ []) do
    base = %{
      span_id: "append:" <> delta_id,
      kind: :store_append,
      trace_id: nil,
      parent_id: nil,
      refs: [delta_id],
      ts: 1_000.4,
      data: %{delta_id: delta_id, outcome: :committed}
    }

    Map.merge(base, Map.new(opts))
  end

  @doc "A fan_out span (unattributed — attaches via refs/rule 4)."
  def fan_span(delta_id, opts \\ []) do
    base = %{
      span_id: "fan:" <> delta_id,
      kind: :fan_out,
      trace_id: nil,
      parent_id: nil,
      refs: [delta_id],
      ts: 1_000.5,
      data: %{delta_id: delta_id, delivered: 1, pruned: 0}
    }

    Map.merge(base, Map.new(opts))
  end

  def closed(payload \\ %{outcome: :answered}), do: %{status: :closed, data: payload}
end
