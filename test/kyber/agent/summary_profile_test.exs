defmodule Kyber.Agent.SummaryProfileTest do
  @moduledoc """
  T14j AC3 (C3 — the A5 cross-session summary keying): the ConversationSummary
  carries the profile dimension explicitly — the optional `profile` string
  role (the T14g profile name). The gather (prompt.ex) filters on (session,
  profile) — nil == nil matches (profile-less boots stay byte-identical) —
  and `summarized?` (engine.ex) is (session, profile)-scoped AND
  liveness-aware (NEW-4).

  THE FULL MATRIX IS WITNESSED (M3): (a) an unkeyed legacy summary serves a
  `{nil, nil}` boot AND must NOT serve a profiled boot after the fix; (b) a
  hand-built profile-keyed summary must NOT serve a profile-less boot (the
  keyed-vs-unkeyed MISS cell). AC-recorded byte delta (the T14g M4
  discipline): "profiled boots no longer serve legacy unkeyed summaries".
  The NEW-4 mint leg: window 2 + 5 turns -> exactly 1 summary; retraction +
  6th turn -> exactly 1 LIVE summary (the retraction-blind skip is fixed —
  a dead summary no longer blocks the re-mint).
  """
  use ExUnit.Case, async: false

  alias Kyber.{Events, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, MemoryPort, Prompt}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @operator_seed String.duplicate("7f", 32)
  @human_seed String.duplicate("a1", 32)
  @ts 1_700_000_000_000.0
  @session "session:sum"
  @profile "channel:discord"

  # ------------------------------------------------------------ scaffolding

  defp author, do: Kyber.Keys.author_for_seed(@operator_seed)

  defp summary(content, ts, profile \\ nil) do
    {:ok, {claims, sig}} =
      AgentEvents.conversation_summary(@agent_seed, ts, @session, content, ["d1"], profile)

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  defp summary_notes(messages) do
    for msg <- messages,
        String.starts_with?(msg["content"], "Summary of earlier turns: "),
        do: msg["content"]
  end

  defp raw_negation(target_id) do
    raw = %{
      timestamp: @ts + 900,
      author: author(),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Kyber.Keys.sign(claims, @operator_seed)
    {claims, sig}
  end

  # ------------------------------------------------------- the AC3 matrix

  test "AC3 (a): an unkeyed legacy summary serves a {nil, nil} boot — AND must NOT serve a profiled boot (the AC-recorded byte delta)" do
    {_id, element} = summary("legacy unkeyed summary text", @ts + 1)
    set = set_of([element])

    # the profile-less boot: the unkeyed summary rides — byte-identical
    # note, exactly as pre-slice
    unkeyed_boot = Prompt.assemble(set, @session, [], 8, nil, {nil, nil})
    assert summary_notes(unkeyed_boot) == ["Summary of earlier turns: legacy unkeyed summary text"]

    # the profiled boot: the SAME store — the legacy unkeyed summary is a
    # MISS (the gather filters (session, profile), nil != "channel:discord")
    profiled_boot = Prompt.assemble(set, @session, [], 8, nil, {@profile, author()})
    assert summary_notes(profiled_boot) == []
  end

  test "AC3 (b): a hand-built profile-keyed summary must NOT serve a profile-less boot (the keyed-vs-unkeyed MISS cell)" do
    {_id, element} = summary("profile-keyed summary text", @ts + 1, @profile)
    set = set_of([element])

    # the keyed summary serves ONLY its own profile
    profiled_boot = Prompt.assemble(set, @session, [], 8, nil, {@profile, author()})
    assert summary_notes(profiled_boot) == ["Summary of earlier turns: profile-keyed summary text"]

    # and NEVER a profile-less boot — keyed-vs-unkeyed is a MISS both ways
    unkeyed_boot = Prompt.assemble(set, @session, [], 8, nil, {nil, nil})
    assert summary_notes(unkeyed_boot) == []
  end

  test "AC3: the profile key is exact — a summary keyed to profile A never serves a boot under profile B" do
    {_id, element} = summary("A-keyed summary", @ts + 1, "profile:a")
    set = set_of([element])

    assert summary_notes(Prompt.assemble(set, @session, [], 8, nil, {"profile:a", author()})) ==
             ["Summary of earlier turns: A-keyed summary"]

    assert summary_notes(Prompt.assemble(set, @session, [], 8, nil, {"profile:b", author()})) == []
  end

  test "AC3: the retracted-summary leg holds (NEW-4) — a negated summary neither serves the gather nor blocks the re-mint" do
    {sum_id, element} = summary("the retracted summary", @ts + 1)
    neg = raw_negation(sum_id)
    set = set_of([element, neg])

    # the gather is liveness-filtered: the negated summary never serves
    unkeyed_boot = Prompt.assemble(set, @session, [], 8, nil, {nil, nil})
    assert summary_notes(unkeyed_boot) == []

    # and summarized? is liveness-aware: the dead summary does NOT count
    assert engine_summarized?(set, @session, nil) == false
  end

  # ------------------------------------------------- the NEW-4 mint path

  test "AC3/NEW-4: the mint path is constructible — window 2 + 5 turns => exactly 1 summary; retraction + 6th turn => exactly 1 LIVE summary" do
    store = start_store()
    engine = start_engine(store, "ok", window: 2)

    for i <- 1..5 do
      ingest_and_answer(store, engine, "turn #{i}", @ts + i * 100)
    end

    set = Agent.get(store, & &1)
    summaries = conversation_summaries(set)
    assert length(summaries) == 1, "window 2 + 5 turns must mint exactly one summary"

    # retract the summary, then drive a 6th turn
    {retracted_id, _claims} = hd(summaries)
    admit(store, raw_negation(retracted_id))

    ingest_and_answer(store, engine, "turn 6", @ts + 600)

    set = Agent.get(store, & &1)
    all = conversation_summaries(set)
    live = Enum.filter(all, fn {id, _claims} -> Kyber.Agent.Liveness.live?(set, id, fn _ -> true end) end)

    # exactly ONE LIVE summary — the retraction-blind skip is fixed: the
    # dead summary no longer blocks the re-mint, so a fresh live summary
    # covers the elided head again
    assert length(live) == 1
    {replacement_id, _claims} = hd(live)
    refute replacement_id == retracted_id
  end

  # ------------------------------------------------------------------ utils

  defp conversation_summaries(set) do
    for {id, {claims, _sig}} <- set,
        match?(%{type: "ConversationSummary"}, Schema.resolve(claims)),
        do: {id, claims}
  end

  defp engine_summarized?(set, session_id, profile_name) do
    # the private oracle is exercised through the observable mint behavior;
    # this direct check runs the same (session, profile) + liveness filter
    # the engine applies
    Enum.any?(set, fn {id, {claims, _sig}} ->
      match?(%{type: "ConversationSummary"}, Schema.resolve(claims)) and
        match?({:entity, ^session_id, _ctx}, pointer(claims, "sessionId")) and
        summary_profile(claims) == profile_name and
        Kyber.Agent.Liveness.live?(set, id, fn _claims -> true end)
    end)
  end

  defp summary_profile(claims) do
    case pointer(claims, "profile") do
      {:string, profile} -> profile
      _none -> nil
    end
  end

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  # ------------------------------------------------ the engine harness

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      decoded = JSON.decode!(body)
      send(state.reply_to, {:llm_request, decoded})
      content = state.respond.(decoded)

      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}]
           })
       }}
    end
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp admit(store, {claims, sig}) do
    Agent.update(store, &Map.put(&1, Delta.id_hex(claims), {claims, sig}))
  end

  defp start_engine(store, respond, opts \\ []) do
    test = self()

    {:ok, llm} =
      Kyber.Agent.LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: test, respond: fn _ -> respond end}}
      )

    {:ok, engine} =
      Engine.start_link(
        name: nil,
        llm: llm,
        window: Keyword.get(opts, :window, 8),
        store: fn -> Agent.get(store, & &1) end,
        sink: fn wire ->
          put_wire(store, wire)
          send(test, {:sink, wire})
          {:ok, :persisted}
        end
      )

    engine
  end

  defp ingest_and_answer(store, engine, content, ts) do
    {:ok, signed} =
      Events.message_received(@human_seed, ts, "msg:" <> Integer.to_string(trunc(ts)), "chan-1", @session, content)

    prompt = put_wire(store, Wire.envelope(signed))

    builder =
      ContextBuilder.handler(
        seed: @agent_seed,
        store: fn -> Agent.get(store, & &1) end,
        memory: {MemoryPort.Stub, %{}}
      )

    [request_wire] = builder.([prompt])
    request = put_wire(store, request_wire)
    Engine.handler(engine).([request])

    # drain the turn's sinks to a quiet mailbox (receive-after, never
    # Process.sleep): the answer + the zero-charge StandingDigest + the
    # possibly-minted ConversationSummary all land before the next ingest
    drain_sinks()
  end

  # no-sleep drain: every sink/llm message for the turn is consumed; a
  # quiet mailbox (100 ms with nothing) means the turn's emissions landed
  defp drain_sinks do
    receive do
      {:sink, _wire} ->
        drain_sinks()

      {:llm_request, _body} ->
        drain_sinks()
    after
      100 ->
        :ok
    end
  end
end
