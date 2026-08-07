defmodule Kyber.SchemaTest do
  use ExUnit.Case, async: true

  alias Kyber.{Events, Keys, Schema, Store, Wire}
  alias Kyber.Schema.Genesis

  @seed String.duplicate("a1", 32)
  @ts 1_785_974_400_123.0
  @prompt_text "what did we decide about the cap?"

  # -- Fixtures: real rhizomatic claims — role-tagged pointers, no dialect ----

  defp claims(type, pointers) do
    %{
      timestamp: @ts,
      author: Keys.author_for_seed(@seed),
      pointers: [%{role: "type", target: {:entity, type, "instances"}} | pointers]
    }
  end

  defp ptr(role, target), do: %{role: role, target: target}
  defp id64(byte), do: String.duplicate(byte, 32)

  defp submitted_prompt do
    claims("SubmittedPrompt", [
      ptr("channel", {:string, "cli"}),
      ptr("prompt_text", {:string, @prompt_text}),
      ptr("sessionId", {:entity, "session:2f7c", "prompts"})
    ])
  end

  defp inference_requested do
    claims("InferenceRequested", [
      ptr("model", {:string, "claude-fable-5"}),
      ptr("sessionId", {:entity, "session:2f7c", "inferences"}),
      ptr("conversationRef", {:delta, id64("31"), "context_of"}),
      ptr("promptRef", {:delta, id64("77"), "requested"}),
      ptr("memoryPointers", {:delta, id64("11"), "informed"}),
      ptr("memoryPointers", {:delta, id64("22"), "informed"})
    ])
  end

  defp lifecycle_fixtures do
    [
      claims("Session", [ptr("channel", {:string, "cli"})]),
      submitted_prompt(),
      inference_requested(),
      claims("ResponseDelta", [
        ptr("requestRef", {:delta, id64("31"), "answer"}),
        ptr("index", {:number, 0.0}),
        ptr("content", {:string, "we decided the cap is a lens"}),
        ptr("memoryUsed", {:delta, id64("11"), "informed"})
      ]),
      claims("ToolCall", [
        ptr("tool", {:entity, "tool:grep", "invocations"}),
        ptr("args", {:string, ~s({"q":"cap"})}),
        ptr("requestRef", {:delta, id64("c0"), "tool_use"})
      ]),
      claims("ToolResult", [
        ptr("call", {:delta, id64("c1"), "result"}),
        ptr("result", {:string, "3 matches"})
      ]),
      claims("ConversationSummary", [
        ptr("sessionId", {:entity, "session:2f7c", "summaries"}),
        ptr("content", {:string, "we discussed the cap"}),
        ptr("covers", {:delta, id64("d1"), "summarized"}),
        ptr("covers", {:delta, id64("d2"), "summarized"})
      ]),
      claims("MemoryEntity", [
        ptr("entity", {:entity, "topic:cap", "memories"}),
        ptr("content", {:string, "the cap is a lens"}),
        ptr("source", {:delta, id64("e1"), "remembered"})
      ]),
      claims("MemoryEdited", [
        ptr("edits", {:delta, id64("f1"), "edited"}),
        ptr("content", {:string, "the cap is a lens, never a store property"}),
        ptr("reason", {:string, "precision"})
      ])
    ]
  end

  # -- AC2/AC7: the genesis vocabulary -----------------------------------------

  test "AC2: every lifecycle delta validates against its genesis schema and resolves typed" do
    for c <- lifecycle_fixtures() do
      assert {:ok, typed} = Schema.validate(c)
      assert typed.type == c.pointers |> hd() |> Map.fetch!(:target) |> elem(1)
      assert typed.author == c.author
    end
  end

  test "AC2: InferenceRequested carries pointers, never the conversation text (composites point)" do
    {:ok, typed} = Schema.validate(inference_requested())

    # point kinds stay TAGGED tuples — the witness's idiom, never coerced
    assert typed.conversationRef == {:delta, id64("31"), "context_of"}
    assert typed.promptRef == {:delta, id64("77"), "requested"}

    assert typed.memoryPointers == [
             {:delta, id64("11"), "informed"},
             {:delta, id64("22"), "informed"}
           ]

    # structural: an extra role embedding history is REFUSED (closed validation)
    bad =
      inference_requested()
      |> Map.update!(:pointers, &(&1 ++ [ptr("history", {:string, "the whole conversation"})]))

    assert {:error, {:unknown_role, "history"}} = Schema.validate(bad)
  end

  test "AC7: a malformed delta is refused — missing required role" do
    bad =
      claims("InferenceRequested", [
        ptr("model", {:string, "kimi-k3"}),
        ptr("sessionId", {:entity, "session:2f7c", "inferences"}),
        ptr("conversationRef", {:delta, id64("31"), "context_of"})
      ])

    assert {:error, {:missing_role, "promptRef"}} = Schema.validate(bad)
  end

  test "AC7: a malformed delta is refused — wrong kind (reject, never repair)" do
    bad =
      claims("SubmittedPrompt", [
        ptr("channel", {:string, "cli"}),
        ptr("prompt_text", {:entity, "topic:cap", "prompts"}),
        ptr("sessionId", {:entity, "session:2f7c", "prompts"})
      ])

    assert {:error, {:bad_target_kind, "prompt_text", :string}} = Schema.validate(bad)
  end

  test "AC7: duplicate one-arity role refused" do
    bad =
      claims("Session", [
        ptr("channel", {:string, "cli"}),
        ptr("channel", {:string, "discord"})
      ])

    assert {:error, {:duplicate_role, "channel"}} = Schema.validate(bad)
  end

  test "AC7: unknown and undeclared types are admitted raw — never saturating typed handlers" do
    assert {:ok, :raw} = Schema.validate(claims("NoSuchType", [ptr("x", {:string, "y"})]))

    assert {:ok, :raw} =
             Schema.validate(%{
               timestamp: @ts,
               author: Keys.author_for_seed(@seed),
               pointers: [ptr("content", {:string, "hi"})]
             })
  end

  test "AC7: malformed type declaration is refused" do
    bad = %{
      timestamp: @ts,
      author: Keys.author_for_seed(@seed),
      pointers: [%{role: "type", target: {:string, "SubmittedPrompt"}}]
    }

    assert {:error, :bad_type_declaration} = Schema.validate(bad)
  end

  # -- Genesis round-trip + self-host ------------------------------------------

  test "genesis round-trip: committed wire data reproduces the build byte-for-byte" do
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

  test "self-host: every genesis schema delta verifies through the door and validates against the set" do
    for wire <- Genesis.deltas() do
      assert {:ok, %{id: _id, claims: claims}} = Store.verify(wire)
      assert {:ok, _typed} = Schema.validate(claims)
    end
  end

  # -- Drift-proofing: the real emitters against the infra schemas (B's posture)

  test "cross-validation: the infra schemas mirror the real emitters' roles (drift-proof)" do
    # T11b wired the type declaration into the emitters (carried addition 1),
    # so the drift-proof property is: each infra schema's field set is EXACTLY
    # the emitter's role set minus the declaration, and the emitted claims
    # validate typed as-is.
    for {emitter, type, args} <- [
          {&Events.message_received/6, "MessageReceived",
           {@seed, @ts, "msg:1", "channel:cli", "session:1", "hello"}},
          {&Events.message_sent/6, "MessageSent",
           {@seed, @ts, id64("77"), "msg:2", "channel:cli", "hi back"}},
          {&Events.prompt_annotated/4, "PromptAnnotated", {@seed, @ts, id64("77"), "a note"}},
          {&Events.llm_response/4, "LlmResponse", {@seed, @ts, id64("77"), "the answer"}},
          {&Events.tool_exec/6, "ToolInvoked",
           {@seed, @ts, id64("77"), "tool:grep", "{}", "3 matches"}}
        ] do
      {:ok, {claims, _sig}} = apply(emitter, Tuple.to_list(args))

      roles =
        claims.pointers |> Enum.map(& &1.role) |> Enum.reject(&(&1 == "type")) |> Enum.sort()

      schema_fields = Genesis.compiled().schemas[type].fields |> Map.keys() |> Enum.sort()
      assert roles == schema_fields, "schema #{type} drifted from its emitter"

      # the emitter declares its own type (T11b) — the output validates typed
      assert {:ok, typed} = Schema.validate(claims)
      assert typed.type == type
    end
  end

  # -- Live evolution (retraction-plus-new-issue) + the replay matrix ----------

  defp genesis_id(type) do
    Genesis.deltas()
    |> Enum.find(fn wire ->
      {:ok, %{claims: claims}} = Store.verify(wire)

      match?(%{pointers: [%{target: {:entity, ^type, "schema"}} | _]}, claims) or
        Enum.any?(
          claims.pointers,
          &match?(%{role: "rhizomatic.hyperschema.defines", target: {:entity, ^type, _}}, &1)
        )
    end)
    |> then(fn wire ->
      {:ok, %{id: id}} = Store.verify(wire)
      id
    end)
  end

  # Build a v2 schema delta for a type: same envelope as genesis, one extra
  # optional role, retracts the given issue.
  defp schema_v2_wire(type, retracts_id, extra_optional \\ {"title", "string"}) do
    author = Keys.author_for_seed(@seed)

    term =
      {:map,
       [
         {{:tstr, "kind"}, {:tstr, "schema"}},
         {{:tstr, "name"}, {:tstr, type}},
         {{:tstr, "version"}, {:float, 2.0}},
         {{:tstr, "fields"},
          {:arr,
           [
             {:map,
              [
                {{:tstr, "name"}, {:tstr, "channel"}},
                {{:tstr, "kind"}, {:tstr, "string"}},
                {{:tstr, "required"}, {:bool, true}},
                {{:tstr, "repeat"}, {:bool, false}}
              ]},
             {:map,
              [
                {{:tstr, "name"}, {:tstr, "prompt_text"}},
                {{:tstr, "kind"}, {:tstr, "string"}},
                {{:tstr, "required"}, {:bool, true}},
                {{:tstr, "repeat"}, {:bool, false}}
              ]},
             {:map,
              [
                {{:tstr, "name"}, {:tstr, "sessionId"}},
                {{:tstr, "kind"}, {:tstr, "entity"}},
                {{:tstr, "required"}, {:bool, true}},
                {{:tstr, "repeat"}, {:bool, false}}
              ]},
             {:map,
              [
                {{:tstr, "name"}, {:tstr, elem(extra_optional, 0)}},
                {{:tstr, "kind"}, {:tstr, elem(extra_optional, 1)}},
                {{:tstr, "required"}, {:bool, false}},
                {{:tstr, "repeat"}, {:bool, false}}
              ]}
           ]}}
       ]}

    term_hex = Base.encode16(Rhizomatic.Cbor.encode(term), case: :lower)

    claims = %{
      timestamp: @ts,
      author: author,
      pointers: [
        %{role: "type", target: {:entity, "Schema", "instances"}},
        %{role: "rhizomatic.hyperschema.name", target: {:string, type}},
        %{role: "rhizomatic.hyperschema.defines", target: {:entity, type, "schema"}},
        %{role: "rhizomatic.hyperschema.alg", target: {:number, 0.0}},
        %{role: "rhizomatic.hyperschema.term", target: {:string, term_hex}},
        %{role: "retracts", target: {:delta, retracts_id, "retracted"}}
      ]
    }

    {:ok, sig} = Keys.sign(claims, @seed)
    Wire.envelope({claims, sig})
  end

  defp negation_wire(target_id) do
    claims = %{
      timestamp: @ts,
      author: Keys.author_for_seed(@seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, sig} = Keys.sign(claims, @seed)
    Wire.envelope({claims, sig})
  end

  setup do
    start_supervised!(Kyber.Store)
    start_supervised!(Kyber.Schema)
    :ok
  end

  test "live evolution: a new issue must retract the current one" do
    v1 = genesis_id("SubmittedPrompt")
    v2 = schema_v2_wire("SubmittedPrompt", v1)

    assert :ok = Schema.observe(v2)

    # the evolved schema admits a claim with the new optional role...
    with_title =
      claims("SubmittedPrompt", [
        ptr("channel", {:string, "cli"}),
        ptr("prompt_text", {:string, @prompt_text}),
        ptr("sessionId", {:entity, "session:2f7c", "prompts"}),
        ptr("title", {:string, "the cap question"})
      ])

    assert {:ok, typed} = Schema.validate(with_title)
    assert typed.title == "the cap question"

    # ...and the pre-evolution fixture still validates (fields are a superset)
    assert {:ok, _} = Schema.validate(submitted_prompt())

    # a replacement that does NOT retract the live issue is refused
    {:ok, %{id: v2_id}} = Store.verify(v2)
    rogue = schema_v2_wire("SubmittedPrompt", id64("ff"))
    assert {:error, {:must_retract_current, ^v2_id}} = Schema.observe(rogue)
  end

  test "replay matrix: re-ingest and late-arriving older versions are no-ops" do
    v1 = genesis_id("SubmittedPrompt")

    # same delta re-observed: no-op, :ok
    genesis_wire =
      Genesis.deltas()
      |> Enum.find(fn w ->
        {:ok, %{id: id}} = Store.verify(w)
        id == v1
      end)

    assert :ok = Schema.observe(genesis_wire)

    # v2 supersedes v1
    v2 = schema_v2_wire("SubmittedPrompt", v1)
    assert :ok = Schema.observe(v2)

    # the late-arriving v1 (genesis) is a no-op, not an error
    assert :ok = Schema.observe(genesis_wire)

    # retracting the SUPERSEDED id does not kill the live entry
    assert :ok = Schema.observe(negation_wire(v1))
    assert {:ok, _typed} = Schema.validate(submitted_prompt())

    # retracting the live id removes the entry — admitted raw thereafter
    {:ok, %{id: v2_id}} = Store.verify(v2)
    assert :ok = Schema.observe(negation_wire(v2_id))
    assert {:ok, :raw} = Schema.validate(submitted_prompt())
    refute "SubmittedPrompt" in Schema.known_types()
  end

  # -- Entity resolution (spine 2 bridge) ---------------------------------------

  test "resolve_entity: the bounded gather over a delta set, with the reading hyperschema" do
    c1 =
      claims("SubmittedPrompt", [
        ptr("channel", {:string, "cli"}),
        ptr("prompt_text", {:string, "a"}),
        ptr("sessionId", {:entity, "session:abc", "prompts"})
      ])

    c2 =
      claims("InferenceRequested", [
        ptr("model", {:string, "x"}),
        ptr("sessionId", {:entity, "session:abc", "inferences"}),
        ptr("conversationRef", {:delta, id64("31"), "c"}),
        ptr("promptRef", {:delta, id64("77"), "r"})
      ])

    {:ok, sig1} = Keys.sign(c1, @seed)
    {:ok, sig2} = Keys.sign(c2, @seed)

    delta_set = %{id64("aa") => {c1, sig1}, id64("bb") => {c2, sig2}}

    assert {:ok, view} = Schema.resolve_entity("session:abc", delta_set)
    assert view.id == "session:abc"
    assert view.reading == "Session"
    assert view.props["sessionId"] == [id64("aa"), id64("bb")]

    # a root with no reading hyperschema resolves with reading: nil
    assert {:ok, view} = Schema.resolve_entity("topic:cap", delta_set)
    assert view.reading == nil
  end
end
