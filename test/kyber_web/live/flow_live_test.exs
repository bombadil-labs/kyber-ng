defmodule KyberWeb.FlowLiveTest do
  @moduledoc """
  T19 view 0 — FLOW-1..8 (`.adlc/specs/T19.md`, "view 0 (FlowLive)"). The
  funnel is the store's append point,
  each live `DurableStore` subscriber is a node, each committed delta is a
  packet travelling the edges. Sleep-free: `DurableStore.append/1` is a
  serialized call whose fan-out `send` lands in the view's mailbox before
  the call returns, so a following `send(view.pid, :refresh)` and
  `render/1` are strictly ordered; only the collector's span cast is
  polled.
  """

  use KyberWeb.Case, async: false

  alias Kyber.{DurableStore, Events, Wire}
  alias Kyber.Trace.Collector
  alias KyberWeb.FlowLive

  @human_seed String.duplicate("cd", 32)

  # returns the log path, so a test can restart the store on the SAME log
  defp start_store!(path \\ fresh_log_path()) do
    start_supervised!({DurableStore, path})
    path
  end

  defp fresh_log_path do
    # `System.unique_integer/1` restarts from small values in every BEAM, so
    # a bare unique-integer path collides with a PREVIOUS run's leftover tmp
    # dir and the store replays that stale log into this test's set. The
    # os_time prefix makes the path unique across runs, not just within one.
    dir =
      Path.join(
        System.tmp_dir!(),
        "kyber-flow-#{System.os_time()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Path.join(dir, "store.jsonl")
  end

  defp received_wire(ts, msg_id, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:flow",
        "session:flow",
        content
      )

    Wire.envelope(signed)
  end

  # the content-derived id of the delta with this timestamp (the test cannot
  # know the hash a priori — it derives it from the store)
  defp delta_id(ts) do
    {id, _element} =
      Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} -> claims.timestamp == ts end)

    id
  end

  # a subscriber parked in a receive (never Process.sleep); killed on exit
  defp probe! do
    pid = park()
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # parks on a message that is never sent, so the delta feed accumulates in
  # the mailbox instead of matching and letting the probe exit
  defp park, do: spawn(fn -> receive do: (:__never_sent__ -> :ok) end)

  # the view blocks its store calls behind a throttle, so a recovery needs a
  # whole throttle window of ticks — any `refresh_ticks()` consecutive ticks
  # cross the counter's zero exactly once, whatever it started at (and a
  # real 1s timer tick landing in the middle cannot break that)
  defp tick_through_throttle(view) do
    for _n <- 1..FlowLive.refresh_ticks(), do: send(view.pid, :refresh)
  end

  # the RAW registered set — `DurableStore.subscribers/0` prunes dead pids
  # from its reply, so it cannot tell an unsubscribe from a corpse
  defp registered_subscribers, do: :sys.get_state(DurableStore).subscribers

  defp packet_ids(html) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find("circle.packet")
    |> Floki.attribute("phx-value-id")
  end

  defp node_labels(html) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find("svg.flow text.node-label")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  test "FLOW-1: the funnel and one node per live subscriber render" do
    start_store!()

    # an anonymous subscriber (labelled honestly as a viewer) and one
    # registered as the daemon
    anon = probe!()
    assert :ok = DurableStore.subscribe(anon)

    daemon = probe!()
    Process.register(daemon, Kyber.Daemon)
    # only the registration THIS test made is undone — an unconditional
    # unregister would clobber whoever else holds the global name
    on_exit(fn ->
      if Process.whereis(Kyber.Daemon) == daemon, do: Process.unregister(Kyber.Daemon)
    end)
    assert :ok = DurableStore.subscribe(daemon)

    conn = build_conn()
    {:ok, _view, html} = live(conn, "/")

    labels = node_labels(html)

    # the funnel node — the store's append point
    assert "store" in labels
    assert html =~ "polygon"

    # a node per subscriber: the two probes plus the view itself (the view
    # subscribes in mount, so it is part of its own topology)
    assert "daemon" in labels
    assert Enum.count(labels, &(&1 == "viewer")) == 2

    {:ok, doc} = Floki.parse_document(html)
    assert length(Floki.find(doc, "svg.flow circle.node")) == 3
    # one edge from the funnel to each subscriber node
    assert length(Floki.find(doc, "svg.flow line.edge")) == 3
  end

  test "FLOW-2: a committed delta spawns a kind-coloured packet that opens its trace" do
    start_store!()

    conn = build_conn()
    # the view is the ONLY subscriber, so the delta spawns exactly one packet
    {:ok, view, _html} = live(conn, "/")

    assert :ok = DurableStore.append(received_wire(4_000.0, "ac2-packet", "in flight"))
    id = delta_id(4_000.0)

    html = render(view)
    assert packet_ids(html) == [id]

    {:ok, doc} = Floki.parse_document(html)
    packet = doc |> Floki.find("circle.packet") |> List.first()
    # kind = the first pointer role; "received" gets the blue fill class
    assert Floki.attribute([packet], "class") == ["packet p-received"]

    # the packet animates down the edge with CSS, no JS: the shared
    # `packet-flow` keyframes drive `offset-distance`, and the per-edge
    # geometry rides inline because every subscriber has its own x. The
    # view is the only subscriber here, so its node sits at x=450.
    assert Floki.attribute([packet], "style") == [
             "offset-path: path('M450,90 L450,300')"
           ]

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element(~s(circle.packet[phx-value-id="#{id}"]))
      |> render_click()

    assert to == "/trace/" <> id
  end

  test "FLOW-3: the fan-out delivered/pruned counts surface on refresh" do
    start_store!()

    probe = probe!()
    assert :ok = DurableStore.subscribe(probe)

    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    assert :ok = DurableStore.append(received_wire(4_100.0, "ac3-counts", "counted"))
    id = delta_id(4_100.0)

    # the probe and the view both received it; the store's fan_out span cast
    # lands in the collector (polled — no sleep)
    poll_until(fn -> Collector.fan_out_counts(id) == %{delivered: 2, pruned: 0} end)

    send(view.pid, :refresh)
    html = render(view)

    {:ok, doc} = Floki.parse_document(html)
    cells = doc |> Floki.find("tbody tr td") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert Enum.at(cells, 0) == String.slice(id, 0, 12)
    assert Enum.at(cells, 1) == "received"
    assert Enum.at(cells, 3) == "2"
    assert Enum.at(cells, 4) == "0"

    # the packet is drawn down BOTH edges (L4: the span carries counts only,
    # never subscriber identities — the view cannot attribute an edge)
    assert packet_ids(html) == [id, id]
  end

  test "FLOW-4: the packet ring is bounded" do
    start_store!()

    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    for n <- 1..40 do
      assert :ok = DurableStore.append(received_wire(4_200.0 + n, "ac4-#{n}", "flood #{n}"))
    end

    send(view.pid, :refresh)
    html = render(view)

    {:ok, doc} = Floki.parse_document(html)
    subscribers = length(Floki.find(doc, "svg.flow circle.node"))
    packets = length(Floki.find(doc, "circle.packet"))

    assert subscribers >= 1
    # 40 deltas committed, at most @max_packets (30) in the ring. The bound
    # is what the ring guarantees — equality would ride the 2.5s packet TTL
    # (a slow tick between the last append and the render ages packets out).
    assert packets <= 30 * subscribers
    assert packets > 0

    # the ring keeps the NEWEST deltas — the oldest packets rolled off
    ids = packet_ids(html)
    assert delta_id(4_240.0) in ids
    refute delta_id(4_201.0) in ids

    # the table is history, not animation: it has its own (deeper, 50-row)
    # bound, so the rows for the deltas whose packets rolled off are still
    # there — including the very first one
    assert length(Floki.find(doc, "tbody tr")) == 40
    assert Floki.find(doc, "tr#flow-row-1") != []
  end

  test "FLOW-5: the banner renders when the store is absent (separate-BEAM state)" do
    # no store started in this test — the mount guard sees none (M4/L6)
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "nothing to show"
    # no store means no subscribers and no nodes, but the page still renders
    assert node_labels(html) == ["store"]
  end

  test "FLOW-6: DurableStore.subscribers/0 returns live pids and prunes dead ones" do
    start_store!()

    alive = probe!()
    doomed = park()

    assert :ok = DurableStore.subscribe(alive)
    assert :ok = DurableStore.subscribe(doomed)

    subscribers = DurableStore.subscribers()
    assert alive in subscribers
    assert doomed in subscribers

    Process.exit(doomed, :kill)
    poll_until(fn -> not Process.alive?(doomed) end)

    pruned = DurableStore.subscribers()
    assert alive in pruned
    refute doomed in pruned
  end

  test "FLOW-7: the refresh tick recovers the view across a store restart" do
    path = start_store!()

    conn = build_conn()
    {:ok, view, html} = live(conn, "/")
    refute html =~ "nothing to show"

    assert :ok = DurableStore.append(received_wire(4_290.0, "flow7-before", "pre-outage"))

    # the store dies under the view; `stop_supervised!` blocks until it is
    # down, so the following send is strictly ordered after the death
    stop_supervised!(Kyber.DurableStore)

    send(view.pid, :refresh)
    down = render(view)

    assert down =~ "nothing to show"
    assert node_labels(down) == ["store"]
    # the outage does not rewrite history: the row for the delta that DID
    # commit stays, and the banner is what reports the live state
    assert down =~ "flow-row-1"

    # banner and row agree: a re-subscribe that could not be acked never
    # renders a healthy topology (no nodes, no edges) while detached — and
    # a second tick against the dead store neither raises nor "recovers"
    send(view.pid, :refresh)
    still_down = render(view)

    {:ok, down_doc} = Floki.parse_document(still_down)
    assert still_down =~ "nothing to show"
    assert Floki.find(down_doc, "svg.flow circle.node") == []
    assert Floki.find(down_doc, "svg.flow line.edge") == []
    assert packet_ids(still_down) == []

    # the store comes back on the SAME log, so it replays every delta it
    # committed. Its subscriber set, though, is fresh and has never heard of
    # this view: the tick must re-subscribe rather than render an empty
    # topology forever
    start_store!(path)

    # recovery is a pair of blocking store calls, so it waits for the same
    # throttle the membership read does (FLOW-9) — one tick is no longer
    # enough to heal
    tick_through_throttle(view)
    back = render(view)

    refute back =~ "nothing to show"
    assert "viewer" in node_labels(back)

    # the re-subscribe REBUILDS the table from the seeded snapshot instead of
    # emptying it: the delta committed before the outage is back in the table
    # although nothing has committed since. The packets ring is not rebuilt —
    # those were mid-flight when the store died
    before_id = delta_id(4_290.0)
    {:ok, back_doc} = Floki.parse_document(back)

    assert length(Floki.find(back_doc, "tbody tr")) == 1
    assert back =~ String.slice(before_id, 0, 12)
    assert packet_ids(back) == []

    # the re-subscribe is live, not cosmetic — the restarted store's feed lands
    assert :ok = DurableStore.append(received_wire(4_300.0, "flow7-restart", "recovered"))
    id = delta_id(4_300.0)

    live_html = render(view)
    assert packet_ids(live_html) == [id]

    # the live delta is numbered AFTER the rebuilt rows, so it gets its own
    # row rather than colliding with the snapshot's
    {:ok, live_doc} = Floki.parse_document(live_html)
    assert length(Floki.find(live_doc, "tbody tr")) == 2
    assert Floki.find(live_doc, "tr#flow-row-2") != []

    # a tab opened NOW, against a store that already holds both deltas, reads
    # the same store as the recovered one: mount seeds the table from its own
    # subscribe ack, so a fresh page is not an empty table under a full store
    {:ok, _fresh, fresh_html} = live(build_conn(), "/")

    {:ok, fresh_doc} = Floki.parse_document(fresh_html)
    assert length(Floki.find(fresh_doc, "tbody tr")) == 2
    assert fresh_html =~ String.slice(before_id, 0, 12)
    assert fresh_html =~ String.slice(id, 0, 12)
    # history is the table, not the animation: nothing is in flight on a
    # freshly mounted view
    assert packet_ids(fresh_html) == []
  end

  test "FLOW-8: the subscriber row is capped and the overflow collapses to one node" do
    start_store!()

    # 12 probes plus the view itself = 13 live subscribers, over the 8 cap
    for _n <- 1..12 do
      assert :ok = DurableStore.subscribe(probe!())
    end

    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    assert :ok = DurableStore.append(received_wire(4_400.0, "flow8-cap", "capped"))
    html = render(view)

    {:ok, doc} = Floki.parse_document(html)

    # 8 rendered subscriber nodes plus the one overflow label node
    assert length(Floki.find(doc, "svg.flow circle.node")) == 9
    assert length(Floki.find(doc, "svg.flow circle.node-more")) == 1
    assert "+5 more" in node_labels(html)

    # the overflow node carries no edge and no packets: the quadratic term
    # is the CAP, not the live subscriber count
    assert length(Floki.find(doc, "svg.flow line.edge")) == 8
    assert length(packet_ids(html)) == 8

    # the cap may never hide the viewing LiveView from its own topology: the
    # view subscribed LAST, so an oldest-first take would drop it. Nodes are
    # keyed by pid hash and every rendered node carries the packet, so the
    # view's own packet circle is the proof that its node is in the row.
    assert Floki.find(doc, ~s(circle.packet[id="packet-1-#{:erlang.phash2(view.pid)}"])) != []
  end

  test "FLOW-9: a detached view's recovery is throttled, not attempted every tick" do
    # no store at mount, so the view is detached with a KNOWN tick counter:
    # mount leaves it at 0 and every `:refresh` below advances it by one
    conn = build_conn()
    {:ok, view, html} = live(conn, "/")
    assert html =~ "nothing to show"

    start_store!()

    # tick 1 of the throttle window: the store is back, but re-subscribing
    # is two blocking calls into the process that serializes appends — the
    # view waits for its window instead of storming a store that may be the
    # slow one that detached it in the first place
    send(view.pid, :refresh)
    assert render(view) =~ "nothing to show"
    refute view.pid in registered_subscribers()

    # the rest of the window: recovery lands, once
    tick_through_throttle(view)
    healed = render(view)

    refute healed =~ "nothing to show"
    assert "viewer" in node_labels(healed)
    assert view.pid in registered_subscribers()
  end

  test "FLOW-10: a view unsubscribes when it terminates" do
    start_store!()

    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")
    pid = view.pid

    assert pid in registered_subscribers()

    # a graceful stop runs terminate/2, and `GenServer.stop/1` returns only
    # once the process is down — so the unsubscribe call has already been
    # serialized into the store. (A hard kill cannot run terminate; that
    # case is the store's own fan-out prune, tested as FLOW-6.)
    :ok = GenServer.stop(pid)

    refute pid in registered_subscribers()
  end

  test "FLOW-11: a mount whose subscribe is not acked never renders as healthy" do
    # a stand-in registered under the store's name: it is ALIVE (so the
    # store-down banner does not apply) but refuses the first subscribe,
    # which is what a call timing out behind the append queue looks like
    # to the view — the reply is simply not the ack
    stub_store!()

    conn = build_conn()
    {:ok, _view, html} = live(conn, "/")

    # without this the page renders no banner and no nodes: a blank that
    # reads as a healthy idle store while the view is off the delta feed
    assert html =~ "connecting to the store"
    assert node_labels(html) == ["store"]
  end

  # replies to the store's call protocol: the FIRST subscribe_seeded is
  # refused, every later one is acked (so the view's own refresh tick
  # recovers against it rather than crashing on an unexpected reply)
  defp stub_store! do
    pid = spawn(fn -> stub_loop(:refuse) end)
    Process.register(pid, DurableStore)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp stub_loop(mode) do
    receive do
      {:"$gen_call", from, {:subscribe_seeded, _pid}} ->
        GenServer.reply(from, if(mode == :refuse, do: {:error, :unavailable}, else: {:ok, %{}}))
        stub_loop(:ack)

      {:"$gen_call", from, :subscribers} ->
        GenServer.reply(from, [])
        stub_loop(mode)

      {:"$gen_call", from, _other} ->
        GenServer.reply(from, :ok)
        stub_loop(mode)
    end
  end
end
