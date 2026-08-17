defmodule Kyber.Trace do
  @moduledoc """
  T19 the span emitter (the pin-1 cast seam): `span_start/1`, `span_end/3`
  cast to the registered `Kyber.Trace.Collector`; a cast to an unregistered
  name is a silent no-op, never a crash (the `notify_reactor/1` precedent —
  I7). Every emitter call is TOTAL (L5): it returns `:ok` whether or not a
  collector lives, and no span payload ever carries a seed, api_key, or raw
  tool args/results (D8 by construction — the call sites build span data
  from pre-validated fields only).

  Message shapes (pinned verbatim):

      {:span_start, %{span_id, kind, trace_id, parent_id, refs, ts, data}}
      {:span_end, span_id, %{status, data}}
      {:trace_attribution, delta_id, turn_id}

  `:llm` span ids are per-attempt (`Kyber.Trace.Span.llm_span_id/2`);
  every other span id is the deterministic prefix + delta id. `refs` are
  the delta ids the activity referenced (click-through + attach-by-refs).
  """

  alias Kyber.Trace.Collector

  @doc """
  Start a span (cast; total — `:ok` with or without a collector). The span
  map's fields come from pre-validated call-site data: `span_id` (binary),
  `kind` (one of `:turn | :dispatch | :llm | :tool_exec | :store_append |
  :fan_out`), optional `trace_id` / `parent_id` / `refs`, `ts` (the
  initiating delta's `claims.timestamp` — never wall clock), and optional
  `data`. The collector mints `start_mono_ms`/`seq` at receipt.
  """
  @spec span_start(map()) :: :ok
  def span_start(%{} = span) do
    cast({:span_start, span})
  rescue
    _ -> :ok
  end

  def span_start(_), do: :ok

  @doc """
  Close a span (cast; total). `payload` is `%{status: atom(), data:
  map()}` — `:closed` (or `:truncated`, for sweep force-closes). END for an
  unknown or already-closed span id is a no-op (I5 — re-fires merge into
  the first span). Fires on error returns too (L5).
  """
  @spec span_end(binary(), map()) :: :ok
  def span_end(span_id, %{} = payload) when is_binary(span_id) do
    cast({:span_end, span_id, payload})
  rescue
    _ -> :ok
  end

  def span_end(_span_id, _payload), do: :ok

  @doc """
  The attribution cast (M3): the reactor's delta → turn feed. These casts
  populate the SEPARATE delta → trace index in the collector that SURVIVES
  span eviction — what makes click-through-after-eviction and `resume/1`
  work (its rows reference trace ids, never span ids). Total.
  """
  @spec attribution(binary(), binary()) :: :ok
  def attribution(delta_id, turn_id) when is_binary(delta_id) and is_binary(turn_id) do
    cast({:trace_attribution, delta_id, turn_id})
  rescue
    _ -> :ok
  end

  def attribution(_delta_id, _turn_id), do: :ok

  # the pin-1 seam: a cast to an unregistered name is dropped, never a
  # crash (the collector is node-wide, registered under its module name)
  defp cast(message) do
    GenServer.cast(Collector, message)
    :ok
  rescue
    _ -> :ok
  end
end
