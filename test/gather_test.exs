defmodule Kyber.GatherTest do
  use ExUnit.Case, async: true

  alias Kyber.{Events, Gather, Wire}

  @agent_seed String.duplicate("ab", 32)
  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  # Each test gets its own isolated Gather (a pid, not the named singleton) so
  # the suite stays async. The sink is a closure that forwards every persisted
  # delta to the test process — the no-sleep firing oracle: Gather.route/notify
  # are synchronous calls, so a fired handler's sinked output is on the mailbox
  # the instant the call returns.
  setup do
    test = self()
    persist = fn {claims, _sig} -> send(test, {:persisted, claims}) && :ok end

    {:ok, gather} = Gather.start_link(name: nil, persist: persist, pulse_only: ["tick"])
    on_exit(fn -> if Process.alive?(gather), do: GenServer.stop(gather) end)

    {:ok, gather: gather}
  end

  # -------------------------------------------------------------- fixtures

  defp received_delta(message_id \\ "message:discord:g:1") do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        @ts,
        message_id,
        "channel:discord:g",
        "session:discord:g",
        "hello gather"
      )

    signed
  end

  defp tick_wire do
    {:ok, signed} = Events.watcher_tick(@agent_seed, @ts, "watcher:g:1")
    Wire.envelope(signed)
  end

  # a handler that acks whatever it is handed (the T10 degenerate single-delta
  # view): message.received -> message.sent, deterministic reply
  defp ack_handler do
    fn deltas ->
      Enum.map(deltas, fn {claims, _sig} ->
        received_id = Rhizomatic.Delta.id_hex(claims)

        {:ok, signed} =
          Events.message_sent(
            @agent_seed,
            claims.timestamp,
            received_id,
            "message:kyber:ack:" <> received_id,
            "channel:discord:g",
            "ack " <> received_id
          )

        signed
      end)
    end
  end

  defp flavor(claims), do: claims.pointers |> List.first() |> Map.fetch!(:role)

  # ------------------------------------------------------------------ route

  test "route fires the role-matched handler and sinks its output", %{gather: gather} do
    Gather.subscribe(gather, "received", ack_handler())

    delta = received_delta()
    assert {:ok, [{sent_claims, _sig}]} = Gather.route(gather, delta)

    # the output is a message.sent whose reply points back at the received id
    received_id = Rhizomatic.Delta.id_hex(elem(delta, 0))
    assert flavor(sent_claims) == "sent"
    assert Enum.any?(sent_claims.pointers, &(&1.target == {:string, "ack " <> received_id}))

    # ...and it was sinked (persist-everything at the sink)
    assert_receive {:persisted, ^sent_claims}
  end

  test "a claim with no matching subscriber routes to nothing (no fire, no output)", %{
    gather: gather
  } do
    # no subscribers at all
    assert {:ok, []} = Gather.route(gather, received_delta())
    refute_receive {:persisted, _}
  end

  test "the producing handler is not its own subscriber — a message.sent never re-fires it", %{
    gather: gather
  } do
    Gather.subscribe(gather, "received", ack_handler())

    # route the received -> produces a sent
    assert {:ok, [sent]} = Gather.route(gather, received_delta())
    # route the sent back through: role 'sent' has no subscriber -> nothing
    assert {:ok, []} = Gather.route(gather, sent)
  end

  # ------------------------------------------------------------------ notify

  test "notify with a pulse-only shape fires the handler but NEVER persists the pulse", %{
    gather: gather
  } do
    # a tick subscriber whose side effect is a message.sent (AC5's example)
    Gather.subscribe(gather, "tick", fn deltas ->
      Enum.map(deltas, fn {claims, _sig} ->
        {:ok, signed} =
          Events.message_sent(
            @agent_seed,
            claims.timestamp,
            "watcher:tick:response",
            "message:kyber:tick",
            "channel:kyber:watcher",
            "tick observed"
          )

        signed
      end)
    end)

    assert {:ok, :pulsed} = Gather.notify(gather, tick_wire())

    # the side effect landed (the subscriber's message.sent was sinked)...
    assert_receive {:persisted, sent_claims}
    assert flavor(sent_claims) == "sent"

    # ...but the tick itself was NEVER sinked (no watcher.tick reaches memory)
    refute_receive {:persisted, %{pointers: [%{role: "tick"} | _]}}
  end

  test "notify with a default (persist) shape admits the claim and does NOT fire immediately", %{
    gather: gather
  } do
    Gather.subscribe(gather, "received", ack_handler())

    wire = Wire.envelope(received_delta())
    assert {:ok, :persisted} = Gather.notify(gather, wire)

    # the INPUT is admitted to the store (persist-everything default)...
    assert_receive {:persisted, received_claims}
    assert flavor(received_claims) == "received"

    # ...and the handler did NOT fire here (the log-poll fires persisted
    # claims exactly once; notify must not double-fire them)
    refute_receive {:persisted, %{pointers: [%{role: "sent"} | _]}}
  end

  test "notify never weakens the door: an unsigned/tampered wire is refused, never pulsed", %{
    gather: gather
  } do
    Gather.subscribe(gather, "tick", fn _ -> flunk("a refused pulse must not fire") end)

    tampered = Map.put(tick_wire(), "sig", String.duplicate("00", 64))
    assert {:error, _reason} = Gather.notify(gather, tampered)
    refute_receive {:persisted, _}

    unsigned = Map.delete(tick_wire(), "sig")
    assert {:error, _reason} = Gather.notify(gather, unsigned)
    refute_receive {:persisted, _}
  end
end
