defmodule Kyber.Agent.MemoryStoreTest do
  @moduledoc """
  T11c — AC10's testable properties beyond the round-trip: the A/B seam
  (stub ↔ real retriever, swappable at construction against the same
  store), the carried determinism clause, trajectory retrieval, watcher
  idempotence, and the container-as-cache (unconditional intake, rehydrate
  by replay). Pure door + tmp dirs throughout.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Schema, Store, Wire}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.{Projector, Retriever, Tierer, Watcher}
  alias Kyber.Agent.MemoryPort

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @ts 1_754_000_000_000

  # the T5/T6 tmp-dir pattern (test/vault_test.exs): a fresh dir under the
  # system tmp per test, removed on exit — the real ~/.kyber is never touched
  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "kyber-memory-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp admit!(set, signed) do
    assert {:ok, set} = Store.admit(Wire.envelope(signed), set)
    set
  end

  defp remember!(set, ts, entity_id, content) do
    assert {:ok, signed} = AgentEvents.memory_entity(@agent_seed, ts, entity_id, content, [])
    admit!(set, signed)
  end

  defp edit!(set, ts, target_id, content) do
    assert {:ok, signed} = AgentEvents.memory_edited(@agent_seed, ts, target_id, content)
    admit!(set, signed)
  end

  # ------------------------------------------------------- the A/B property

  test "AC10: stub and real retriever are swappable behind the seam, same store, same query shape" do
    set = remember!(DeltaSet.new(), @ts, "user:myk", "Myk prefers Elixir")
    %{head: head} = Memory.canon(set, "user:myk")

    {:ok, signed} =
      Events.message_received(@human_seed, @ts + 1, "msg-1", "chan-1", "session:s1", "hi")

    {:ok, received} = signed |> Wire.envelope() |> Store.verify()
    received = %{id: received.id, claims: received.claims}

    handler = fn memory ->
      ContextBuilder.handler(seed: @agent_seed, store: fn -> set end, memory: memory)
    end

    for memory <- [{MemoryPort.Stub, %{memories: [head]}}, {Retriever, %{store: set}}] do
      assert [wire] = handler.(memory).([received])
      assert {:ok, request} = Store.verify(wire)
      assert Schema.resolve(request.claims).memoryPointers == [{:delta, head, "informed"}]
    end
  end

  test "the carried determinism clause: retrieve/2 is a pure function of (store, query, state)" do
    set =
      DeltaSet.new()
      |> remember!(@ts, "user:myk", "Myk prefers Elixir")
      |> remember!(@ts + 1, "proj:kyber", "Kyber is an agent harness")

    query = %{session_id: "s1", prompt: "anything"}

    assert Retriever.retrieve(query, %{store: set}) == Retriever.retrieve(query, %{store: set})

    assert Retriever.retrieve(query, %{store: fn -> set end}) ==
             Retriever.retrieve(query, %{store: set})

    assert Retriever.retrieve(query, %{}) == {:error, :no_store}
  end

  # ------------------------------------------------- trajectory + resolution

  test "trajectory: the time-ordered chain of a memory's resolutions, oldest → newest, edits of edits included" do
    set = remember!(DeltaSet.new(), @ts, "user:myk", "v1")
    %{head: base} = Memory.canon(set, "user:myk")

    set = edit!(set, @ts + 1, base, "v2")
    %{head: second} = Memory.canon(set, "user:myk")
    assert second != base

    set = edit!(set, @ts + 2, second, "v3")
    %{head: third, content: "v3"} = Memory.canon(set, "user:myk")

    assert Retriever.trajectory(set, "user:myk") == [base, second, third]
    assert Retriever.trajectory(set, "user:never") == []
  end

  test "a MemoryEdited without human attestation re-resolves the canon but stays auto-derived" do
    set = remember!(DeltaSet.new(), @ts, "user:myk", "v1")
    %{head: base} = Memory.canon(set, "user:myk")

    assert {:ok, signed} = AgentEvents.memory_edited(@agent_seed, @ts + 1, base, "v2", "lens")
    set = admit!(set, signed)

    assert %{content: "v2", provenance: :auto} = Memory.canon(set, "user:myk")
  end

  test "tierer: human tier first, then canon recency, then entity id — a total, replay-stable order" do
    mem = fn entity, prov, ts ->
      %{entity: entity, provenance: prov, timestamp: ts, content: "", head: "", chain: []}
    end

    ranked =
      Tierer.rank([
        mem.("c", :auto, 3.0),
        mem.("b", :human, 1.0),
        mem.("a", :auto, 3.0),
        mem.("d", :human, 2.0)
      ])

    assert Enum.map(ranked, & &1.entity) == ["d", "b", "a", "c"]
  end

  # ---------------------------------------------------------------- watcher

  test "watcher idempotence: an unchanged file, a re-tick after admission, and a foreign shape all emit nothing",
       %{tmp_dir: tmp_dir} do
    vault_dir = Path.join(tmp_dir, "vault")
    set = remember!(DeltaSet.new(), @ts, "user:myk", "v1")

    tick = fn set, ts ->
      Watcher.tick(store: set, vault_dir: vault_dir, seed: @agent_seed, ts: ts)
    end

    # nothing projected yet: nothing observed
    assert {:ok, []} = tick.(set, @ts + 1)

    assert {:ok, %{files: 1}} = Projector.project(set, vault_dir)
    path = Projector.path(vault_dir, "user:myk")

    # unchanged body: nothing to attest
    assert {:ok, []} = tick.(set, @ts + 1)

    # a garbled file (no frontmatter) is not an edit — the projector owns the shape
    File.write!(path, "just some text")
    assert {:ok, []} = tick.(set, @ts + 1)

    # a real divergence emits exactly once per canon: after admission the
    # canon matches the body and the next tick is a no-op
    assert {:ok, _} = Projector.project(set, vault_dir)
    File.write!(path, String.replace(File.read!(path), "v1", "v2"))
    assert {:ok, [wire]} = tick.(set, @ts + 1)
    assert {:ok, set} = Store.admit(wire, set)
    assert {:ok, []} = tick.(set, @ts + 2)
    assert %{content: "v2", provenance: :human} = Memory.canon(set, "user:myk")
  end

  # ------------------------------------------- the container (cache of truth)

  test "container: intake is unconditional through the one door; rehydrate replays; the cache is a lens" do
    {:ok, container} = Memory.start_link()

    {:ok, memory_signed} = AgentEvents.memory_entity(@agent_seed, @ts, "user:myk", "v1", [])
    memory_wire = Wire.envelope(memory_signed)

    # a NON-memory delta intakes too — no type filter (spine 9)
    {:ok, other_signed} =
      Events.message_received(@human_seed, @ts + 1, "msg-1", "chan-1", "session:s1", "hi")

    other_wire = Wire.envelope(other_signed)

    assert :ok = Memory.intake(container, memory_wire)
    assert :ok = Memory.intake(container, other_wire)
    assert map_size(Memory.set(container)) == 2

    # the resolution lens picks the memory vocabulary out
    assert [%{entity: "user:myk", content: "v1", provenance: :auto}] =
             Memory.memories(container)

    # a refused wire leaves the cache untouched (verify-then-merge)
    assert {:error, _} = Memory.intake(container, %{"id" => "nope"})
    assert map_size(Memory.set(container)) == 2

    # rehydrate by replay: the same wires rebuild the same cache
    cached = Memory.set(container)
    assert :ok = Memory.rehydrate(container, [memory_wire, other_wire])
    assert Memory.set(container) == cached
  end
end
