defmodule Kyber.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Kyber.{AgentLoop, DeltaSet, Events, Keys, Store}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @agent_seed String.duplicate("ab", 32)

  defp received_delta(content \\ "hello", ts \\ 1_754_512_345_678) do
    {:ok, {claims, _sig}} =
      Events.message_received(
        @human_seed,
        ts,
        "message:discord:t10:1",
        "channel:discord:t10",
        "session:discord:t10",
        content
      )

    %{id: Delta.id_hex(claims), claims: claims}
  end

  test "AC4: the built-in handler emits the pinned deterministic ack" do
    handler = AgentLoop.handler(@agent_seed)
    %{id: received_id, claims: received_claims} = d = received_delta()

    assert [wire] = handler.([d])

    # the response is a new message claim: kind marker "sent" first, pointer
    # back to the received claim, the pinned verbatim reply text
    assert wire["claims"]["pointers"] == [
             %{
               "role" => "sent",
               "target" => %{"id" => "message:ack:" <> received_id, "context" => "outgoing"}
             },
             %{
               "role" => "via",
               "target" => %{"id" => "channel:discord:t10", "context" => "sent"}
             },
             %{"role" => "content", "target" => "ack " <> received_id},
             %{"role" => "caused_by", "target" => %{"delta" => received_id}},
             %{
               "role" => "type",
               "target" => %{"id" => "MessageSent", "context" => "instances"}
             }
           ]

    # signed by the daemon's (agent) key, not the human's
    assert wire["claims"]["author"] == Keys.author_for_seed(@agent_seed)

    # determinism pin: the response claims the received claim's own timestamp,
    # so the response id is a pure function of the input view (re-fires dedupe
    # by content address)
    assert wire["claims"]["timestamp"] == received_claims.timestamp
  end

  test "AC4: the response is deterministic — the same view yields the identical wire" do
    handler = AgentLoop.handler(@agent_seed)
    d = received_delta()

    assert handler.([d]) == handler.([d])
  end

  test "AC4: the door verifies the response (the daemon's signature is valid)" do
    handler = AgentLoop.handler(@agent_seed)
    [wire] = handler.([received_delta()])

    assert {:ok, _set} = Store.admit(wire, DeltaSet.new())
  end

  test "a received claim with no 'at' pointer yields no response (reject, never repair)" do
    raw = %{
      timestamp: 1_754_512_345_678.0,
      author: Keys.author_for_seed(@human_seed),
      pointers: [
        %{role: "received", target: {:entity, "message:x:1", "incoming"}},
        %{role: "content", target: {:string, "hi"}}
      ]
    }

    {:ok, claims} = Delta.validate(raw)
    handler = AgentLoop.handler(@agent_seed)

    assert handler.([%{id: Delta.id_hex(claims), claims: claims}]) == []
  end

  test "the handler is (delta[]) -> delta[]: a multi-delta view yields one response per delta" do
    handler = AgentLoop.handler(@agent_seed)
    d1 = received_delta("one")
    d2 = received_delta("two")

    assert [w1, w2] = handler.([d1, d2])

    assert w1["claims"]["pointers"] |> Enum.at(2) == %{
             "role" => "content",
             "target" => "ack " <> d1.id
           }

    assert w2["claims"]["pointers"] |> Enum.at(2) == %{
             "role" => "content",
             "target" => "ack " <> d2.id
           }
  end
end
