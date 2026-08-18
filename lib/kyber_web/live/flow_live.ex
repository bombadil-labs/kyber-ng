defmodule KyberWeb.FlowLive do
  @moduledoc """
  T19 view 0 — the delta topology. The store's append point is the funnel at
  top-center; every live `DurableStore` subscriber is a node in the row
  below (capped at `@max_nodes`, the rest collapsed into a "+N more" label
  node — every tab is a subscriber, so an uncapped row is quadratic in
  viewers); one edge per rendered subscriber. A committed delta arriving on
  the pinned `subscribe_seeded/1` feed (F2 — no commit gap) spawns a packet
  that travels each edge, so the fan-out is visible as motion rather than as
  a number.

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

  The refresh tick is the only recovery driver: it re-reads store liveness,
  re-subscribes when the store restarted under the view, and re-asserts the
  banner when it went away. Every store read is guarded (`store_call/1`), so
  a store that dies between the liveness check and the call cannot take the
  socket — and every dashboard tab — down with it, and a re-subscribe that
  fails is never rendered as a healthy topology.

  `DurableStore.subscribers/0` is a blocking call into the process that
  serializes appends, and it sweeps the whole subscriber set for liveness —
  so every open tab calling it every tick would tax the append path in
  proportion to viewers². Liveness (`Process.whereis`) is checked every
  tick because it is free; the subscriber ROW is re-read only every
  `@topology_refresh_ticks` ticks, which is indistinguishable from every
  tick at human timescales.
  """

  use Phoenix.LiveView

  alias Kyber.DurableStore
  alias Kyber.Trace.Collector

  @refresh_ms 1_000
  # the subscriber row is re-read every Nth tick, not every tick — see the
  # moduledoc: the read is a blocking, O(subscribers) call per open tab
  @topology_refresh_ticks 5
  # the packet ring is a bounded window over an unbounded store; the DOM
  # packet count can never exceed @max_packets * length(subscribers)
  @max_packets 30
  # a packet leaves the DOM once its animation has finished (dur + slack)
  @packet_ttl_ms 2_500
  # every open tab is itself a subscriber, so an uncapped row would render
  # packets * viewers circles — quadratic in viewers. The overflow is
  # reported as a "+N more" label node instead.
  @max_nodes 8

  @scene_width 900
  @funnel %{x: 450, y: 90}
  @subscriber_y 300

  @impl true
  def mount(_params, _session, socket) do
    subscribed? =
      if connected?(socket) do
        # the pinned source: the view IS a subscriber node, so it appears in
        # its own topology and receives the live feed
        ack = store_call(fn -> DurableStore.subscribe_seeded(self()) end)
        # ticks even with no store: the tick is what notices one arriving
        Process.send_after(self(), :refresh, @refresh_ms)
        match?({:ok, _reply}, ack)
      else
        false
      end

    socket =
      socket
      |> assign(:banner, banner(store_up?()))
      |> assign(:funnel, @funnel)
      |> assign(:packets, [])
      |> assign(:seq, 0)
      |> assign(:subscribed?, subscribed?)
      |> assign(:tick, 0)
      |> assign_topology(subscriber_row())

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

    socket = sync_store(socket)

    packets =
      socket.assigns.packets
      |> Enum.reject(&(now_ms() - &1.at > @packet_ttl_ms))
      |> Enum.map(&refresh_counts/1)

    # steady state is an unchanged list: re-assigning it would make LiveView
    # re-diff the packets × subscribers block every second for nothing
    socket =
      if packets == socket.assigns.packets,
        do: socket,
        else: assign(socket, :packets, packets)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -------------------------------------------------------------- liveness

  defp store_up?, do: Process.whereis(DurableStore) != nil

  # `subscribers/0` and `subscribe_seeded/1` are blocking calls into the
  # store's append-serialization process: it can die between the liveness
  # check and the call, and an exiting call would take the socket with it.
  # `:down` is the store being gone — distinct from a reply that is itself
  # `nil`, and never confusable with success.
  defp store_call(fun) when is_function(fun, 0) do
    if store_up?() do
      try do
        {:ok, fun.()}
      catch
        :exit, _ -> :down
      end
    else
      :down
    end
  end

  defp read_subscribers do
    store_call(fn -> Enum.reverse(DurableStore.subscribers()) end)
  end

  defp subscriber_row do
    case read_subscribers() do
      {:ok, subscribers} -> subscribers
      :down -> []
    end
  end

  defp banner(store_up?) do
    cond do
      not store_up? ->
        "nothing to show — no store on this BEAM (run `mix kyber.dashboard`)"

      not Collector.live?() ->
        "no span collector on this BEAM — deltas stream, but traces are unavailable"

      true ->
        nil
    end
  end

  # The tick is the recovery driver. A store that went away re-asserts the
  # banner and empties the row; a store that came back — or restarted under
  # the view, so the fresh registered set has never heard of it — is
  # re-subscribed. Losing the store is observed every tick (liveness is
  # free); a store that died and restarted BETWEEN two ticks is caught by
  # the throttled membership check instead.
  defp sync_store(socket) do
    tick = rem(socket.assigns.tick + 1, @topology_refresh_ticks)
    socket = assign(socket, :tick, tick)

    cond do
      not store_up?() ->
        assign_detached(socket)

      not socket.assigns.subscribed? ->
        resubscribe(socket)

      tick != 0 ->
        socket

      true ->
        case read_subscribers() do
          {:ok, subscribers} ->
            if self() in subscribers,
              do: assign_topology(socket, subscribers),
              else: resubscribe(socket)

          :down ->
            assign_detached(socket)
        end
    end
  end

  # The re-subscribe must be ACKED before the view may render as healthy: a
  # store that dies during the call leaves the view permanently off the
  # delta feed, and a healthy-looking topology would hide that forever. The
  # fresh store mints fresh ids, so the ring is cleared with the
  # re-subscribe rather than left holding unreachable deltas.
  defp resubscribe(socket) do
    with {:ok, _reply} <- store_call(fn -> DurableStore.subscribe_seeded(self()) end),
         {:ok, subscribers} <- read_subscribers() do
      socket
      |> assign(:banner, banner(true))
      |> assign(:subscribed?, true)
      |> assign(:packets, [])
      |> assign_topology(subscribers)
    else
      :down -> assign_detached(socket)
    end
  end

  defp assign_detached(socket) do
    socket
    |> assign(:banner, banner(false))
    |> assign(:subscribed?, false)
    |> assign_topology([])
  end

  # ------------------------------------------------------------- topology

  defp assign_topology(socket, pids) do
    {nodes, more} = layout(pids)

    socket |> assign(:subscribers, nodes) |> assign(:more, more)
  end

  # the row is re-spread on every refresh — subscribers join and leave as
  # views connect and disconnect, so no position is ever hardcoded. Only the
  # rendered (capped) nodes carry edges and packets; the overflow is one
  # label node holding the last slot.
  defp layout(pids) do
    shown = Enum.take(pids, @max_nodes)
    hidden = length(pids) - length(shown)
    slots = length(shown) + min(hidden, 1)

    nodes =
      shown
      |> Enum.with_index()
      |> Enum.map(fn {pid, i} ->
        %{
          pid: pid,
          key: :erlang.phash2(pid),
          label: label_for(pid),
          x: spread(i, slots),
          y: @subscriber_y
        }
      end)

    more =
      if hidden > 0 do
        %{label: "+#{hidden} more", x: spread(length(shown), slots), y: @subscriber_y}
      end

    {nodes, more}
  end

  defp spread(i, slots), do: round(@scene_width * (i + 1) / (slots + 1))

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

        <g :if={@more}>
          <circle class="node node-more" cx={@more.x} cy={@more.y} r="18" />
          <text class="node-label muted" x={@more.x} y={@more.y + 36} text-anchor="middle">
            <%= @more.label %>
          </text>
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
