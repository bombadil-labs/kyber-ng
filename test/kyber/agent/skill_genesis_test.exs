defmodule Kyber.Agent.SkillGenesisTest do
  @moduledoc """
  T14f H5 — genesis evolution is a DELIVERABLE: the SkillSet + SkillRetract
  kinds ride the genesis `@defs`, the committed `genesis.jsonl` is
  REGENERATED (byte-for-byte gated by schema_test.exs:167-183), and the
  `Events.skill_set` / `Events.skill_retract` builders are the house
  emission seam. The fold only sees TYPED deltas — a genesis drift would
  blind it silently (a delta declaring an unknown type is admitted `:raw`
  and never saturates typed handlers), so this file pins the kinds, the
  field shapes, and the door round-trip for skill deltas.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.Events
  alias Kyber.Schema.Genesis
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @ts 1_700_000_000_000.0

  test "H5: the SkillSet and SkillRetract kinds ride the compiled genesis set with the pinned field shapes" do
    schemas = Genesis.compiled().schemas

    # SkillSet: name rides as the `skill` entity aggregate key, description
    # and body are required strings; metadata (JSON string) and source
    # (provenance delta pointer) are optional (D1)
    assert %{fields: skill_set_fields} = schemas["SkillSet"]
    assert skill_set_fields["skill"].kind == :entity
    assert skill_set_fields["skill"].arity == :one
    assert skill_set_fields["description"].kind == :string
    assert skill_set_fields["description"].arity == :one
    assert skill_set_fields["body"].kind == :string
    assert skill_set_fields["body"].arity == :one
    assert skill_set_fields["metadata"].kind == :string
    assert skill_set_fields["metadata"].arity == :maybe
    assert skill_set_fields["source"].kind == :delta
    assert skill_set_fields["source"].arity == :maybe

    # SkillRetract: delta-ID-targeted negation (D4) — the target is a
    # delta pointer, never a name form
    assert %{fields: retract_fields} = schemas["SkillRetract"]
    assert retract_fields["skill"].kind == :entity
    assert retract_fields["negates"].kind == :delta
    assert retract_fields["negates"].arity == :one
  end

  test "H5: a minted SkillSet admits through the door and resolves typed — the fold's input is typed, never raw" do
    {:ok, {claims, sig}} = Events.skill_set(@agent_seed, @ts, "greet", "Greet", "say hello", "{}", "call:1")
    wire = Wire.envelope({claims, sig})

    # the one door (Store.verify) admits it, and typed resolution saturates
    assert {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
    assert %{type: "SkillSet"} = Schema.resolve(claims)
    assert {:ok, %Kyber.Schema.SkillSet{}} = Schema.validate(claims)

    # the generated struct is the house typed shape
    assert %Kyber.Schema.SkillSet{
             skill: {:entity, "greet", "skills"},
             description: "Greet",
             body: "say hello",
             metadata: "{}",
             source: {:delta, "call:1", "triggered"}
           } = Schema.resolve(claims)
  end

  test "H5: a minted SkillRetract admits through the door and resolves typed" do
    {:ok, {target_claims, _sig}} = Events.skill_set(@agent_seed, @ts, "greet", "Greet", "say hello")
    target_id = Delta.id_hex(target_claims)
    {:ok, {claims, sig}} = Events.skill_retract(@agent_seed, @ts + 1, "greet", target_id)
    wire = Wire.envelope({claims, sig})

    assert {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
    assert %Kyber.Schema.SkillRetract{} = Schema.resolve(claims)
    assert Schema.resolve(claims).negates == {:delta, target_id, "retracted"}
  end

  test "H5: the genesis round-trip — committed wire data reproduces the build byte-for-byte (the regenerated genesis.jsonl)" do
    committed =
      "lib/kyber/schema/genesis/wire/genesis.jsonl"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        {:ok, wire} = Wire.decode(line)
        wire
      end)

    built = Genesis.deltas()

    assert Enum.map(built, & &1["id"]) |> Enum.sort() ==
             Enum.map(committed, & &1["id"]) |> Enum.sort()

    assert Enum.sort_by(built, & &1["id"]) == Enum.sort_by(committed, & &1["id"])
  end

  test "H5: the builders are the drift-proof emission seam — emitter roles EXACTLY the schema field set" do
    for {emitter, type, args} <- [
          {&Events.skill_set/7, "SkillSet",
           {@agent_seed, @ts, "greet", "Greet", "say hello", "{}", id64("99")}},
          {&Events.skill_retract/4, "SkillRetract", {@agent_seed, @ts, "greet", id64("99")}}
        ] do
      {:ok, {claims, _sig}} = apply(emitter, Tuple.to_list(args))

      roles =
        claims.pointers |> Enum.map(& &1.role) |> Enum.reject(&(&1 == "type")) |> Enum.sort()

      schema_fields = Genesis.compiled().schemas[type].fields |> Map.keys() |> Enum.sort()
      assert roles == schema_fields, "schema #{type} drifted from its emitter"

      assert {:ok, typed} = Schema.validate(claims)
      assert typed.type == type
    end
  end

  defp id64(hex), do: String.duplicate(hex, 8)
end
