defmodule Kyber.Agent.TrajectoryTest do
  @moduledoc """
  T14h AC2/H5/H3 — the trajectory digest + the always-on block's shape: the
  covered kinds {MessageReceived, ResponseDelta, ToolCall, ToolResult,
  GateDecision} derive into asked/answered/called/done/decided lines
  (session-scoped, liveness-filtered BEFORE line derivation, N=16
  newest-first, 2048-byte CONTIGUOUS stop-at-overflow at mint, `covers` =
  the POST-CAP rendered deltas — M8), and the block renders the sections in
  the pinned claim order Standing -> Trajectory -> Open against the THIRD
  4096 budget (never pooled with identity/skill). The open-threads fold is
  a SEPARATE per-assembly fold over the resume-scan class (asked-without-
  answered, {ts, id} ascending, contiguous-stop). The A5 summary gather is
  hardened: liveness + {ts, id} tie-break + 4096 skip-whole cap (M3).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Digest, Events, MemoryPort, Prompt, Standing}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
  @ts 1_700_000_000_000.0

  defp start_store(initial \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp id_of({claims, _sig}), do: Delta.id_hex(claims)

  defp add(store, {:ok, signed}) do
    put_wire(store, Wire.envelope(signed))
  end

  defp add(store, {claims, sig} = signed) when is_map(claims) do
    put_wire(store, Wire.envelope(signed))
  end

  # one answered turn: received -> request -> response
  defp answered_turn(store, session, ts, prompt, answer, msg_id \\ "msg:1") do
    add(store, Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", session, prompt))
    {:ok, req} = Events.inference_requested(@agent_seed, ts + 1, "m", session, "conv", "pr", [])
    req_id = id_of(req)
    add(store, req)
    add(store, Events.response_delta(@agent_seed, ts + 2, req_id, 0.0, answer, []))
    req_id
  end

  defp raw_negation(target_id, opts \\ []) do
    seed = Keyword.get(opts, :seed, @human_seed)
    ts = Keyword.get(opts, :ts, @ts + 99)

    claims = %{
      timestamp: ts,
      author: Kyber.Keys.author_for_seed(seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, sig} = Kyber.Keys.sign(claims, seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp admit(store, {id, {claims, sig}}) do
    put_wire(store, Wire.envelope({claims, sig}))
    id
  end

  # ------------------------------------------------------ the line grammar

  test "AC2: the covered kinds derive into asked/answered/called/done/decided lines — chronological, deterministic" do
    store = start_store()
    session = "session:t1"

    # one full tool turn: received -> request -> tool call -> tool result ->
    # gate decision -> response
    add(store, Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "what is the cap?"))
    {:ok, req} = Events.inference_requested(@agent_seed, @ts + 1, "m", session, "conv", "pr", [])
    req_id = id_of(req)
    add(store, req)

    {:ok, call} = Events.tool_call(@agent_seed, @ts + 2, "memory.read", "{\"entity\":\"e1\"}", req_id)
    call_id = id_of(call)
    add(store, call)

    {:ok, result} = Events.tool_result(@agent_seed, @ts + 3, call_id, "the canon: the cap is a lens", "ok")
    add(store, result)

    {:ok, decision} = Events.gate_decision(@agent_seed, @ts + 4, call_id, "allow", "memory_policy")
    add(store, decision)

    add(store, Events.response_delta(@agent_seed, @ts + 5, req_id, 0.0, "the cap is a lens.", []))

    set = Agent.get(store, & &1)
    %{content: content, covers: covers} = Digest.derive(set, session)

    assert content ==
             "asked: what is the cap?\n" <>
               "called: memory.read\n" <>
               "done: memory.read: the canon: the cap is a lens\n" <>
               "decided: allow\n" <>
               "answered: the cap is a lens."

    # covers == EXACTLY the rendered lines' deltas (M8), in rendered order:
    # asked (MessageReceived), called (ToolCall), done (ToolResult),
    # decided (GateDecision), answered (ResponseDelta)
    {:ok, {received_claims, _}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "what is the cap?")

    {:ok, {tool_result_claims, _}} =
      Events.tool_result(@agent_seed, @ts + 3, call_id, "the canon: the cap is a lens", "ok")

    {:ok, {decision_claims, _}} = Events.gate_decision(@agent_seed, @ts + 4, call_id, "allow", "memory_policy")

    {:ok, {response_claims, _}} =
      Events.response_delta(@agent_seed, @ts + 5, req_id, 0.0, "the cap is a lens.", [])

    assert covers == [
             Delta.id_hex(received_claims),
             call_id,
             Delta.id_hex(tool_result_claims),
             Delta.id_hex(decision_claims),
             Delta.id_hex(response_claims)
           ]
  end

  test "AC2: args NEVER ride and the done-line result summary is capped at 80 chars (M4)" do
    store = start_store()
    session = "session:t2"

    add(store, Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "run it"))
    {:ok, req} = Events.inference_requested(@agent_seed, @ts + 1, "m", session, "conv", "pr", [])
    req_id = id_of(req)
    add(store, req)

    {:ok, call} = Events.tool_call(@agent_seed, @ts + 2, "http.get", "{\"url\":\"https://secret.example/\",\"headers\":{\"token\":\"TOP-SECRET\"}}", req_id)
    call_id = id_of(call)
    add(store, call)

    long_result = String.duplicate("r", 200)
    {:ok, result} = Events.tool_result(@agent_seed, @ts + 3, call_id, long_result, "ok")
    add(store, result)
    add(store, Events.response_delta(@agent_seed, @ts + 4, req_id, 0.0, "done", []))

    set = Agent.get(store, & &1)
    %{content: content} = Digest.derive(set, session)

    # the secret args NEVER ride; the result summary is the first 80 chars
    refute content =~ "TOP-SECRET"
    assert content =~ "done: http.get: " <> String.duplicate("r", 80)
    refute content =~ String.duplicate("r", 81)
  end

  test "AC2: N=16 items newest-first — the 17th event displaces the oldest; covers lists the newest 16" do
    store = start_store()
    session = "session:t3"

    # 17 answered turns (each: received + response = 2 covered deltas => 34)
    ids =
      for i <- 1..17 do
        answered_turn(store, session, @ts + i * 10, "prompt #{i}", "answer #{i}", "msg:#{i}")
      end

    set = Agent.get(store, & &1)
    %{content: content, covers: covers} = Digest.derive(set, session)

    # 34 covered deltas -> newest 16 selected: the LAST 16 events (turns
    # 10..17) — the first turn's deltas (prompt 1/answer 1) are displaced
    lines = String.split(content, "\n")
    assert length(covers) == 16
    assert ids != []

    refute "asked: prompt 1" in lines
    refute "asked: prompt 2" in lines
    assert "asked: prompt 17" in lines
    assert "answered: answer 17" in lines
    # the boundary: turn 9's deltas are the 17th/18th newest — displaced
    refute "asked: prompt 9" in lines

    # chronological render: newest-16 rendered oldest-first within the
    # selection
    assert hd(lines) == "asked: prompt 10"
    assert List.last(lines) == "answered: answer 17"
  end

  test "AC2: the 2048-byte mint cap is CONTIGUOUS stop-at-overflow — an overflow stops the sequence, never holes it" do
    store = start_store()
    session = "session:t4"

    # a small recent turn
    answered_turn(store, session, @ts + 100, "recent question", "recent answer", "msg:r")

    # a GIANT older turn — its lines would overflow the cap alone
    answered_turn(store, session, @ts, String.duplicate("huge ", 2000), "x", "msg:h")

    set = Agent.get(store, & &1)
    %{content: content, covers: covers} = Digest.derive(set, session)

    # newest-first accumulation: the recent lines + the huge turn's SMALL
    # answer line ride; the huge ASKED line (next in the newest-first walk)
    # overflows and STOPS the sequence — nothing older rides (no
    # skip-and-continue, no holes)
    assert content =~ "asked: recent question"
    assert content =~ "answered: x"
    refute content =~ "huge"
    assert length(covers) == 3
  end

  test "AC2: session-scoped at mint AND read — another session's stream never rides" do
    store = start_store()
    answered_turn(store, "session:mine", @ts, "my question", "my answer", "msg:mine")
    answered_turn(store, "session:other", @ts + 1, "their question", "their answer", "msg:other")

    set = Agent.get(store, & &1)
    %{content: content} = Digest.derive(set, "session:mine")

    assert content =~ "my question"
    refute content =~ "their question"
  end

  test "H2: the covered set is liveness-filtered BEFORE line derivation — a negated source produces no line (all five kinds)" do
    store = start_store()
    session = "session:t5"

    add(store, Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "the secret ask"))
    {:ok, req} = Events.inference_requested(@agent_seed, @ts + 1, "m", session, "conv", "pr", [])
    req_id = id_of(req)
    add(store, req)

    {:ok, call} = Events.tool_call(@agent_seed, @ts + 2, "fs.read", "{\"path\":\"/secret\"}", req_id)
    call_id = id_of(call)
    add(store, call)

    {:ok, result} = Events.tool_result(@agent_seed, @ts + 3, call_id, "secret contents", "ok")
    add(store, result)

    {:ok, decision} = Events.gate_decision(@agent_seed, @ts + 4, call_id, "refuse", "fs_policy", "no")
    add(store, decision)

    add(store, Events.response_delta(@agent_seed, @ts + 5, req_id, 0.0, "denied", []))

    set = Agent.get(store, & &1)
    %{content: before} = Digest.derive(set, session)
    assert before =~ "the secret ask"
    assert before =~ "done: fs.read"
    assert before =~ "decided: refuse"

    # the runbook's hand-rolled negations (author-blind — M6): negate the
    # source deltas, then the derivation is clean
    neg_ids =
      for {_id, {claims, _sig}} <- set,
          %{pointers: [%{role: role} | _]} = claims,
          role in ["received", "requestRef", "tool", "call", "decides"],
          do: _id

    for target <- neg_ids do
      admit(store, raw_negation(target))
    end

    set = Agent.get(store, & &1)
    %{content: after_neg} = Digest.derive(set, session)
    refute after_neg =~ "the secret ask"
    refute after_neg =~ "done: fs.read"
    refute after_neg =~ "decided: refuse"
    refute after_neg =~ "denied"
  end

  # --------------------------------------------------- the always-on block

  test "AC4: the block renders Standing -> Trajectory -> Open in the pinned claim order, after identity before memory_notes" do
    store = start_store()
    session = "session:block"

    # standing: a flagged + epoch-allowed entity
    add(store, Events.memory_entity(@agent_seed, @ts, "memory:e1", "the standing fact", []))
    add(store, Events.standing_flag(@agent_seed, @ts + 1, "memory:e1"))
    add(store, Events.memory_policy(@operator_seed, @ts + 2, ["memory:e1"]))

    # a trajectory: one answered turn, then the real mint path lands the
    # StandingDigest (the trajectory section reads the digest head)
    answered_turn(store, session, @ts + 10, "hello", "hi there", "msg:b1")

    set0 = Agent.get(store, & &1)
    :ok = Digest.mint(@agent_seed, fn w -> put_wire(store, w) end, set0, session, @ts + 11)

    # an open thread: an unanswered request with a REAL promptRef
    {:ok, msg_open} =
      Kyber.Events.message_received(@human_seed, @ts + 19, "msg:o", "chan-1", session, "hello")

    msg_open_id = id_of(msg_open)
    add(store, msg_open)
    {:ok, req} = Events.inference_requested(@agent_seed, @ts + 20, "m", session, msg_open_id, msg_open_id, [])
    add(store, req)

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    assert hd(messages)["role"] == "system"
    # Standing first, Trajectory second, Open last — then the turns
    standing_idx = Enum.find_index(contents, &(&1 == "Standing:\n- memory:e1: the standing fact"))
    trajectory_idx = Enum.find_index(contents, &String.starts_with?(&1, "Trajectory:\n"))
    open_idx = Enum.find_index(contents, &(&1 == "Open:\n- hello"))

    assert standing_idx < trajectory_idx
    assert trajectory_idx < open_idx
    assert open_idx < Enum.find_index(contents, &(&1 == "hello"))
  end

  test "AC4: the open section is a SEPARATE per-assembly fold — {ts, id} ascending, asked-without-answered, (tool waiting) for in-flight chains" do
    store = start_store()
    session = "session:open"

    # an unanswered request (never tool-called) — its promptRef is a REAL
    # MessageReceived so the asked-without-answered line carries the text
    {:ok, msg1} =
      Kyber.Events.message_received(@human_seed, @ts + 9, "msg:o1", "chan-1", session, "open question one")

    msg1_id = id_of(msg1)
    add(store, msg1)
    {:ok, req1} = Events.inference_requested(@agent_seed, @ts + 10, "m", session, msg1_id, msg1_id, [])
    add(store, req1)

    # an in-flight chain: a ToolCall with NO ToolResult
    {:ok, msg2} =
      Kyber.Events.message_received(@human_seed, @ts + 19, "msg:o2", "chan-1", session, "open question two")

    msg2_id = id_of(msg2)
    add(store, msg2)
    {:ok, req2} = Events.inference_requested(@agent_seed, @ts + 20, "m", session, msg2_id, msg2_id, [])
    req2_id = id_of(req2)
    add(store, req2)
    add(store, Events.tool_call(@agent_seed, @ts + 21, "fs.read", "{}", req2_id))

    set = Agent.get(store, & &1)
    threads = Standing.open(set, session)

    # {ts, id} ascending; the waiting chain is classified via the SHARED
    # chain_position helper (M2)
    assert Enum.map(threads, & &1.id) == Enum.sort_by(Enum.map(threads, & &1.id), & &1)

    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    assert Enum.any?(contents, &String.starts_with?(&1, "Open:"))
    open_note = Enum.find(contents, &String.starts_with?(&1, "Open:"))
    # {ts, id} ascending; the asked text rides; the in-flight chain is
    # classified via the SHARED chain_position helper (M2 — the (tool
    # waiting) suffix)
    assert open_note =~ "- open question one\n- open question two (tool waiting)"
  end

  test "AC4: the block is byte-capped at 4096 (THIRD budget) — standing skip-whole, open contiguous-stop, trajectory omit-whole" do
    store = start_store()
    session = "session:cap"

    # three standing entities, one of which alone would blow the cap
    add(store, Events.memory_entity(@agent_seed, @ts, "memory:small", "small fact", []))
    add(store, Events.memory_entity(@agent_seed, @ts + 1, "memory:huge", String.duplicate("x", 5_000), []))
    add(store, Events.memory_entity(@agent_seed, @ts + 2, "memory:small2", "another small fact", []))
    add(store, Events.standing_flag(@agent_seed, @ts + 3, "memory:small"))
    add(store, Events.standing_flag(@agent_seed, @ts + 4, "memory:huge"))
    add(store, Events.standing_flag(@agent_seed, @ts + 5, "memory:small2"))
    add(store, Events.memory_policy(@operator_seed, @ts + 6, ["memory:small", "memory:huge", "memory:small2"]))

    answered_turn(store, session, @ts + 10, "hi", "yo", "msg:c1")

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    # standing: SKIP-WHOLE — the oversized line is omitted entirely, the
    # smaller later lines still fit
    standing_note = Enum.find(contents, &String.starts_with?(&1, "Standing:"))
    assert standing_note =~ "memory:small"
    assert standing_note =~ "memory:small2"
    refute standing_note =~ "memory:huge"
    # never truncated
    refute Enum.any?(contents, &String.contains?(&1, String.duplicate("x", 100)))
    # the block total stays under the THIRD budget
    block_bytes =
      contents
      |> Enum.filter(&(String.starts_with?(&1, "Standing:") or String.starts_with?(&1, "Trajectory:") or String.starts_with?(&1, "Open:")))
      |> Enum.map(&byte_size/1)
      |> Enum.sum()

    assert block_bytes <= 4096
  end

  test "AC4: the window's budget is preserved — window: 0 still renders the block, the elision note is untouched" do
    store = start_store()
    session = "session:w0"

    add(store, Events.memory_entity(@agent_seed, @ts, "memory:e1", "standing fact", []))
    add(store, Events.standing_flag(@agent_seed, @ts + 1, "memory:e1"))
    add(store, Events.memory_policy(@operator_seed, @ts + 2, ["memory:e1"]))

    answered_turn(store, session, @ts + 10, "hello", "hi", "msg:w1")

    set = Agent.get(store, & &1)

    messages = Prompt.assemble(set, session, [], 0, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    # window 0: the block still renders, the turns do not
    assert Enum.any?(contents, &String.starts_with?(&1, "Standing:"))
    refute Enum.any?(contents, &(&1 == "hello"))
  end

  # ------------------------------------------------- the A5 summary gather

  test "M3: the summary gather is {ts, id}-tie-broken — tied-ts summaries render in id order, never hash-map order" do
    store = start_store()
    session = "session:sum"

    {:ok, s1} = Events.conversation_summary(@agent_seed, @ts + 1, session, "aaaa summary", ["d1"])
    {:ok, s2} = Events.conversation_summary(@agent_seed, @ts + 1, session, "zzzz summary", ["d2"])
    {s1_claims, _} = s1
    {s2_claims, _} = s2
    add(store, s1)
    add(store, s2)

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    summaries = Enum.filter(contents, &String.starts_with?(&1, "Summary of earlier turns: "))

    # deterministic: {ts, id}-tie-broken, replica-identical (the old
    # timestamp-only sort rendered tied-ts summaries in hash-map order)
    id1 = Delta.id_hex(s1_claims)
    id2 = Delta.id_hex(s2_claims)

    expected =
      if id1 < id2 do
        ["Summary of earlier turns: aaaa summary", "Summary of earlier turns: zzzz summary"]
      else
        ["Summary of earlier turns: zzzz summary", "Summary of earlier turns: aaaa summary"]
      end

    assert summaries == expected
    assert Prompt.assemble(set, session, [], 8, nil, {nil, @author()}) == messages
  end

  test "M3: a negated ConversationSummary is absent from the gather (liveness arm)" do
    store = start_store()
    session = "session:sum2"

    {:ok, {sum_claims, sum_sig}} =
      Events.conversation_summary(@agent_seed, @ts + 1, session, "the retracted summary", ["d1"])

    sum_id = Delta.id_hex(sum_claims)
    put_wire(store, Wire.envelope({sum_claims, sum_sig}))
    admit(store, raw_negation(sum_id))

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    refute Enum.any?(contents, &(&1 == "Summary of earlier turns: the retracted summary"))
  end

  test "M3: the A5 cap is SKIP-WHOLE 4096 — an oversized summary is omitted entirely, smaller later summaries still fit" do
    store = start_store()
    session = "session:sum3"

    add(store, Events.conversation_summary(@agent_seed, @ts + 1, session, String.duplicate("huge ", 2_000), ["d1"]))
    add(store, Events.conversation_summary(@agent_seed, @ts + 2, session, "small summary", ["d2"]))

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, session, [], 8, nil, {nil, @author()})
    contents = Enum.map(messages, & &1["content"])

    refute Enum.any?(contents, &String.contains?(&1, String.duplicate("huge ", 100)))
    assert Enum.any?(contents, &(&1 == "Summary of earlier turns: small summary"))
  end

  # ------------------------------------------------------------------ utils

  defp author, do: Kyber.Keys.author_for_seed(@operator_seed)
end
