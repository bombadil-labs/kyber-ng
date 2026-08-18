defmodule Kyber.Agent.MemoryTest do
  @moduledoc """
  T11c — AC6: the memory store round-trips through markdown. A MemoryEntity
  resolves (entities-as-resolutions, never written) → projects to a vault
  markdown file; a HUMAN EDIT to that file, observed by a watcher tick (the
  no-sleep drive), becomes an attested `MemoryEdited` delta; the entity's
  canon re-resolves to the edited content, carries `provenance: :human`, and
  the retriever ranks it above auto-derived memory.

  Everything here rides the pure door (`Kyber.Store.admit/2`) against plain
  delta sets and an ExUnit tmp vault dir — no live store, no real `~/.kyber`.
  """
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, Schema, Store, Wire}
  alias Kyber.Agent.Events
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.{Projector, Retriever, Watcher}

  @agent_seed String.duplicate("b2", 32)
  @human_seed String.duplicate("a1", 32)
  @ts 1_754_000_000_000

  defp human_author, do: Kyber.Keys.author_for_seed(@human_seed)

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
    assert {:ok, signed} = Events.memory_entity(@agent_seed, ts, entity_id, content, [])
    admit!(set, signed)
  end

  test "AC6: resolve → project → human edit → watcher tick → MemoryEdited → canon re-resolves, provenance ranks",
       %{tmp_dir: tmp_dir} do
    vault_dir = Path.join(tmp_dir, "vault")

    set =
      DeltaSet.new()
      |> remember!(@ts, "user:myk", "Myk prefers Elixir")
      |> remember!(@ts + 1, "proj:kyber", "Kyber is an agent harness")

    # the memory resolves — an entity-as-resolution over the delta chain,
    # auto-derived until a human says otherwise
    assert %{content: "Myk prefers Elixir", provenance: :auto, head: head} =
             Memory.canon(set, "user:myk")

    # ... and projects to a vault markdown file (the rendering lens)
    assert {:ok, %{files: 2}} = Projector.project(set, vault_dir)
    path = Projector.path(vault_dir, "user:myk")
    assert File.exists?(path)
    assert File.read!(path) =~ "Myk prefers Elixir"

    # a HUMAN edits that file out-of-band
    edited =
      path
      |> File.read!()
      |> String.replace("Myk prefers Elixir", "Myk prefers Elixir and Rust")

    File.write!(path, edited)

    # tick the watcher — the tick is the no-sleep drive; it answers the
    # signed MemoryEdited wire, admissible through the one door. The edit is
    # signed with the HUMAN's key (fold from the T11c verdict: provenance is
    # authority — the signer decides, not the reason label)
    assert {:ok, [wire]} =
             Watcher.tick(
               store: fn -> set end,
               vault_dir: vault_dir,
               seed: @agent_seed,
               human_seed: @human_seed,
               ts: @ts + 2
             )

    assert {:ok, %{claims: claims}} = Store.verify(wire)
    typed = Schema.resolve(claims)

    # attested: signed, source: :human_edit (riding the schema's `reason`
    # role), NEW content inline, OLD content by pointer — the `edits` target
    # is the superseded canon head, whose delta carries the old content
    assert typed.type == "MemoryEdited"
    assert typed.content == "Myk prefers Elixir and Rust"
    assert typed.reason == "human_edit"
    assert typed.edits == {:delta, head, "edited"}
    {old_claims, _sig} = Map.fetch!(set, head)
    assert Schema.resolve(old_claims).content == "Myk prefers Elixir"

    # the edit delta lands; the entity's canon re-resolves to the edited
    # content and carries provenance: :human — SIGNER-derived now
    set = admit!(set, {claims, wire["sig"]})

    assert %{content: "Myk prefers Elixir and Rust", provenance: :human, head: edited_head} =
             Memory.canon(set, "user:myk", human_author())

    assert %{provenance: :auto, head: auto_head} =
             Memory.canon(set, "proj:kyber", human_author())

    # the retriever (the REAL MemoryPort) ranks the human-edited memory
    # ABOVE the auto-derived one — provenance is a ranking axis
    assert {:ok, [^edited_head, ^auto_head]} =
             Retriever.retrieve(
               %{session_id: "s1", prompt: "anything"},
               %{store: set, human_author: human_author()}
             )

    # re-projection reifies the provenance role into the rendered file
    assert {:ok, _} = Projector.project(set, vault_dir)
    reprojected = File.read!(path)
    assert reprojected =~ "provenance: human"
    assert reprojected =~ "Myk prefers Elixir and Rust"
  end

  test "EOL canonicalization: a save that only touches line endings mints NO edit" do
    # premortem C2 fix 2026-08-06 (pinned in AC6): editors normalize
    # trailing newlines / CRLF; the watcher compares canonicalized bodies on
    # both sides, so a CRLF save is not a divergence and embeds no \r bytes.
    set =
      DeltaSet.new()
      |> remember!(@ts, "user:myk", "Myk prefers Elixir")

    vault_dir =
      Path.join(System.tmp_dir!(), "kyber-memory-eol-#{System.os_time()}-#{System.unique_integer([:positive])}")

    {:ok, %{files: 1}} = Projector.project(set, vault_dir)
    path = Projector.path(vault_dir, "user:myk")

    # the human's editor saves with CRLF + an extra trailing blank line
    File.write!(path, String.replace(File.read!(path), "\n", "\r\n") <> "\r\n")

    assert {:ok, []} =
             Watcher.tick(
               store: fn -> set end,
               vault_dir: vault_dir,
               seed: @agent_seed,
               human_seed: @human_seed,
               ts: @ts + 1
             )

    # and a REAL divergence still mints the edit (canonical body stored)
    File.write!(path, String.replace(File.read!(path), "Elixir", "Elixir and Rust"))

    assert {:ok, [wire]} =
             Watcher.tick(
               store: fn -> set end,
               vault_dir: vault_dir,
               seed: @agent_seed,
               human_seed: @human_seed,
               ts: @ts + 2
             )

    {:ok, %{claims: claims}} = Store.verify(wire)
    assert Schema.resolve(claims).content == "Myk prefers Elixir and Rust"
  end

  test "spoof-proof: an agent-signed edit LABELLED human_edit is :auto under a known human key" do
    # the T11c verdict fold (C's best idea): provenance is AUTHORITY. An
    # agent that writes `reason: "human_edit"` must NOT be able to launder
    # its edit into :human — this is the overclaim B's build shipped and
    # could not test.
    set =
      DeltaSet.new()
      |> remember!(@ts, "user:myk", "Myk prefers Elixir")

    # the agent signs an edit with the HUMAN marker but its OWN key
    base_head = Memory.canon(set, "user:myk").head

    assert {:ok, signed} =
             Events.memory_edited(
               @agent_seed,
               @ts + 1,
               base_head,
               "Myk prefers Rust",
               "human_edit"
             )

    set = admit!(set, signed)

    assert %{provenance: :auto} = Memory.canon(set, "user:myk", human_author())

    # the pre-wiring fallback (human_author == nil) still honours the marker
    assert %{provenance: :human} = Memory.canon(set, "user:myk")
  end

  test "AC10 A/B: a second container rehydrated by replay serves the same queries against the same store" do
    # fold from the T11c verdict (B's best attribute): the three-way
    # equality — container A == container B == the bare pure path — is the
    # only test that proves AC10's A/B property end-to-end.
    start_supervised!(Kyber.Store)

    vault_dir =
      Path.join(System.tmp_dir!(), "kyber-memory-ab-#{System.os_time()}-#{System.unique_integer([:positive])}")

    {:ok, memory_a} = Memory.start_link(name: nil)

    {:ok, entity_wire} =
      Events.memory_entity(@agent_seed, @ts, "topic:cap", "the cap is a lens", [])

    entity_wire = Wire.envelope(entity_wire)
    :ok = Memory.intake(memory_a, entity_wire)
    :ok = Kyber.Store.append(entity_wire)

    # project the memory to its vault file, then edit it OUT-OF-BAND
    {:ok, %{files: 1}} = Projector.project(Memory.set(memory_a), vault_dir)
    path = Projector.path(vault_dir, "topic:cap")

    File.write!(
      path,
      String.replace(File.read!(path), "the cap is a lens", "the cap is a lens, never a store")
    )

    {:ok, [edit_wire]} =
      Watcher.tick(
        store: fn -> Memory.set(memory_a) end,
        vault_dir: vault_dir,
        seed: @agent_seed,
        human_seed: @human_seed,
        ts: @ts + 1
      )

    :ok = Memory.intake(memory_a, edit_wire)
    :ok = Kyber.Store.append(edit_wire)

    # the second container: rehydrate by replay from the SAME store
    {:ok, memory_b} = Memory.start_link(name: nil)

    wires = Kyber.Store.set() |> Map.values() |> Enum.map(&Kyber.Wire.envelope/1)
    :ok = Memory.rehydrate(memory_b, wires)

    # identical resolutions from both caches — and from the bare set
    assert Memory.memories(memory_a) == Memory.memories(memory_b)
    assert Memory.memories(memory_b) == Memory.resolve_set(Kyber.Store.set())

    assert %{content: "the cap is a lens, never a store", provenance: :human} =
             Memory.canon(Memory.set(memory_b), "topic:cap", human_author())

    # identical retrieval against both containers and the bare store
    query = %{session_id: "session:s1", prompt: "cap"}
    reader_a = %{store: fn -> Memory.set(memory_a) end, human_author: human_author()}
    reader_b = %{store: fn -> Memory.set(memory_b) end, human_author: human_author()}
    reader_store = %{store: fn -> Kyber.Store.set() end, human_author: human_author()}

    assert Retriever.retrieve(query, reader_a) == Retriever.retrieve(query, reader_b)
    assert Retriever.retrieve(query, reader_b) == Retriever.retrieve(query, reader_store)

    # the determinism clause: byte-identical re-fire of the same store read
    assert Retriever.retrieve(query, reader_store) == Retriever.retrieve(query, reader_store)
  end
end
