defmodule KyberWeb.FlowLiveTest do
  @moduledoc """
  T19 view 0 — the delta topology. The funnel is the store's append point,
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

  @human_seed String.duplicate("cd", 32)

  defp start_store! do
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
    start_supervised!({DurableStore, Path.join(dir, "store.jsonl")})
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

  test "AC1: the funnel and one node per live subscriber render" do
    start_store!()

    # an anonymous subscriber (labelled honestly as a viewer) and one
    # registered as the daemon
    anon = probe!()
    assert :ok = DurableStore.subscribe(anon)

    daemon = probe!()
    Process.register(daemon, Kyber.Daemon)
    on_exit(fn -> Process.unregister(Kyber.Daemon) end)
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

  test "AC2: a committed delta spawns a kind-coloured packet that opens its trace" do
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

  test "AC3: the fan-out delivered/pruned counts surface on refresh" do
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

  test "AC4: the packet ring is bounded" do
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
    # 40 deltas committed, at most @max_packets (30) in the ring
    assert packets <= 30 * subscribers
    assert packets == 30 * subscribers

    # the ring keeps the NEWEST deltas — the oldest packets rolled off
    ids = packet_ids(html)
    assert delta_id(4_240.0) in ids
    refute delta_id(4_201.0) in ids
  end

  test "AC5: the banner renders when the store is absent (separate-BEAM state)" do
    # no store started in this test — the mount guard sees none (M4/L6)
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "nothing to show"
    # no store means no subscribers and no nodes, but the page still renders
    assert node_labels(html) == ["store"]
  end

  test "AC6: DurableStore.subscribers/0 returns live pids and prunes dead ones" do
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
end
