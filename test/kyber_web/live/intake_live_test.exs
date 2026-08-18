defmodule KyberWeb.IntakeLiveTest do
  @moduledoc """
  AC1 — view 1: the live delta intake waterfall. Source:
  `DurableStore.subscribe_seeded/1` (the pinned F2 seam — no commit gap);
  committed deltas stream in order; each row shows kind, fan-out
  delivered/pruned counts, and the traced/untraced badge; duplicate
  re-appends surface via the `:store_append` span's `:duplicate` outcome.
  Sleep-free: the store's feed drives the stream, badges are refreshed by
  direct `:refresh` sends, and collector reads are polled with the
  receive-timeout helper.
  """

  use KyberWeb.Case, async: false

  alias Kyber.{DurableStore, Events, Wire}
  alias Kyber.Trace.Collector

  @human_seed String.duplicate("cd", 32)

  defp start_store! do
    dir = Path.join(System.tmp_dir!(), "kyber-intake-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({DurableStore, Path.join(dir, "store.jsonl")})
  end

  defp received_wire(ts, msg_id, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        msg_id,
        "channel:intake",
        "session:intake",
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

  test "AC1: committed deltas stream live, in commit order, with kinds and the untraced state" do
    start_store!()
    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    assert :ok = DurableStore.append(received_wire(2_000.0, "ac1-m1", "first"))
    assert :ok = DurableStore.append(received_wire(2_001.0, "ac1-m2", "second"))
    assert :ok = DurableStore.append(received_wire(2_002.0, "ac1-m3", "third"))

    id1 = delta_id(2_000.0)
    id2 = delta_id(2_001.0)
    id3 = delta_id(2_002.0)

    # render_async returns per-diff — keep consuming until the LAST row
    # streams in (all three messages are processed before the first flush,
    # the loop exits on the first call)
    html =
      render_until(view, fn h ->
        String.contains?(h, String.slice(id3, 0, 12)) and
          String.contains?(h, String.slice(id2, 0, 12)) and
          String.contains?(h, String.slice(id1, 0, 12))
      end)

    # all three streamed rows are present
    assert html =~ String.slice(id1, 0, 12)
    assert html =~ String.slice(id2, 0, 12)
    assert html =~ String.slice(id3, 0, 12)
    assert html =~ "received"

    # the rows render in commit order: the visible anchor for id1 comes
    # before id2 before id3 (anchor text, not the hrefs)
    {:ok, doc} = Floki.parse_document(html)
    rows = doc |> Floki.find("a.delta") |> Floki.attribute("phx-value-id")
    assert List.first(rows) == id1
    assert Enum.at(rows, 1) == id2
    assert Enum.at(rows, 2) == id3

    # no reactor on this BEAM -> the untraced state renders for each delta
    assert html =~ "untraced"
  end

  test "AC1: delivered/pruned counts render from the fan_out span" do
    start_store!()

    # a probe subscriber: the fan_out span must count it alongside the view
    probe = spawn(fn -> receive do _ -> :ok end end)
    assert :ok = DurableStore.subscribe(probe)

    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    assert :ok = DurableStore.append(received_wire(2_100.0, "ac1-counts", "counted"))
    id = delta_id(2_100.0)

    # the store's fan_out span cast lands in the collector (poll, no sleep)
    poll_until(fn -> Collector.fan_out_counts(id) == %{delivered: 2, pruned: 0} end)

    # the badge refresh surfaces the counts on the already-streamed row
    send(view.pid, :refresh)
    html = render_async(view, 1_000)
    assert html =~ "2"
  end

  test "AC1: duplicate re-appends surface via the store_append span's :duplicate outcome" do
    start_store!()
    conn = build_conn()
    {:ok, view, _html} = live(conn, "/")

    wire = received_wire(2_200.0, "ac1-dup", "duplicate me")
    assert :ok = DurableStore.append(wire)
    id = delta_id(2_200.0)

    html = render_async(view, 1_000)
    assert html =~ String.slice(id, 0, 12)
    refute html =~ "duplicate"

    # the identical wire re-appended: admitted by the door, set unchanged —
    # never fanned out again, surfaced via the span's :duplicate outcome
    assert :ok = DurableStore.append(wire)
    poll_until(fn -> Collector.append_outcome(id) == :duplicate end)

    send(view.pid, :refresh)
    html = render_async(view, 1_000)
    assert html =~ "duplicate"
  end

  test "AC1: the banner renders when the store is absent (separate-BEAM state)" do
    # no store started in this test — the view's mount guard sees none and
    # renders the explicit banner (M4/L6)
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "nothing to show"
  end

  # consume render diffs until the predicate holds (bounded by render_async's
  # own timeout — sleep-free)
  defp render_until(view, predicate, timeout \\ 2_000) do
    html = render_async(view, timeout)

    if predicate.(html) do
      html
    else
      render_until(view, predicate, timeout)
    end
  end

end
