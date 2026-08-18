defmodule KyberWeb.FlowLive do
  @moduledoc """
  T19 view 0 — the delta topology. The store's append point is the funnel at
  top-center; every live `DurableStore` subscriber is a node in the row
  below; one edge per subscriber. A committed delta arriving on the pinned
  `subscribe_seeded/1` feed (F2 — no commit gap) spawns a packet that travels
  each edge, so the fan-out is visible as motion rather than as a number.

  The view is itself a subscriber, so it always renders at least its own
  node. Node labels are honest: a registered pid is labelled by the last
  segment of its registered name (`Kyber.Daemon` → "daemon"), an anonymous
  pid is "viewer" — the dashboard views and the index server are all
  anonymous and are NOT guessed apart.

  Known limit (L4): the `:fan_out` span carries COUNTS only, never subscriber
  identities, so the view cannot attribute a packet to a specific pid. A
  packet is therefore rendered down EVERY live edge and the authoritative
  delivered/pruned counts are surfaced as text in the recent table. The two
  disagree only for a subscriber that attached after the delta committed.

  Separate-BEAM / store-down states render the same explicit banner as
  view 1 (M4/L6). Animation is CSS (offset-path + keyframes) inside the SVG —
  no JS, no npm.
  """

  use Phoenix.LiveView

  alias Kyber.DurableStore
  alias Kyber.Trace.Collector

  @refresh_ms 1_000
  # the packet ring is a bounded window over an unbounded store; the DOM
  # packet count can never exceed @max_packets * length(subscribers)
  @max_packets 30
  # a packet leaves the DOM once its animation has finished (dur + slack)
  @packet_ttl_ms 2_500

  @scene_width 900
  @funnel %{x: 450, y: 90}
  @subscriber_y 300

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

    if store_up? and connected?(socket) do
      # the pinned source: the view IS a subscriber node, so it appears in
      # its own topology and receives the live feed
      {:ok, _seeded} = DurableStore.subscribe_seeded(self())
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    socket =
      socket
      |> assign(:banner, banner)
      |> assign(:funnel, @funnel)
      |> assign(:packets, [])
      |> assign(:seq, 0)
      |> assign(:subscribers, layout(read_subscribers()))

    {:ok, socket}
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/trace/" <> id)}
  end

  @impl true
  def handle_info({:delta, id, claims}, socket) do
    seq = socket.assigns.seq + 1

    packet = %{
      id: id,
      seq: seq,
      kind: kind(claims),
      ts: claims.timestamp,
      at: now_ms(),
      delivered: nil,
      pruned: nil
    }

    # oldest-first ring, capped at @max_packets (the same append-and-take
    # shape view 1 uses for its waterfall rows)
    packets = Enum.take(socket.assigns.packets ++ [packet], -@max_packets)

    {:noreply, socket |> assign(:packets, packets) |> assign(:seq, seq)}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    packets =
      socket.assigns.packets
      |> Enum.reject(&(now_ms() - &1.at > @packet_ttl_ms))
      |> Enum.map(&refresh_counts/1)

    socket =
      socket
      |> assign(:packets, packets)
      |> assign(:subscribers, layout(read_subscribers()))

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ------------------------------------------------------------- topology

  defp read_subscribers do
    if Process.whereis(DurableStore), do: Enum.reverse(DurableStore.subscribers()), else: []
  end

  # the row is re-spread on every refresh — subscribers join and leave as
  # views connect and disconnect, so no position is ever hardcoded
  defp layout(pids) do
    n = length(pids)

    pids
    |> Enum.with_index()
    |> Enum.map(fn {pid, i} ->
      %{
        pid: pid,
        key: :erlang.phash2(pid),
        label: label_for(pid),
        x: round(@scene_width * (i + 1) / (n + 1)),
        y: @subscriber_y
      }
    end)
  end

  defp label_for(pid) do
    if pid == Process.whereis(Kyber.Daemon) do
      "daemon"
    else
      case Process.info(pid, :registered_name) do
        {:registered_name, name} when is_atom(name) -> short_name(name)
        _ -> "viewer"
      end
    end
  end

  defp short_name(name) do
    case Atom.to_string(name) do
      "Elixir." <> module -> module |> String.split(".") |> List.last() |> String.downcase()
      other -> other
    end
  end

  # ------------------------------------------------------------- packets

  defp refresh_counts(packet) do
    counts = Collector.fan_out_counts(packet.id)
    %{packet | delivered: counts.delivered, pruned: counts.pruned}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: "?"

  @packet_fills ~w(received sent checkpoint seed agent)

  defp fill_class(kind) when kind in @packet_fills, do: "p-" <> kind
  defp fill_class(_kind), do: "p-default"

  defp short(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short(_id), do: "?"

  # -------------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @banner do %>
        <div class="banner"><%= @banner %></div>
      <% end %>
      <h2>delta flow</h2>
      <p class="muted">
        funnel = store append · packets = committed deltas · click a packet for its trace
      </p>

      <svg class="flow" viewBox="0 0 900 420" role="img">
        <line
          :for={s <- @subscribers}
          class="edge"
          x1={@funnel.x}
          y1={@funnel.y}
          x2={s.x}
          y2={s.y}
        />

        <polygon class="funnel" points="380,34 520,34 468,90 432,90" />
        <text class="node-label" x={@funnel.x} y="26" text-anchor="middle">store</text>

        <g :for={s <- @subscribers}>
          <circle class="node" cx={s.x} cy={s.y} r="18" />
          <text class="node-label" x={s.x} y={s.y + 36} text-anchor="middle"><%= s.label %></text>
        </g>

        <%= for p <- @packets, s <- @subscribers do %>
          <circle
            id={"packet-#{p.seq}-#{s.key}"}
            class={"packet " <> fill_class(p.kind)}
            cx="0"
            cy="0"
            r="5"
            phx-click="open"
            phx-value-id={p.id}
            style={"offset-path: path('M#{@funnel.x},#{@funnel.y} L#{s.x},#{s.y}')"}
          >
          </circle>
        <% end %>
      </svg>

      <table>
        <thead>
          <tr>
            <th>delta</th>
            <th>kind</th>
            <th>ts</th>
            <th>delivered</th>
            <th>pruned</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- Enum.reverse(@packets)} id={"flow-row-#{p.seq}"}>
            <td>
              <a class="delta" href={"/trace/" <> p.id} phx-click="open" phx-value-id={p.id}>
                <%= short(p.id) %>
              </a>
            </td>
            <td class="kind"><%= p.kind %></td>
            <td class="muted"><%= trunc(p.ts) %></td>
            <td><%= p.delivered || "–" %></td>
            <td><%= p.pruned || "–" %></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
