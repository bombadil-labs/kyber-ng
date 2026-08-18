defmodule KyberWeb.IntakeLive do
  @moduledoc """
  T19 view 1 at `/intake` — the delta intake waterfall (AC1). Source: the pinned
  `DurableStore.subscribe_seeded/1` seam (F2 — no commit gap): every
  committed delta lands in the LiveView `stream/4` in commit order. Each
  row shows the delta id (clickable — AC3 click-through to view 2), its
  kind, the fan-out counts (delivered/pruned — the `:fan_out` span carries
  COUNTS only, L4), and a traced/untraced/duplicate badge (duplicate
  re-appends surface via the `:store_append` span's `:duplicate` outcome —
  they are never fanned out again). A periodic self-refresh re-checks the
  badges against the collector as spans arrive (duplicates and fan counts
  are span data, not feed messages).

  Separate-BEAM / store-down states render the explicit "nothing to show"
  banner (M4/L6). Every ETS read is guarded (rescue → empty-read).
  """

  use Phoenix.LiveView

  alias Kyber.DurableStore
  alias Kyber.Trace.Collector

  @refresh_ms 1_000
  # the DOM waterfall is a bounded window over the store (the store is
  # unbounded; the page is not)
  @max_rows 2_000

  @impl true
  def mount(_params, _session, socket) do
    store_up? = Process.whereis(DurableStore) != nil

    banner =
      cond do
        not store_up? ->
          "nothing to show — no store on this BEAM (run `mix kyber.dashboard`)"

        not Collector.live?() ->
          "no span collector on this BEAM — deltas stream, but traces are unavailable"

        true ->
          nil
      end

    socket = assign(socket, :banner, banner)

    set =
      cond do
        not store_up? ->
          %{}

        connected?(socket) ->
          # the pinned source: seed + subscribe in ONE serialized store call
          {:ok, seeded} = DurableStore.subscribe_seeded(self())
          seeded

        true ->
          DurableStore.set()
      end

    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    rows = seed_rows(set)
    socket = assign(socket, :rows, rows)
    {:ok, stream(socket, :deltas, rows)}
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    # AC3 click-through: any delta opens view 2 (root → full trace; else
    # by_delta; else the attribution index — resolved inside TraceLive)
    {:noreply, push_navigate(socket, to: "/trace/" <> id)}
  end

  @impl true
  def handle_info({:delta, id, claims}, socket) do
    row = delta_row(id, claims)

    # append-only rows list in commit order (the waterfall never reorders);
    # capped so the page stays bounded even on an unbounded store
    rows = Enum.take(socket.assigns.rows ++ [row], -@max_rows)

    socket =
      stream_insert(socket, :deltas, row)
      |> assign(:rows, rows)

    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, refresh_badges(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------ rows

  defp seed_rows(set) do
    set
    |> Enum.sort_by(fn {id, {claims, _sig}} -> {claims.timestamp, id} end)
    |> Enum.map(fn {id, {claims, _sig}} -> delta_row(id, claims) end)
    |> Enum.take(-@max_rows)
  end

  defp delta_row(id, claims) do
    counts = Collector.fan_out_counts(id)

    %{
      id: id,
      kind: kind(claims),
      ts: claims.timestamp,
      traced: Collector.traced?(id),
      duplicate: Collector.duplicate?(id),
      delivered: counts.delivered,
      pruned: counts.pruned
    }
  end

  # badges are span data: the periodic refresh re-reads the collector so a
  # duplicate re-append, a fan-out, or a first dispatch surfaces on the
  # already-streamed row without re-streaming it. The rows list is a PLAIN
  # LIST in commit order (a LiveStream can only be consumed by a for
  # comprehension — it is never enumerable in handle_info); re-inserting
  # every row in list order is order-idempotent (the stream re-rotation
  # nets back to commit order).
  defp refresh_badges(socket) do
    Enum.reduce(socket.assigns.rows, socket, fn item, acc ->
      stream_insert(acc, :deltas, refresh_row(item))
    end)
  end

  defp refresh_row(item) do
    counts = Collector.fan_out_counts(item.id)

    %{
      item
      | traced: Collector.traced?(item.id),
        duplicate: Collector.duplicate?(item.id),
        delivered: counts.delivered,
        pruned: counts.pruned
    }
  end

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: "?"

  defp short(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short(_id), do: "?"

  # ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @banner do %>
        <div class="banner"><%= @banner %></div>
      <% end %>
      <h2>delta intake</h2>
      <table>
        <thead>
          <tr>
            <th>delta</th>
            <th>kind</th>
            <th>ts</th>
            <th>delivered</th>
            <th>pruned</th>
            <th>state</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{sid, d} <- @streams.deltas} id={sid}>
            <td>
              <a class="delta" href={"/trace/" <> d.id} phx-click="open" phx-value-id={d.id}>
                <%= short(d.id) %>
              </a>
            </td>
            <td><%= d.kind %></td>
            <td class="muted"><%= trunc(d.ts) %></td>
            <td><%= d.delivered || "–" %></td>
            <td><%= d.pruned || "–" %></td>
            <td>
              <%= if d.duplicate do %><span class="badge b-dup">duplicate</span><% end %>
              <%= if d.traced do %>
                <span class="badge b-traced">traced</span>
              <% else %>
                <span class="badge b-untraced">untraced</span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
