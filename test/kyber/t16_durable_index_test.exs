defmodule Kyber.T16DurableIndexTest do
  @moduledoc """
  T16 AC1/AC2/AC4 — the DurableStore maintains an incremental dedup index and
  answers `dedup_check/1` in O(1) without scanning the set.

  The behavioral contract (identical to the T15c round-3/round-4 semantics,
  now index-backed):

    - a RECENT, UNANSWERED MessageReceived with `content` => duplicate
      (a re-send must collapse, no second turn minted)
    - a MessageReceived that HAS been answered (an InferenceRequested for it
      that got a ResponseDelta) => allowed (legitimate re-ask)
    - a STALE (outside the dup window) unanswered MessageReceived => allowed
      (the inference failed/timed out; operator can re-send to retry)

  The index is APPEND-ONLY: it only ever grows on admit, never shrinks —
  a refused delta must not change it (AC4). The subscribe feed (AC2)
  delivers one ordered cast per admitted delta, never for a refused one.
  """
  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Events, Keys, Store, Wire}
  alias Kyber.Agent.Events, as: AgentEvents

  @seed String.duplicate("ab", 32)
  @content "T16_DEDUP_MARKER"

  setup do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t16-key-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t16-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    :ok = Keys.import_human_seed(@seed, key_dir)
    log_path = Path.join(log_dir, "store.jsonl")

    Application.stop(:kyber)
    config_log = Application.get_env(:kyber, :log_path)
    Application.put_env(:kyber, :log_path, log_path)
    {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, config_log)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    %{log_path: log_path}
  end

  # append a signed MessageReceived and return its id
  defp append_message(content, ts) do
    {:ok, signed} =
      Events.message_received(
        @seed,
        ts,
        "message:t16:#{trunc(ts)}",
        "channel:t16",
        "session:t16",
        content
      )

    wire = Wire.envelope(signed)
    {:ok, %{id: id}} = Kyber.Store.verify(wire)
    :ok = DurableStore.append(wire)
    id
  end

  # append an InferenceRequested pointing at the message; return its id
  defp append_inference(message_id, ts) do
    # inference_requested(seed, ts, model, session_id, conversation_ref,
    # prompt_id, memory_ids) — the PROMPT REF is what the index's two-hop
    # bridge matches on, and it must point at the message id
    {:ok, signed} =
      AgentEvents.inference_requested(
        @seed,
        ts,
        "deepseek-v4-flash",
        "session:t16",
        "conversation:t16",
        message_id,
        []
      )

    wire = Wire.envelope(signed)
    {:ok, %{id: id}} = Kyber.Store.verify(wire)
    :ok = DurableStore.append(wire)
    id
  end

  defp append_response(inference_id, ts, content \\ "t16 answer") do
    {:ok, signed} = AgentEvents.response_delta(@seed, ts, inference_id, 0, content, [])
    :ok = DurableStore.append(Wire.envelope(signed))
  end

  describe "AC1 — dedup_check answers from the maintained index" do
    test "recent unanswered message is a duplicate; answer then re-ask is allowed" do
      now = System.system_time(:millisecond) * 1.0
      msg_id = append_message(@content, now)

      # index has learned the message; nothing has answered it
      assert DurableStore.dedup_check(@content, 30_000)

      # an inference + response answers it
      inf_id = append_inference(msg_id, now + 1)
      append_response(inf_id, now + 2)

      refute DurableStore.dedup_check(@content, 30_000)
    end

    test "stale unanswered message is allowed (retry-safe, round-4 semantics)" do
      stale = (System.system_time(:millisecond) - 3_600_000) * 1.0
      append_message(@content, stale)

      refute DurableStore.dedup_check(@content, 30_000)
    end

    test "different content is never a duplicate" do
      now = System.system_time(:millisecond) * 1.0
      append_message("T16_OTHER_MARKER", now)

      refute DurableStore.dedup_check(@content, 30_000)
    end
  end

  describe "AC1 — the O(1) seam: open_duplicate? does not scan the set" do
    test "dedup_check is answered by the store's index, not a set() rescan" do
      now = System.system_time(:millisecond) * 1.0
      append_message(@content, now)

      # instrument: count set/0 calls around a dedup_check
      before = DurableStore.set_calls()
      assert DurableStore.dedup_check(@content, 30_000)
      after_calls = DurableStore.set_calls()

      # a scan-based answer would have called set() (>=1); the index path
      # must not
      assert after_calls == before
    end
  end

  describe "AC4 — the index is append-only (no deletion, refused deltas don't move it)" do
    test "a refused delta does not change the index" do
      now = System.system_time(:millisecond) * 1.0
      append_message(@content, now)

      {:error, _} = DurableStore.append(%{"not" => "a valid wire"})
      assert DurableStore.dedup_check(@content, 30_000)
    end

    test "appending more deltas never shrinks the index's knowledge" do
      now = System.system_time(:millisecond) * 1.0
      append_message(@content, now)
      assert DurableStore.dedup_check(@content, 30_000)

      # another message + an unrelated inference don't remove the first entry
      append_message("T16_OTHER_MARKER", now + 1)
      inf = append_inference(append_message("T16_THIRD_MARKER", now + 2), now + 3)
      append_response(inf, now + 4)

      # the original content is still known (unanswered => still a dup)
      assert DurableStore.dedup_check(@content, 30_000)
    end
  end

  describe "AC2 — the subscribe feed" do
    test "subscribers receive one ordered cast per admitted delta, never for refused" do
      now = System.system_time(:millisecond) * 1.0

      parent = self()

      {:ok, sub} =
        Task.start(fn ->
          loop = fn loop ->
            receive do
              {:delta, id, claims} ->
                send(parent, {:feed, id, claims})
                loop.(loop)

              :stop ->
                :ok
            end
          end

          loop.(loop)
        end)

      :ok = DurableStore.subscribe(sub)

      id1 = append_message("T16_FEED_ONE", now)
      id2 = append_message("T16_FEED_TWO", now + 1)

      # refused deltas are never delivered
      {:error, _} = DurableStore.append(%{"nope" => true})

      # event-driven: each admitted delta arrives as its own {:feed, id, _}
      # cast in commit order; the refused delta never produces one
      assert_receive {:feed, ^id1, _claims1}, 5_000
      assert_receive {:feed, ^id2, _claims2}, 5_000
      refute_receive {:feed, _id, _claims}, 300

      :ok = DurableStore.unsubscribe(sub)
      send(sub, :stop)
    end
  end

  describe "AC3 — the spawned IndexServer (F3)" do
    test "fed by the feed, answers identically to the in-process index" do
      now = System.system_time(:millisecond) * 1.0

      # init ATOMICALLY seeds + subscribes (subscribe_seeded); no explicit
      # attach needed (P5 fix — the seed-then-attach gap is gone)
      {:ok, server} = Kyber.IndexServer.start_link(seed_from_set: true)

      # a recent unanswered message: both the in-process index and the
      # server's view agree it is a duplicate
      msg_id = append_message(@content, now)
      assert DurableStore.dedup_check(@content, 30_000)
      assert Kyber.IndexServer.open_duplicate?(server, @content, 30_000)
      refute Kyber.IndexServer.answered?(server, msg_id)

      # answer it through the store: the feed carries the inference +
      # response to the server's view, which flips to answered — same as the
      # in-process index
      inf_id = append_inference(msg_id, now + 1)
      append_response(inf_id, now + 2)

      refute DurableStore.dedup_check(@content, 30_000)
      refute Kyber.IndexServer.open_duplicate?(server, @content, 30_000)
      assert Kyber.IndexServer.answered?(server, msg_id)
    end

    test "a late subscriber re-seeds from set/0 (PM3 — replay == live fold)" do
      now = System.system_time(:millisecond) * 1.0
      msg_id = append_message(@content, now)
      inf_id = append_inference(msg_id, now + 1)
      append_response(inf_id, now + 2)

      # spawn AFTER the history exists, seed_from_set: true -> catches up
      {:ok, server} = Kyber.IndexServer.start_link(seed_from_set: true)
      assert Kyber.IndexServer.answered?(server, msg_id)
      refute Kyber.IndexServer.open_duplicate?(server, @content, 30_000)

      # and with seed_from_set: false it does NOT know the history
      {:ok, blind} = Kyber.IndexServer.start_link(seed_from_set: false)
      refute Kyber.IndexServer.answered?(blind, msg_id)
    end

    test "the server survives a store restart and re-attaches (P5 fix)" do
      now = System.system_time(:millisecond) * 1.0
      msg_id = append_message(@content, now)
      inf_id = append_inference(msg_id, now + 1)
      append_response(inf_id, now + 2)

      {:ok, server} = Kyber.IndexServer.start_link(seed_from_set: true)
      assert Kyber.IndexServer.answered?(server, msg_id)

      # restart the STORE from the same log: the server's monitor fires, it
      # re-attaches + re-seeds atomically (bounded retry until the new store
      # is up), and still agrees.
      Application.stop(:kyber)
      {:ok, _} = Application.ensure_all_started(:kyber)
      assert DurableStore.set() |> map_size() >= 3

      # the server re-attached and re-seeded from the restarted store (the
      # re-attach is a bounded 50ms-cadence retry, so the view catches up
      # within the poll budget — no-sleep idiom)
      answered =
        Enum.reduce_while(1..100, false, fn _, _ ->
          if Kyber.IndexServer.answered?(server, msg_id) do
            {:halt, true}
          else
            receive do
            after
              25 -> :timeout
            end

            {:cont, false}
          end
        end)

      assert answered

      # and it is live on the feed again: a NEW message + answer propagates
      # (the feed send and the server's processing are async across
      # processes — gate on the view with the no-sleep poll, like the
      # re-attach above)
      now2 = System.system_time(:millisecond) * 1.0
      msg2 = append_message("T16_AFTER_RESTART", now2)
      refute Kyber.IndexServer.answered?(server, msg2)
      inf2 = append_inference(msg2, now2 + 1)
      append_response(inf2, now2 + 2)

      answered2 =
        Enum.reduce_while(1..100, false, fn _, _ ->
          if Kyber.IndexServer.answered?(server, msg2) do
            {:halt, true}
          else
            receive do
            after
              25 -> :timeout
            end

            {:cont, false}
          end
        end)

      assert answered2

      # a fresh server seeded from the RESTARTED store agrees too (PM3)
      {:ok, fresh} = Kyber.IndexServer.start_link(seed_from_set: true)
      assert Kyber.IndexServer.answered?(fresh, msg_id)
    end

    test "seed+attach is atomic: deltas committed between seed and attach are never lost" do
      # the OLD race: seed from set/0, then subscribe — a delta committed in
      # between is lost. The fix: subscribe_seeded does both in ONE store
      # call. Exercise it by starting the server, then IMMEDIATELY appending
      # a message (the server's init call and this append serialize in the
      # store — whichever order, the server ends up consistent).
      {:ok, server} = Kyber.IndexServer.start_link(seed_from_set: true)
      now = System.system_time(:millisecond) * 1.0
      msg_id = append_message(@content, now)

      # the message is either in the server's seed OR delivered by the feed
      # (the store serializes subscribe_seeded and the append); either way
      # the view must know it
      assert Kyber.IndexServer.open_duplicate?(server, @content, 30_000)
      refute Kyber.IndexServer.answered?(server, msg_id)
    end
  end
end
