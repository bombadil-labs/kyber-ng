defmodule Kyber.Agent.LensGovernanceTest do
  @moduledoc """
  T14j AC4 (C4 — the N4 lens governance): the lens caps are OPERATOR
  CONSTANTS (compile-time module attributes, changed by code review +
  rebuild; NEVER read from the store — a hostile store must never widen a
  cap). The in-code registry (Prompt's moduledoc) names all FIVE lens caps
  — identity 8192, always-on 4096, summary 4096, skill count 4, skill
  bytes 8192 — and notes the two DISPATCH budgets (the reactor's 32 and
  the window 8) are DELIBERATELY out-of-scope (N3). Behavioral tripwires
  per constant: a byte over the cap is cut at the cap. The disjointness
  leg accounts PER-SECTION bytes (M7): each rendered section's bytes sit
  under ITS OWN cap while all four coexist; a section over its cap is cut
  at ITS cap, never borrowing another section's budget.
  """
  use ExUnit.Case, async: false

  alias Kyber.Agent.{Events, Identity, Prompt}
  alias Kyber.Agent.Memory.Assoc
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @operator_seed String.duplicate("7f", 32)
  @ts 1_700_000_000_000.0
  @session "session:gov"

  # ------------------------------------------------------------ scaffolding

  defp author, do: Kyber.Keys.author_for_seed(@operator_seed)

  defp skill(name, description, body, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    {:ok, {claims, sig}} = Events.skill_set(@agent_seed, ts, name, description, body)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp epoch(allow_names, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    {:ok, {claims, sig}} = Events.skill_policy(@agent_seed, ts, allow_names)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp summary(content, ts) do
    {:ok, {claims, sig}} = Events.conversation_summary(@agent_seed, ts, @session, content, [])
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp identity_set(id, kind, body) do
    {:ok, {claims, sig}} = Events.identity_set(@operator_seed, @ts, id, kind, body)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp memory(entity, content, ts) do
    {:ok, {claims, sig}} = Events.memory_entity(@agent_seed, ts, entity, content, [])
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp standing_flag(entity, ts) do
    {:ok, {claims, sig}} = Events.standing_flag(@agent_seed, ts, entity)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp memory_policy(entities, ts) do
    {:ok, {claims, sig}} = Events.memory_policy(@operator_seed, ts, entities)
    {Delta.id_hex(claims), {claims, sig}}
  end

  # the trajectory_test convention: elements are {claims, sig} pairs — the
  # content-derived id is derived HERE, never pre-wrapped
  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  defp notes(set, prompt_text) do
    Prompt.assemble(set, @session, [], 8, prompt_text, {nil, author()})
  end

  defp section_bytes(messages, prefix) do
    messages
    |> Enum.filter(&String.starts_with?(&1["content"], prefix))
    |> Enum.map(&byte_size(&1["content"]))
    |> Enum.sum()
  end

  # -------------------------------------------------------- the registry

  test "N3: the cap registry moduledoc names all five lens caps and the two dispatch-budget exclusions" do
    {:docs_v1, _anno, _beam_language, _format, module_doc, _metadata, _docs} =
      Code.fetch_docs(Kyber.Agent.Prompt)

    doc = module_doc["en"]

    # the five lens caps — name + value each
    assert doc =~ "identity block: 8192"
    assert doc =~ "always-on block: 4096"
    assert doc =~ "summary notes: 4096"
    assert doc =~ "skill notes: 4 skills"
    assert doc =~ "skill notes: 8192"

    # the two dispatch budgets are DELIBERATELY out-of-scope
    assert doc =~ "DELIBERATELY out-of-scope"
    assert doc =~ "reactor"
    assert doc =~ "32"
    assert doc =~ "window"
    assert doc =~ "8"

    # never read from the store
    assert doc =~ "NEVER read from the store"
  end

  # --------------------------------------------------- per-constant tripwires

  test "identity tripwire: 8192 rendered bytes — a soul over the cap is skipped whole (never truncated); under the cap it rides" do
    {_id, big} = identity_set("identity:soul", "soul", String.duplicate("s", 8_200))
    {_id2, ok} = identity_set("identity:soul", "soul", String.duplicate("s", 8_000))

    # over the cap: the note would blow 8192 -> skipped ENTIRELY, never
    # truncated (skip-and-continue per primitive)
    over = set_of([big])
    assert section_bytes(notes(over, "x"), "Soul: ") == 0
    assert Identity.block(over, author(), nil) == []

    # under the cap: rides, and the identity block's bytes sit under ITS cap
    under = set_of([ok])
    identity_bytes = section_bytes(notes(under, "x"), "Soul: ")
    assert identity_bytes == 8_000 + 6
    assert identity_bytes <= 8192
  end

  test "always-on tripwire: 4096 rendered bytes — a standing line over the cap is skipped whole; under the cap it rides" do
    {_m_id, m} = memory("memory:e1", String.duplicate("f", 4_000), @ts)
    {_f_id, f} = standing_flag("memory:e1", @ts + 1)
    {_p_id, p} = memory_policy(["memory:e1"], @ts + 2)
    base = set_of([m, f, p])

    assert Enum.any?(notes(base, "x"), &(&1["content"] == "Standing:\n- memory:e1: " <> String.duplicate("f", 4_000)))
    always_on_bytes = section_bytes(notes(base, "x"), "Standing:")
    assert always_on_bytes <= 4096

    # over the cap: the line would blow 4096 -> the standing section is
    # absent (skip-whole), never truncated, never borrowing another budget
    {_m2_id, m2} = memory("memory:huge", String.duplicate("x", 5_000), @ts)
    {_f2_id, f2} = standing_flag("memory:huge", @ts + 1)
    {_p2_id, p2} = memory_policy(["memory:huge"], @ts + 2)
    over = set_of([m2, f2, p2])
    assert section_bytes(notes(over, "x"), "Standing:") == 0
  end

  test "summary tripwire: 4096 rendered bytes, SKIP-WHOLE — an oversized summary is omitted, a smaller later one still fits" do
    {_h_id, huge} = summary(String.duplicate("huge ", 2_000), @ts + 1)
    {_s_id, small} = summary("small summary", @ts + 2)
    set = set_of([huge, small])

    messages = notes(set, "x")
    refute section_bytes(messages, "Summary of earlier turns: ") >= 4096
    assert Enum.any?(messages, &(&1["content"] == "Summary of earlier turns: small summary"))
    refute Enum.any?(messages, &String.contains?(&1["content"], String.duplicate("huge ", 100)))
  end

  test "skill count tripwire: 4 skills — the fifth ranked skill never rides" do
    {e_id, e} = epoch(["skill1", "skill2", "skill3", "skill4", "skill5"])
    pairs =
      for n <- 1..5 do
        {_id, pair} = skill("skill#{n}", "x", "y")
        pair
      end

    set = set_of([e | pairs])
    skill_notes =
      for msg <- notes(set, "skill1 skill2 skill3 skill4 skill5"),
          String.starts_with?(msg["content"], "Skill: "),
          do: msg["content"]

    assert length(skill_notes) == 4
  end

  test "skill bytes tripwire: 8192 rendered bytes, skip-and-continue — a too-big skill is omitted, a smaller LATER skill still fits" do
    {_e_id, e} = epoch(["alpha", "beta"])
    {_a_id, a} = skill("alpha", "x", String.duplicate("a", 9_000))
    {_b_id, b} = skill("beta", "y", String.duplicate("c", 1_000))
    set = set_of([e, a, b])

    messages = notes(set, "alpha beta")
    skill_notes =
      for msg <- messages,
          String.starts_with?(msg["content"], "Skill: "),
          do: msg["content"]

    refute Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: alpha"))
    assert Enum.any?(skill_notes, &(&1 == "Skill: beta\ny\n" <> String.duplicate("c", 1_000)))
    Enum.each(skill_notes, fn note -> assert byte_size(note) <= 8192 end)
  end

  # --------------------------------------------- the PER-SECTION disjointness

  test "M7: PER-SECTION bytes — all four sections coexist, each under ITS OWN cap (never pooled)" do
    # identity: a soul near the 8192 identity cap
    {_i_id, i} = identity_set("identity:soul", "soul", String.duplicate("s", 8_000))

    # always-on: a standing entity whose section is near the 4096 cap
    {_m_id, m} = memory("memory:e1", String.duplicate("f", 4_000), @ts)
    {_f_id, f} = standing_flag("memory:e1", @ts + 1)
    {_p_id, p} = memory_policy(["memory:e1"], @ts + 2)

    # summary: a summary near the 4096 cap
    {_u_id, u} = summary(String.duplicate("sum ", 1_000), @ts + 3)

    # skill: a skill note near the 8192 cap
    {_e_id, e} = epoch(["bigskill"])
    {_b_id, b} = skill("bigskill", "d", String.duplicate("b", 8_100))

    set = set_of([i, m, f, p, u, e, b])

    messages = notes(set, "bigskill")

    identity_bytes = section_bytes(messages, "Soul: ")
    always_on_bytes = section_bytes(messages, "Standing:")
    summary_bytes = section_bytes(messages, "Summary of earlier turns: ")
    skill_bytes = section_bytes(messages, "Skill: ")

    # ALL FOUR coexist
    assert identity_bytes > 0
    assert always_on_bytes > 0
    assert summary_bytes > 0
    assert skill_bytes > 0

    # EACH under ITS OWN cap — one total would not prove non-pooling
    assert identity_bytes <= 8192
    assert always_on_bytes <= 4096
    assert summary_bytes <= 4096
    assert skill_bytes <= 8192
  end

  test "M7: a section over ITS cap is cut at ITS cap — never borrowing another section's budget" do
    # identity OVER its cap: the soul note (9000 bytes) would blow 8192 ->
    # skipped entirely — while the always-on / summary / skill sections
    # still render at THEIR caps (the identity overage borrows nothing)
    {_i_id, i} = identity_set("identity:soul", "soul", String.duplicate("s", 9_000))

    {_m_id, m} = memory("memory:e1", String.duplicate("f", 4_000), @ts)
    {_f_id, f} = standing_flag("memory:e1", @ts + 1)
    {_p_id, p} = memory_policy(["memory:e1"], @ts + 2)

    {_u_id, u} = summary(String.duplicate("sum ", 1_000), @ts + 3)

    {_e_id, e} = epoch(["bigskill"])
    {_b_id, b} = skill("bigskill", "d", String.duplicate("b", 8_100))

    set = set_of([i, m, f, p, u, e, b])

    messages = notes(set, "bigskill")

    # the identity section is CUT at its cap (the 9000-byte soul is skipped
    # whole — nothing rides)
    assert section_bytes(messages, "Soul: ") == 0

    # the OTHER sections still ride, each under its own cap
    always_on_bytes = section_bytes(messages, "Standing:")
    summary_bytes = section_bytes(messages, "Summary of earlier turns: ")
    skill_bytes = section_bytes(messages, "Skill: ")
    assert always_on_bytes > 0 and always_on_bytes <= 4096
    assert summary_bytes > 0 and summary_bytes <= 4096
    assert skill_bytes > 0 and skill_bytes <= 8192
  end
end
