defmodule Kyber.Agent.SkillLensTest do
  @moduledoc """
  T14f AC3 — the skill lens: a call-less content surface in `Prompt.assemble`
  (M3 — re-homed from ContextBuilder), FAIL-CLOSED from birth (D6/N2):
  ungoverned AND forked epochs contribute NO skills, and NO GateDecision is
  minted (the lens is prompt assembly, not a gate). The query is
  PROMPT-RELATIVE — the request's own promptRef text (the engine supplies
  it), NEVER the conversation tail (a resumed request would match the wrong
  turn). Matching: exact-name substring tier (case-sensitive — L2) FIRST,
  then `Assoc.digests` overlap over the views' names/descriptions (never
  the raw streams); rank `{-shared_digest_count, name}` (M1 — total,
  deterministic; ties are the norm). Cap: 4 skills AND 8192 RENDERED note
  bytes, SKIP-AND-CONTINUE (M4 — a ranked skill that would blow the byte
  bound is omitted entirely, never truncated; smaller later skills may
  still fit). Skill notes ride between summary_notes and elision, rendered
  `"Skill: <name>\\n<description>\\n<body>"`. The fail-open asymmetry is
  pinned (L8): memory notes at `:none` are INCLUDED (legacy debt) while
  skill notes at `:none` are EXCLUDED — the two arms never unify.
  """
  use ExUnit.Case, async: false

  alias Kyber.Agent.{Events, Prompt}
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @human_seed String.duplicate("a1", 32)
  @ts 1_700_000_000_000.0
  @session "session:s1"

  # ------------------------------------------------------------ scaffolding

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

  defp turn(content, ts) do
    {:ok, {claims, sig}} =
      Kyber.Events.message_received(@human_seed, ts, "msg:" <> Integer.to_string(trunc(ts)),
        "channel:test", @session, content)

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp memory(entity, content, ts) do
    {:ok, {claims, sig}} = Events.memory_entity(@agent_seed, ts, entity, content, [])
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp summary(content, ts) do
    {:ok, {claims, sig}} =
      Events.conversation_summary(@agent_seed, ts, @session, content, [])

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  defp notes(messages), do: Enum.map(messages, & &1["content"])

  defp skill_notes(messages) do
    for msg <- messages,
        String.starts_with?(msg["content"], "Skill: "),
        do: msg["content"]
  end

  # ---------------------------------------------------------------- AC3

  test "AC3 positive: exact-name tier and digest tier both ride — note format pinned, ranked, capped" do
    {e_id, e} = epoch(["greet", "checkout", "escalate", "billing"])
    {_g_id, g} = skill("greet", "Greet a new member", "say hello")
    {_c_id, c} = skill("checkout", "Checkout the cart", "run the flow")
    {_x_id, x} = skill("escalate", "escalate incidents to the oncall rotation", "page the oncall")
    {_b_id, b} = skill("billing", "billing statements", "print the invoice")
    {_t_id, t} =
      turn("please greet the new member, run the checkout flow — oncall rotation is needed", @ts)

    set = set_of([e, g, c, x, b, t])

    prompt_text = "please greet the new member, run the checkout flow — oncall rotation is needed"
    messages = Prompt.assemble(set, @session, [], 8, prompt_text)

    skill_notes = skill_notes(messages)

    # "greet" and "checkout" ride by EXACT-NAME substring (case-sensitive);
    # "escalate" rides by the DIGEST tier (shared oncall/rotation digests);
    # "billing" is irrelevant — it does NOT ride
    assert length(skill_notes) == 3
    assert Enum.any?(skill_notes, &(&1 == "Skill: greet\nGreet a new member\nsay hello"))
    assert Enum.any?(skill_notes, &(&1 == "Skill: checkout\nCheckout the cart\nrun the flow"))

    assert Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: escalate\n"))
    refute Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: billing"))

    # exact-name tier ranks FIRST: greet (exact) before escalate (digest)
    names = Enum.map(skill_notes, &String.split(&1, "\n") |> hd() |> String.trim_leading("Skill: "))
    assert hd(names) == "greet"
  end

  test "AC3 negative: irrelevant skills don't ride; no skill matches, no skill notes" do
    {e_id, e} = epoch(["billing"])
    {_b_id, b} = skill("billing", "billing statements", "print the invoice")
    {_t_id, t} = turn("please greet the new member", @ts)
    set = set_of([e, b, t])

    messages = Prompt.assemble(set, @session, [], 8, "please greet the new member")
    assert skill_notes(messages) == []
  end

  test "AC3 fail-closed: ungoverned AND forked epochs contribute NO skills (the lens never unifies with the memory gather)" do
    {_g_id, g} = skill("greet", "Greet a new member", "say hello")
    {_t_id, t} = turn("please greet the new member", @ts)
    set = set_of([g, t])

    # ungoverned
    assert skill_notes(Prompt.assemble(set, @session, [], 8, "please greet the new member")) == []

    # forked: two live skill epochs
    {e1_id, e1} = epoch(["greet"])
    {e2_id, e2} = epoch(["greet"], ts: @ts + 1)
    forked = set_of([e1, e2, g, t])
    assert skill_notes(Prompt.assemble(forked, @session, [], 8, "please greet the new member")) == []
  end

  test "L8: the fail-open asymmetry — memory notes at :none are INCLUDED, skill notes at :none are EXCLUDED" do
    {_g_id, g} = skill("greet", "Greet a new member", "say hello")
    {m_id, m} = memory("e1", "the cap is a lens", @ts)
    {_t_id, t} = turn("please greet the new member", @ts)
    set = set_of([g, m, t])

    messages = Prompt.assemble(set, @session, [m_id], 8, "please greet the new member")
    contents = notes(messages)

    # memory note rides (the legacy fail-open gather), skill note does not
    assert Enum.any?(contents, &(&1 == "Memory: the cap is a lens"))
    assert skill_notes(messages) == []
  end

  test "AC3 epoch-filtered: a matching skill outside the allowlist never rides" do
    {e_id, e} = epoch(["greet"])
    {_c_id, c} = skill("checkout", "Checkout the cart", "run the flow")
    {_t_id, t} = turn("run the checkout flow", @ts)
    set = set_of([e, c, t])

    messages = Prompt.assemble(set, @session, [], 8, "run the checkout flow")
    assert skill_notes(messages) == []
  end

  test "L2: the exact-name tier is case-sensitive — a mis-cased mention falls through to the digest tier (intended)" do
    {e_id, e} = epoch(["Greet", "Abc"])
    # "Greet" mis-cased (lowercase mention): no exact match — the exact-name
    # tier is case-sensitive (L2) — but the digest tier downcases (assoc.ex)
    # and "greet" rides through it
    {_g_id, g} = skill("Greet", "Greet a new member", "say hello")
    # "Abc" is 3 bytes — under the 4-byte digest floor; the mis-cased mention
    # falls through BOTH tiers and does not ride
    {_a_id, a} = skill("Abc", "x", "y")
    {_t_id, t} = turn("please greet now, run the abc flow", @ts)
    set = set_of([e, g, a, t])

    messages = Prompt.assemble(set, @session, [], 8, "please greet now, run the abc flow")
    skill_notes = skill_notes(messages)

    assert Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: Greet\n"))
    refute Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: Abc"))
  end

  test "M1: rank is {-shared, name} — digest-tier order by shared count DESC, ties on the name" do
    {e_id, e} = epoch(["carts", "oncall"])
    # "carts" shares 1 digest with the prompt; "oncall" shares 2
    {_c_id, c} = skill("carts", "carts and carts", "x")
    {_o_id, o} = skill("oncall", "oncall rotation oncall", "y")
    {_t_id, t} = turn("oncall rotation and carts are needed", @ts)
    set = set_of([e, c, o, t])

    messages = Prompt.assemble(set, @session, [], 8, "oncall rotation and carts are needed")
    names = Enum.map(skill_notes(messages), fn note -> String.split(note, "\n") |> hd() end)

    assert names == ["Skill: oncall", "Skill: carts"]
  end

  test "M4: the byte cap is 8192 RENDERED note bytes, skip-and-continue — a too-big skill is omitted, a smaller LATER skill still fits, never truncated" do
    {e_id, e} = epoch(["alpha", "beta", "gamma"])
    big_body = String.duplicate("a", 5_000)
    {_a_id, a} = skill("alpha", "x", big_body)
    {_b_id, b} = skill("beta", "x", String.duplicate("b", 4_000))
    {_c_id, c} = skill("gamma", "x", String.duplicate("c", 1_000))
    {_t_id, t} = turn("alpha beta gamma", @ts)
    set = set_of([e, a, b, c, t])

    messages = Prompt.assemble(set, @session, [], 8, "alpha beta gamma")
    skill_notes = skill_notes(messages)

    # alpha (~5008B) fits; beta would blow 8192 -> SKIPPED; gamma (~1008B)
    # still fits — skip-and-continue, never truncate
    assert Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: alpha\n"))
    refute Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: beta\n"))
    assert Enum.any?(skill_notes, &String.starts_with?(&1, "Skill: gamma\n"))

    # every note is whole — the byte bound is a SELECTION bound, never a truncation
    assert Enum.any?(skill_notes, &String.ends_with?(&1, String.duplicate("a", 5_000)))
    assert Enum.any?(skill_notes, &String.ends_with?(&1, String.duplicate("c", 1_000)))
    Enum.each(skill_notes, fn note -> assert byte_size(note) <= 8_192 end)
  end

  test "M4: the skill cap is 4 — the fifth ranked skill never rides" do
    # the names ride ABOVE the T14j N=4 floor (sub-4 names are lens-inert by
    # construction — the count-cap witness must not trip the floor)
    {e_id, e} = epoch(["skill1", "skill2", "skill3", "skill4", "skill5"])
    pairs =
      for n <- 1..5 do
        {_id, pair} = skill("skill#{n}", "x", "y")
        pair
      end

    {_t_id, t} = turn("skill1 skill2 skill3 skill4 skill5", @ts)
    set = set_of([e | pairs] ++ [t])

    messages = Prompt.assemble(set, @session, [], 8, "skill1 skill2 skill3 skill4 skill5")
    assert length(skill_notes(messages)) == 4
  end

  test "M3: the query is PROMPT-RELATIVE — the supplied prompt text drives the match, never the conversation tail" do
    {e_id, e} = epoch(["alpha", "beta"])
    {_a_id, a} = skill("alpha", "x", "y")
    {_b_id, b} = skill("beta", "x", "y")
    # the conversation tail mentions beta — but the request's own prompt
    # text is "alpha": only alpha rides
    {_t_id, t} = turn("beta beta beta", @ts)
    set = set_of([e, a, b, t])

    messages = Prompt.assemble(set, @session, [], 8, "alpha")
    names = Enum.map(skill_notes(messages), fn note -> String.split(note, "\n") |> hd() end)
    assert names == ["Skill: alpha"]
  end

  test "M3/M4: the note slot is pinned — system, memory_notes, summary_notes, skill_notes, elision, turns" do
    {e_id, e} = epoch(["greet"])
    {_g_id, g} = skill("greet", "Greet a new member", "say hello")
    {m_id, m} = memory("e1", "a memory note", @ts)
    {_s_id, s} = summary("an earlier summary", @ts)
    {_t1_id, t1} = turn("earlier turn", @ts - 2)
    {_t2_id, t2} = turn("please greet the new member", @ts)
    set = set_of([e, g, m, s, t1, t2])

    messages = Prompt.assemble(set, @session, [m_id], 8, "please greet the new member")
    contents = notes(messages)

    assert hd(contents) == Prompt.system_prompt()

    # the pinned order: system -> memory -> summary -> skill -> elision -> turns
    memory_at = Enum.find_index(contents, &(&1 == "Memory: a memory note"))
    summary_at = Enum.find_index(contents, &(&1 == "Summary of earlier turns: an earlier summary"))
    skill_at = Enum.find_index(contents, &(&1 == "Skill: greet\nGreet a new member\nsay hello"))
    turn1_at = Enum.find_index(contents, &(&1 == "earlier turn"))
    turn2_at = Enum.find_index(contents, &(&1 == "please greet the new member"))

    assert memory_at < summary_at
    assert summary_at < skill_at
    assert skill_at < turn1_at
    assert turn1_at < turn2_at
  end
end
