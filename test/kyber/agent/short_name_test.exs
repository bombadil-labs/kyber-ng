defmodule Kyber.Agent.ShortNameTest do
  @moduledoc """
  T14j AC4 (C5 — the degenerate-short-name class): the tool boundary
  refuses names under N = 4 BYTES POST-TRIM (`byte_size(String.trim(name))`;
  the assoc.ex ≥4-byte token floor is the derivation anchor — the boundary
  and the tokenizer speak the same units). The STORED name is never
  normalized (M6 — reject-never-repair at the boundary; a padded name
  stored out-of-band stays padded, never rewritten). The lens's exact-name
  tier is the boundary-anchored case-sensitive literal lookaround over the
  `Regex.escape`d name (H1): "foo.bar" matches "see foo.bar here" and NEVER
  "see foo bar here" or "fooXbar" — the escape makes the literal match
  actually literal. Out-of-band sub-floor names are LENS-INERT (the read-
  side twin): `Assoc.digests("hi") == []`, so the exact tier is their only
  path and the floor makes them permanently inert.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Events, Prompt, Skill, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Memory.Assoc
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0
  @session "session:s1"

  # ------------------------------------------------------------ scaffolding

  defp skill_epoch(allow_names, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} = Events.skill_policy(@agent_seed, ts, allow_names, supersedes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp call_delta(tool, args, ts) do
    {:ok, signed} = Events.tool_call(@agent_seed, ts, tool, args, @request_id)
    {:ok, call} = Store.verify(Wire.envelope(signed))
    call
  end

  defp handler_with(set, tools \\ nil) do
    ToolExecutor.handler(
      seed: @agent_seed,
      tools: tools || ToolExecutor.skill_tools(fn -> set end),
      gate: Gate.new(default: :allow),
      store: fn -> set end
    )
  end

  defp resolve_wire(wire) do
    {:ok, delta} = Store.verify(wire)
    Schema.resolve(delta.claims)
  end

  defp absorb(set, wires) do
    Enum.reduce(wires, set, fn wire, s ->
      {:ok, delta} = Store.verify(wire)
      Map.put(s, delta.id, {delta.claims, wire["sig"]})
    end)
  end

  defp set_args(name, description, body) do
    JSON.encode!(%{"name" => name, "description" => description, "body" => body})
  end

  # --------------------------------------------- the N=4 POST-TRIM boundary

  test "M6: the boundary is N = 4 POST-TRIM bytes — \"x\" (1 trimmed byte) and \" x \" (3 raw -> 1 trimmed) are refused, \"abcd\" (4) accepted" do
    {epoch_id, epoch} = skill_epoch(["x", " x ", "abcd", "   "])
    set = %{epoch_id => epoch}
    handler = handler_with(set)

    for name <- ["x", " x "] do
      call = call_delta("skill.set", set_args(name, "d", "b"), @ts + 1)
      assert [gate_wire, result_wire] = handler.([call])
      assert resolve_wire(gate_wire).verdict == "allow"

      result = resolve_wire(result_wire)
      assert result.type == "ToolResult"
      assert result.status == "error"
      assert result.result == "skill name must be at least 4 bytes after trimming"

      # nothing written, the stored name never normalized (reject, never repair)
      set_after = absorb(set, [gate_wire, result_wire])
      refute Enum.any?(set_after, fn {_id, {claims, _sig}} ->
               match?(%{type: "SkillSet"}, Schema.resolve(claims))
             end)
    end

    # "abcd" (4 trimmed bytes) is accepted — the boundary speaks the token
    # floor's units
    call = call_delta("skill.set", set_args("abcd", "d", "b"), @ts + 1)
    assert [gate_wire, skill_wire, result_wire] = handler.([call])
    assert resolve_wire(result_wire).status == "ok"
    assert resolve_wire(skill_wire).type == "SkillSet"
  end

  test "N1 preserved: whitespace-only names keep the pinned refusal string — never the N=4 message" do
    {epoch_id, epoch} = skill_epoch(["   "])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("   ", "d", "b"), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.status == "error"
    assert result.result == "skill name must not be whitespace-only"
  end

  test "M6: a padded name stored OUT-OF-BAND is never silently rewritten — the store keeps the caller's bytes" do
    {:ok, {claims, sig}} = Events.skill_set(@agent_seed, @ts, " hi ", "d", "b")
    {id, {claims, sig}} = {Delta.id_hex(claims), {claims, sig}}

    # the fold answers the STORED name verbatim — reject-never-repair, the
    # boundary refuses at the tool, never by rewriting the store
    assert {:ok, view} = Skill.view(%{id => {claims, sig}}, " hi ")
    assert view.name == " hi "
  end

  # ------------------------------------------------- the escaped lookaround

  test "H1: the exact tier is the ESCAPED boundary-anchored lookaround — \"foo.bar\" matches \"see foo.bar here\" (positive) and NOT \"see foo bar here\" / \"fooXbar\"" do
    # the separator-variant leg is a POSITIVE test: the escape makes the
    # literal match actually literal — dotted names are legal at the door
    {e_id, e} = skill_epoch(["foo.bar"])
    s = skill_store("foo.bar", "d", "b")
    set = Map.merge(%{e_id => e}, s)

    # matches the literal spelling, bounded by non-word boundaries
    assert Enum.any?(notes(set, "see foo.bar here"), &(&1 == "Skill: foo.bar\nd\nb"))

    # never the separator variant, never the glued variant
    refute notes(set, "see foo bar here") != []
    refute notes(set, "the fooXbar build") != []
  end

  test "H1: regex meta-characters are literals — \"v1.2\" not \"v1x2\"; \"ab+cd\" not \"abcd\"; multi-token \"foo bar\" whole-token only" do
    # all names ride ABOVE the N=4 floor (a sub-4 meta-character name would
    # be lens-inert — the floor and the matcher are separate cells)
    {e_id, e} = skill_epoch(["v1.2", "ab+cd", "foo bar"])
    v = skill_store("v1.2", "d", "b")
    a = skill_store("ab+cd", "d", "b")
    f = skill_store("foo bar", "d", "b")
    set = Map.merge(%{e_id => e}, Map.merge(v, Map.merge(a, f)))

    assert Enum.any?(notes(set, "see v1.2 here"), &String.starts_with?(&1, "Skill: v1.2"))
    refute notes(set, "the v1x2 build") != []

    # the unescaped "+" quantifier would make "ab+cd" match "abcd"; the
    # escaped literal does not
    assert Enum.any?(notes(set, "see ab+cd here"), &String.starts_with?(&1, "Skill: ab+cd"))
    refute notes(set, "the abcd build") != []

    # a multi-token name rides whole-token only — never split across a glued word
    assert Enum.any?(notes(set, "see foo bar here"), &String.starts_with?(&1, "Skill: foo bar"))
    refute notes(set, "see foobar here") != []
  end

  test "H1: the boundary classes are [A-Za-z0-9] — a name glued to word characters never matches; standalone matches" do
    {e_id, e} = skill_epoch(["alpha"])
    a = skill_store("alpha", "d", "b")
    set = %{e_id => e} |> Map.merge(a)

    assert Enum.any?(notes(set, "see alpha here"), &String.starts_with?(&1, "Skill: alpha"))
    assert Enum.any?(notes(set, "(alpha)!"), &String.starts_with?(&1, "Skill: alpha"))
    refute notes(set, "seefooalphahere") != []
    refute notes(set, "alphabet") != []
  end

  # ------------------------------------------- the lens-inert out-of-band twin

  test "the lens-inert twin: an out-of-band sub-floor name renders NOTHING — the N=4 floor and the token floor speak the same units" do
    # "hi" rides today's door (it refuses only "") — but it is digest-blind
    # and the exact tier is its only path; the N=4 floor makes it inert
    assert Assoc.digests("hi") == []

    {e_id, e} = skill_epoch(["hi"])
    h = skill_store("hi", "d", "b")
    set = %{e_id => e} |> Map.merge(h)

    # even a prompt that mentions "hi" standalone never renders the note
    assert notes(set, "say hi to the member") == []
    assert notes(set, "hi") == []
  end

  # ------------------------------------------------------------------ utils

  defp skill_store(name, description, body) do
    {:ok, {claims, sig}} = Events.skill_set(@agent_seed, @ts, name, description, body)
    %{Delta.id_hex(claims) => {claims, sig}}
  end

  defp notes(set, prompt_text) do
    set
    |> Prompt.assemble(@session, [], 8, prompt_text, {nil, nil})
    |> Enum.filter(&String.starts_with?(&1["content"], "Skill: "))
    |> Enum.map(& &1["content"])
  end
end
