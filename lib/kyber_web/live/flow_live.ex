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
  node — its own pid is pinned to the front of the capped row, since the
  cap would otherwise drop a view that attached after `@max_nodes` others.
  Node labels are honest: a registered pid is labelled by the last
  segment of its registered name (`Kyber.Daemon` → "daemon"), an anonymous
  pid is "viewer" — the dashboard views and the index server are all
  anonymous and are NOT guessed apart.

  Known limit (L4): the `:fan_out` span carries COUNTS only, never subscriber
  identities, so the view cannot attribute a packet to a specific pid. A
  packet is therefore rendered down EVERY live edge and the authoritative
  delivered/pruned counts are surfaced as text in the recent table. The two
  disagree only for a subscriber that attached after the delta committed.
  The table reads the `@history_max` ring, not the packets: animation ends
  at `@packet_ttl_ms`, but the record of what committed persists.

  Separate-BEAM / store-down states render the same explicit banner as
  view 1 (M4/L6). Animation is CSS (offset-path + keyframes) inside the SVG —
  no JS, no npm.

  The refresh tick is the only recovery driver: it re-reads store liveness,
  re-subscribes when the store restarted under the view, and re-asserts the
  banner when it went away. Recovery is throttled to the same
  `@topology_refresh_ticks` cadence as the membership read, because it is
  made of the same blocking store calls — a detached tab retrying every
  tick is the call storm the throttle exists to prevent. Every store read is
  guarded (`store_call/1`), so a store that dies between the liveness check
  and the call cannot take the socket — and every dashboard tab — down with
  it, and a subscribe that fails is never rendered as a healthy topology:
  not at mount either, where the store being registered would otherwise
  leave an unacked view with no banner and no nodes. `store_call/1` separates a
  call that TIMED OUT (`:slow` — the store is alive but behind a queue of
  appends, so the tick keeps the last-known topology and re-reads next tick)
  from one that exited for any other reason (`:down` — only that detaches);
  consecutive `:slow` ticks are reported as a hint, since a store stuck
  behind its append queue otherwise renders as a healthy idle one. The
  re-subscribe ack carries the store's current set, so the recent table is
  rebuilt from that snapshot rather than emptied — a restarted store still
  holds every delta it replayed from its log. Mount seeds the table from the
  same ack, so a freshly opened tab and a recovered one report the same
  store rather than two different truths about it.

  `DurableStore.subscribers/0` is a blocking call into the process that
  serializes appends, and it sweeps the whole subscriber set for liveness —
  so every open tab calling it every tick would tax the append path in
  proportion to viewers². Liveness (`Process.whereis`) is checked every
  tick because it is free; the subscriber ROW is re-read only every
  `@topology_refresh_ticks` ticks, which is indistinguishable from every
  tick at human timescales. A view also unsubscribes in `terminate/2`, so a
  closed tab leaves the set at once rather than lingering until the next
  delta's fan-out prune; a hard-killed view cannot run terminate and is
  left to that prune.
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
  # the table is the page's record of what committed, so it outlives the
  # animation: history is bounded by rows, not by the packet TTL
  @history_max 50
  # every open tab is itself a subscriber, so an uncapped row would render
  # packets * viewers circles — quadratic in viewers. The overflow is
  # reported as a "+N more" label node instead.
  @max_nodes 8
  # consecutive timed-out topology reads before the view reports the store
  # as slow rather than rendering a stale topology in silence
  @slow_hint_ticks 3
  @slow_hint "store is slow — queued behind appends (topology is from the last healthy tick)"
  # a subscribe can fail while the store is REGISTERED (a call that timed
  # out behind the append queue): the view is not on the delta feed, and a
  # node-less topology under no banner reads as a healthy empty store
  @connecting "connecting to the store — not on the delta feed yet (the refresh tick retries)"

  @scene_width 900
  @funnel %{x: 450, y: 90}
  @subscriber_y 300

  @doc false
  # the recovery/membership throttle, read by the test so it can drive
  # exactly as many ticks as a recovery needs without pinning the interval
  def refresh_ticks, do: @topology_refresh_ticks

  @impl true
  def mount(_params, _session, socket) do
    {subscribed?, banner, history} =
      if connected?(socket) do
        # the pinned source: the view IS a subscriber node, so it appears in
        # its own topology and receives the live feed. The ack carries the
        # store's current set, and the table is rebuilt from it exactly as a
        # re-subscribe rebuilds it — a freshly opened tab reads the store it
        # is attached to, not an empty page that a later recovery would fill.
        {ack, history} =
          case store_call(fn -> DurableStore.subscribe_seeded(self()) end) do
            {:ok, {:ok, set}} -> {{:ok, set}, seed_history(set)}
            other -> {other, []}
          end

        # ticks even with no store: the tick is what notices one arriving
        Process.send_after(self(), :refresh, @refresh_ms)
        acked? = match?({:ok, {:ok, _set}}, ack)
        {acked?, mount_banner(acked?), history}
      else
        {false, banner(store_up?()), []}
      end

    socket =
      socket
      |> assign(:banner, banner)
      |> assign(:funnel, @funnel)
      |> assign(:packets, [])
      |> assign(:history, history)
      |> assign(:seq, length(history))
      |> assign(:subscribed?, subscribed?)
      |> assign(:tick, 0)
      |> assign(:slow_ticks, 0)
      |> assign(:slow_hint, nil)
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
    history = Enum.take(socket.assigns.history ++ [Map.delete(packet, :at)], -@history_max)

    {:noreply,
     socket
     |> assign(:packets, packets)
     |> assign(:history, history)
     |> assign(:seq, seq)}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    socket = sync_store(socket)

    packets =
      socket.assigns.packets
      |> Enum.reject(&(now_ms() - &1.at > @packet_ttl_ms))
      |> Enum.map(&refresh_counts/1)

    history = Enum.map(socket.assigns.history, &refresh_counts/1)

    socket =
      socket
      |> assign_changed(:packets, packets)
      |> assign_changed(:history, history)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A closed tab leaves the subscriber set here rather than lingering as a
  # corpse until some later delta's fan-out prunes it. The call is guarded
  # like every other: `unsubscribe/1` into a missing store EXITS, and the
  # result is nothing terminate could act on anyway.
  @impl true
  def terminate(_reason, _socket) do
    store_call(fn -> DurableStore.unsubscribe(self()) end)
    :ok
  end

  # -------------------------------------------------------------- liveness

  defp store_up?, do: Process.whereis(DurableStore) != nil

  # `subscribers/0` and `subscribe_seeded/1` are blocking calls into the
  # store's append-serialization process: it can die between the liveness
  # check and the call, and an exiting call would take the socket with it.
  # `:down` is the store being gone — distinct from a reply that is itself
  # `nil`, and never confusable with success. A call that TIMES OUT is
  # `:slow`: a store busy behind a queue of appends is alive, so the caller
  # must skip this tick rather than declare it dead.
  defp store_call(fun) when is_function(fun, 0) do
    if store_up?() do
      try do
        {:ok, fun.()}
      catch
        :exit, {:timeout, _call} -> :slow
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
      _down_or_slow -> []
    end
  end

  # an unacked mount is NOT a healthy one: the store being registered makes
  # `banner/1` return nil, so without this the page renders with no banner
  # and no nodes — a blank that reads as an idle store. Not being on the
  # delta feed outranks the collector's own (transient, trace-only) notice.
  defp mount_banner(acked?) do
    cond do
      not store_up?() -> banner(false)
      not acked? -> @connecting
      true -> banner(true)
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
  # free); every path that BLOCKS on the store, recovery included, waits
  # for the throttle: a detached tab retrying its two calls every second is
  # the same load on the append path that the membership throttle exists to
  # prevent, and it lands hardest on the slow store that caused the detach.
  # A store that died and restarted between two ticks is caught by the same
  # membership check.
  defp sync_store(socket) do
    tick = rem(socket.assigns.tick + 1, @topology_refresh_ticks)
    socket = assign(socket, :tick, tick)

    cond do
      not store_up?() -> assign_detached(socket)
      tick != 0 -> socket
      true -> check_membership(socket)
    end
  end

  defp check_membership(socket) do
    case read_subscribers() do
      {:ok, subscribers} ->
        # the banner is re-read on the healthy path too: the collector can die
        # while the view stays attached to a fine store, and its notice would
        # otherwise never appear (a healthy read returns nil, so this is a
        # no-op whenever nothing changed)
        socket = socket |> clear_slow() |> assign(:banner, banner(true))

        # a pid that is in the set but whose subscribe was never ACKED is
        # already on the feed — the call ran, only the reply was lost — but
        # its history was never seeded, so it re-subscribes ONCE to rebuild
        # (the call is idempotent) rather than once per tick forever
        if self() in subscribers and socket.assigns.subscribed?,
          do: assign_topology(socket, subscribers),
          else: resubscribe(socket)

      # a busy store is still the store: keep the last-known topology and
      # re-read on the next tick rather than retrying inside this one
      :slow ->
        note_slow(socket)

      :down ->
        assign_detached(socket)
    end
  end

  # The re-subscribe must be ACKED before the view may render as healthy: a
  # store that dies during the call leaves the view permanently off the
  # delta feed, and a healthy-looking topology would hide that forever. The
  # ack carries the store's current set, so the table is REBUILT from it:
  # a restarted store still holds every delta it replayed from its log, and
  # the packets the view saw before the outage are no evidence of what the
  # store now has. Only the packets ring is cleared — those were mid-flight
  # when the store died, and the animation is a fresh world after a restart.
  defp resubscribe(socket) do
    with {:ok, {:ok, set}} <- store_call(fn -> DurableStore.subscribe_seeded(self()) end),
         {:ok, subscribers} <- read_subscribers() do
      history = seed_history(set)

      socket
      |> assign(:banner, banner(true))
      |> assign(:subscribed?, true)
      |> assign(:packets, [])
      |> assign(:history, history)
      |> assign(:seq, length(history))
      |> clear_slow()
      |> assign_topology(subscribers)
    else
      :slow -> note_slow(socket)
      :down -> assign_detached(socket)
      # the guarantee that a failing subscribe can never take the socket down
      # is structural, not a coincidence of the reply shapes known today: an
      # unknown-but-successful reply leaves the view as it was, and the next
      # tick re-evaluates it
      _other -> socket
    end
  end

  # `seq` is a per-socket render key, not a store property, so the snapshot
  # carries none: the rebuilt rows are numbered 1..N oldest-first (the ring
  # is oldest-first, and the table renders it reversed) and the socket's seq
  # continues from N, so live packets never reuse a rebuilt row's number.
  defp seed_history(set) do
    set
    |> Enum.sort_by(fn {id, {claims, _sig}} -> {claims.timestamp, id} end)
    |> Enum.take(-@history_max)
    |> Enum.with_index(1)
    |> Enum.map(fn {{id, {claims, _sig}}, seq} ->
      %{id: id, seq: seq, kind: kind(claims), ts: claims.timestamp, delivered: nil, pruned: nil}
    end)
  end

  defp assign_detached(socket) do
    socket
    |> assign(:banner, banner(false))
    |> assign(:subscribed?, false)
    |> clear_slow()
    |> assign_topology([])
  end

  # A `:slow` tick is invisible by design — the view keeps its last-known
  # topology — so a store permanently behind its append queue renders
  # exactly like a healthy idle one. Consecutive slow ticks are a queue
  # rather than a blip, and the view says so instead of looking calm.
  defp note_slow(socket) do
    ticks = socket.assigns.slow_ticks + 1

    socket
    |> assign(:slow_ticks, ticks)
    |> assign(:slow_hint, if(ticks >= @slow_hint_ticks, do: @slow_hint))
  end

  defp clear_slow(socket) do
    socket |> assign(:slow_ticks, 0) |> assign(:slow_hint, nil)
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
    shown = pids |> self_first() |> Enum.take(@max_nodes)
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

  # the view is its own subscriber, and the row is capped: without this a
  # view that attached after @max_nodes others would be cut from its own
  # topology. The displaced node is counted in "+N more" like any other.
  defp self_first(pids) do
    if self() in pids, do: [self() | List.delete(pids, self())], else: pids
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

  # steady state is an unchanged list: re-assigning it would make LiveView
  # re-diff the packets × subscribers block every second for nothing
  defp assign_changed(socket, key, value) do
    if value == socket.assigns[key], do: socket, else: assign(socket, key, value)
  end

  # the fan-out span is written once, so a filled entry is terminal — only
  # the still-nil ones are worth re-reading (history holds @history_max)
  defp refresh_counts(%{delivered: nil} = entry) do
    counts = Collector.fan_out_counts(entry.id)
    %{entry | delivered: counts.delivered, pruned: counts.pruned}
  end

  defp refresh_counts(entry), do: entry

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
      <div :if={@slow_hint} class="muted"><%= @slow_hint %></div>
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
          <tr :for={p <- Enum.reverse(@history)} id={"flow-row-#{p.seq}"}>
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
