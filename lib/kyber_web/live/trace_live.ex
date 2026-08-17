defmodule KyberWeb.TraceLive do
  @moduledoc """
  T19 view 2 — the OTel-style span/trace waterfall (AC2/AC3). Per trace id:
  spans parent-attached, durations from monotonic clocks (end_mono_ms −
  start_mono_ms), statuses shown. Click-through resolution (AC3, pinned
  order): `:l19_traces` first (trace_id = the BARE received delta id, so a
  root click IS the trace key, M5) → full trace; else `:l19_by_delta` →
  the spans whose activity referenced the clicked id; else the
  attribution-seeded index (post-eviction — it survives span eviction by
  design, M3); else the "no trace" banner. A periodic self-refresh keeps a
  live trace current as spans arrive/close. Every ETS read is guarded
  (rescue → empty-read, L6).
  """

  use Phoenix.LiveView

  alias Kyber.Trace.Collector

  @refresh_ms 1_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, trace_id: id, view: trace_view(id))}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, trace_id: nil, view: %{mode: :none, delta_id: nil})}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, assign(socket, trace_id: id, view: trace_view(id))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :view, trace_view(socket.assigns.trace_id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ------------------------------------------------------- click-through

  # AC3: traces -> by_delta -> attribution index, in pinned order
  defp trace_view(nil), do: %{mode: :none, delta_id: nil}

  defp trace_view(id) when is_binary(id) do
    cond do
      Collector.trace(id) != nil ->
        %{mode: :trace, trace_id: id, row: Collector.trace(id), spans: Collector.spans_for(id)}

      Collector.spans_for_delta(id) != [] ->
        %{mode: :by_delta, delta_id: id, spans: Collector.spans_for_delta(id)}

      true ->
        case Collector.attribution(id) do
          nil ->
            %{mode: :none, delta_id: id}

          trace_id ->
            case Collector.trace(trace_id) do
              nil -> %{mode: :evicted, delta_id: id, trace_id: trace_id}
              row -> %{mode: :trace, trace_id: trace_id, row: row, spans: Collector.spans_for(trace_id)}
            end
        end
    end
  end

  # ---------------------------------------------------------- waterfall

  # spans -> [{span, depth}], seq order, parent-attached (cycles guarded)
  defp waterfall(spans) do
    sorted = Enum.sort_by(spans, & &1.seq)
    depths = depth_map(sorted)

    Enum.map(sorted, &{&1, Map.get(depths, &1.span_id, 0)})
  end

  defp depth_map(spans) do
    by_id = Map.new(spans, &{&1.span_id, &1})

    Map.new(spans, fn span ->
      {span.span_id, depth(span, by_id, MapSet.new())}
    end)
  end

  defp depth(span, by_id, seen) do
    case span.parent_id && Map.get(by_id, span.parent_id) do
      nil ->
        0

      parent ->
        if MapSet.member?(seen, parent.span_id) do
          0
        else
          1 + depth(parent, by_id, MapSet.put(seen, span.span_id))
        end
    end
  end

  defp duration_ms(span) do
    case span.end_mono_ms do
      nil -> "open"
      ended -> "#{max(ended - span.start_mono_ms, 0)} ms"
    end
  end

  defp status_badge(span) do
    cond do
      span.status == :pending -> %{class: "b-open", label: "open"}
      span.data[:truncated] -> %{class: "b-truncated", label: "truncated"}
      true -> %{class: "b-closed", label: "closed"}
    end
  end

  defp short(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short(_id), do: "?"

  # ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2>trace</h2>
      <%= case @view do %>
        <% %{mode: :trace, trace_id: tid, row: row, spans: spans} -> %>
          <p class="muted">
            trace <b><%= tid %></b> — <%= row.status %> · <%= row.span_count %> spans
            <%= if row.open > 0, do: " · " <> Integer.to_string(row.open) <> " open" %>
            <%= if row.truncated, do: " · truncated" %>
          </p>
          <%= waterfall_table(spans) %>
        <% %{mode: :by_delta, delta_id: did, spans: spans} -> %>
          <p class="muted">
            no trace is rooted at <b><%= did %></b> — the spans whose activity referenced it:
          </p>
          <%= for {tid, group} <- Enum.group_by(spans, & &1.trace_id) do %>
            <h3 class="muted">trace <%= tid %></h3>
            <%= waterfall_table(group) %>
          <% end %>
        <% %{mode: :evicted, delta_id: did, trace_id: tid} -> %>
          <div class="banner">
            delta <%= did %> was traced (trace <%= tid %>) but its spans have been
            evicted from the ring buffer — the attribution index outlived them (M3).
          </div>
        <% %{mode: :none, delta_id: did} -> %>
          <div class="banner">
            no trace found for <%= did %> — nothing on this BEAM referenced it
            (separate-BEAM dashboard, or pre-collector history).
          </div>
      <% end %>
    </div>
    """
  end

  defp waterfall_table(spans) do
    assigns = %{rows: waterfall(spans)}

    ~H"""
    <table>
      <thead>
        <tr>
          <th>span</th>
          <th>kind</th>
          <th>parent</th>
          <th>duration</th>
          <th>status</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{span, depth} <- @rows} id={"span-" <> span.span_id} class="span-row">
          <td style={"padding-left: #{depth * 1.25}rem"}>
            <span class="muted" title={span.span_id}><%= short(span.span_id) %></span>
          </td>
          <td class="kind"><%= span.kind %></td>
          <td class="muted"><%= if span.parent_id, do: short(span.parent_id), else: "–" %></td>
          <td><%= duration_ms(span) %></td>
          <td>
            <% badge = status_badge(span) %>
            <span class={"badge " <> badge.class}><%= badge.label %></span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
