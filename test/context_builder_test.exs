defmodule Kyber.Agent.ContextBuilderTest do
  @moduledoc """
  T11b — the context builder: fires on `message.received`, gathers the
  session, injects memories through the MemoryPort seam, and emits ONE thin
  `InferenceRequested` delta per prompt — pointers only, never conversation
  text, byte-identical on re-fire (the AC3 dedup depends on it).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Events, Schema, Store, Wire}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.MemoryPort

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)

  defp received(ts, msg_id, content) do
    {:ok, signed} = Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)
    {:ok, delta} = signed |> Wire.envelope() |> Store.verify()
    {delta, signed}
  end

  defp handler(set, memories) do
    ContextBuilder.handler(
      seed: @agent_seed,
      store: fn -> set end,
      memory: {MemoryPort.Stub, %{memories: memories}}
    )
  end

  test "one thin InferenceRequested per prompt: typed, pointers only, memory via the seam" do
    {delta, _signed} = received(1_700_000_000_000, "msg-1", "What is the cap?")
    memory_id = String.duplicate("11", 32)

    assert [wire] = handler(%{}, [memory_id]).([delta])

    assert {:ok, request} = Store.verify(wire)
    typed = Schema.resolve(request.claims)

    assert typed.type == "InferenceRequested"
    assert typed.model == "kimi-k3"
    assert typed.promptRef == {:delta, delta.id, "requested"}
    assert typed.sessionId == {:entity, "session:s1", "inferences"}
    assert typed.memoryPointers == [{:delta, memory_id, "informed"}]

    # thin: closed validation already proves no conversation text rides —
    # and the prompt's content string appears nowhere in the wire
    refute inspect(wire) =~ "What is the cap?"
  end

  test "the emission is deterministic: a re-fire is byte-identical (AC3's dedup)" do
    {delta, signed} = received(1_700_000_000_000, "msg-1", "What is the cap?")
    set = %{delta.id => signed}

    assert [wire1] = handler(set, []).([delta])
    assert [wire2] = handler(set, []).([delta])
    assert wire1 == wire2
  end

  test "conversationRef points at the latest prior conversation delta, never at text" do
    {first, first_signed} = received(1_700_000_000_000, "msg-1", "First question")
    {second, second_signed} = received(1_700_000_100_000, "msg-2", "Second question")
    set = %{first.id => first_signed, second.id => second_signed}

    assert [wire] = handler(set, []).([second])
    assert {:ok, request} = Store.verify(wire)
    typed = Schema.resolve(request.claims)

    assert typed.conversationRef == {:delta, first.id, "context_of"}

    # the first prompt of a session has no prior context: it grounds on itself
    assert [first_wire] = handler(%{}, []).([first])
    assert {:ok, first_request} = Store.verify(first_wire)
    assert Schema.resolve(first_request.claims).conversationRef == {:delta, first.id, "context_of"}
  end

  test "a received delta without a session pointer yields nothing (reject, never repair)" do
    {delta, _signed} = received(1_700_000_000_000, "msg-1", "hello")
    no_session = update_in(delta.claims.pointers, &Enum.reject(&1, fn p -> p.role == "session" end))

    assert handler(%{}, []).([no_session]) == []
  end

  test "the retriever is swappable behind the seam (the A/B property)" do
    defmodule OtherRetriever do
      @behaviour Kyber.Agent.MemoryPort
      @impl true
      def retrieve(%{prompt: prompt}, _state) do
        if prompt =~ "cap", do: {:ok, [String.duplicate("22", 32)]}, else: {:ok, []}
      end
    end

    {delta, _signed} = received(1_700_000_000_000, "msg-1", "What is the cap?")

    handler =
      ContextBuilder.handler(seed: @agent_seed, store: fn -> %{} end, memory: {OtherRetriever, nil})

    assert [wire] = handler.([delta])
    assert {:ok, request} = Store.verify(wire)

    assert Schema.resolve(request.claims).memoryPointers ==
             [{:delta, String.duplicate("22", 32), "informed"}]
  end
end
