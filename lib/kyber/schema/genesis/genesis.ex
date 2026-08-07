defmodule Kyber.Schema.Genesis do
  @moduledoc """
  The genesis schema deltas — committed data (T11a). The vocabulary is pinned
  HERE: the hyperschema plus the schemas saturating the lifecycle and the T10
  infra events, plus the entity-resolution hyperschemas. Each entry below is
  the claims form of a real rhizomatic delta: signed at compile time with the
  well-known genesis seed (Ed25519 is deterministic, so the content ids and
  signatures are reproducible), content addressed by the witness, and
  admissible through the one door (`Kyber.Store.verify/1`) like any other
  delta.

  Schema deltas use the substrate's normative envelope vocabulary
  (rhizomatic SPEC-3 §5): `rhizomatic.hyperschema.name`/`defines`/`alg`/`term`
  pointers, where `term` is the hex of canonical CBOR (the shape algebra is
  kyber's T11a `alg` 0.0 — the substrate's evaluator has not landed in
  Elixir; the ENVELOPE is the substrate's form). Hyperschema terms carry the
  entity-resolution reading (`schema` + `root`).

  The genesis seed is a public constant: authority for these schemas comes
  from being compiled into the release and admitted at genesis, not from key
  secrecy. Evolution is retraction-plus-new-issue (a later schema delta
  `retracts` a genesis issue and re-defines the type), never a migration —
  the store only learns; the compiled set is a lens.

  Primitives ride, composites point: `prompt_text`, `content`, `channel`,
  tool `args` are small facts of the act and travel as strings; conversation
  context, memory, and causality travel as entity/delta references only. No
  schema here gives any delta a role that could embed the conversation
  history — and validation is closed, so the prohibition is structural.
  """

  alias Kyber.Schema.Compiler
  alias Kyber.{Keys, Wire}
  alias Rhizomatic.{Cbor, Delta}

  @genesis_seed String.duplicate("6b", 32)
  @genesis_ts 1_785_974_400_000.0
  @alg 0.0

  # {type name, [requires: [{role, kind}], many: [...], optional: [...]]}
  # Role names follow the T11 contract's literal AC2 vocabulary where AC2
  # names them (sessionId, conversationRef, memoryPointers, promptRef,
  # requestRef, channel as a riding string); infra roles mirror the real
  # emitters (Kyber.Events) — drift-proofed by test.
  @defs [
    # The hyperschema: schema deltas are themselves instances of `Schema`.
    {"Schema",
     requires: [
       {"rhizomatic.hyperschema.name", "string"},
       {"rhizomatic.hyperschema.defines", "entity"},
       {"rhizomatic.hyperschema.alg", "number"},
       {"rhizomatic.hyperschema.term", "string"}
     ],
     optional: [{"retracts", "delta"}]},

    # The lifecycle.
    {"Session", requires: [{"channel", "string"}], optional: [{"title", "string"}]},
    {"SubmittedPrompt",
     requires: [{"channel", "string"}, {"prompt_text", "string"}, {"sessionId", "entity"}]},
    {"InferenceRequested",
     requires: [
       {"model", "string"},
       {"sessionId", "entity"},
       {"conversationRef", "delta"},
       {"promptRef", "delta"}
     ],
     many: [{"memoryPointers", "delta"}]},
    {"ResponseDelta",
     requires: [{"requestRef", "delta"}, {"index", "number"}, {"content", "string"}],
     many: [{"memoryUsed", "delta"}]},
    {"ToolCall", requires: [{"tool", "entity"}, {"args", "string"}, {"requestRef", "delta"}]},
    {"ToolResult",
     requires: [{"call", "delta"}, {"result", "string"}], optional: [{"status", "string"}]},
    {"ConversationSummary",
     requires: [{"sessionId", "entity"}, {"content", "string"}], many: [{"covers", "delta"}]},
    {"MemoryEntity",
     requires: [{"entity", "entity"}, {"content", "string"}], many: [{"source", "delta"}]},
    {"MemoryEdited",
     requires: [{"edits", "delta"}, {"content", "string"}], optional: [{"reason", "string"}]},

    # The T10 infra events (spec/01-events.md §2), named into the vocabulary.
    {"MessageReceived",
     requires: [
       {"received", "entity"},
       {"at", "entity"},
       {"by", "entity"},
       {"content", "string"},
       {"session", "entity"}
     ]},
    {"PromptAnnotated", requires: [{"annotates", "delta"}, {"notes", "string"}]},
    {"LlmResponse",
     requires: [{"responds", "delta"}, {"content", "string"}, {"usage", "entity"}]},
    {"MessageSent",
     requires: [{"sent", "entity"}, {"via", "entity"}, {"content", "string"}],
     optional: [{"caused_by", "delta"}]},
    {"ToolInvoked",
     requires: [
       {"tool", "entity"},
       {"args", "string"},
       {"result", "string"},
       {"during", "delta"}
     ]}
  ]

  # {name, schema, root} — the entity-resolution readings (spine 2 bridge).
  @hyperschemas [
    {"Session", "Session", "session"},
    {"MemoryEntity", "MemoryEntity", "memory"}
  ]

  author = Keys.author_for_seed(@genesis_seed)

  term_hex = fn term -> Base.encode16(Cbor.encode(term), case: :lower) end

  schema_term = fn name, groups ->
    fields =
      for group <- [:requires, :optional, :many],
          {role, kind} <- Keyword.get(groups, group, []) do
        {:map,
         [
           {{:tstr, "name"}, {:tstr, role}},
           {{:tstr, "kind"}, {:tstr, kind}},
           {{:tstr, "required"}, {:bool, group == :requires}},
           {{:tstr, "repeat"}, {:bool, group == :many}}
         ]}
      end

    {:map,
     [
       {{:tstr, "kind"}, {:tstr, "schema"}},
       {{:tstr, "name"}, {:tstr, name}},
       {{:tstr, "version"}, {:float, 1.0}},
       {{:tstr, "fields"}, {:arr, fields}}
     ]}
  end

  hyperschema_term = fn name, schema, root ->
    {:map,
     [
       {{:tstr, "kind"}, {:tstr, "hyperschema"}},
       {{:tstr, "name"}, {:tstr, name}},
       {{:tstr, "version"}, {:float, 1.0}},
       {{:tstr, "schema"}, {:tstr, schema}},
       {{:tstr, "root"}, {:tstr, root}}
     ]}
  end

  envelope_pointers = fn name, term_hex ->
    [
      %{role: "type", target: {:entity, "Schema", "instances"}},
      %{role: "rhizomatic.hyperschema.name", target: {:string, name}},
      %{role: "rhizomatic.hyperschema.defines", target: {:entity, name, "schema"}},
      %{role: "rhizomatic.hyperschema.alg", target: {:number, @alg}},
      %{role: "rhizomatic.hyperschema.term", target: {:string, term_hex}}
    ]
  end

  signed_schema =
    for {name, groups} <- @defs do
      claims = %{
        timestamp: @genesis_ts,
        author: author,
        pointers: envelope_pointers.(name, term_hex.(schema_term.(name, groups)))
      }

      {:ok, sig} = Keys.sign(claims, @genesis_seed)
      {claims, sig}
    end

  signed_hyperschema =
    for {name, schema, root} <- @hyperschemas do
      claims = %{
        timestamp: @genesis_ts,
        author: author,
        pointers: envelope_pointers.(name, term_hex.(hyperschema_term.(name, schema, root)))
      }

      {:ok, sig} = Keys.sign(claims, @genesis_seed)
      {claims, sig}
    end

  compiled_schemas =
    Map.new(signed_schema, fn {claims, _sig} ->
      {:ok, {:schema, spec}} = Compiler.compile(claims, Delta.id_hex(claims))
      {spec.name, spec}
    end)

  compiled_hyperschemas =
    Map.new(signed_hyperschema, fn {claims, _sig} ->
      {:ok, {:hyperschema, hs}} = Compiler.compile(claims, Delta.id_hex(claims))
      {hs.name, hs}
    end)

  compiled = %{schemas: compiled_schemas, hyperschemas: compiled_hyperschemas}

  # Self-check at compile time: every genesis schema delta validates against
  # the compiled set — the hyperschema admits its own instances.
  for {claims, _sig} <- signed_schema ++ signed_hyperschema do
    {:ok, _} = Compiler.validate(claims, compiled.schemas)
  end

  @deltas Enum.map(signed_schema ++ signed_hyperschema, &Wire.envelope/1)
  @compiled compiled

  @doc "The genesis schema deltas as wire envelopes — admissible through the one door."
  @spec deltas() :: [Kyber.Wire.wire()]
  def deltas, do: @deltas

  @doc "The genesis schema set, compiled: `%{schemas: …, hyperschemas: …}`."
  @spec compiled() :: Compiler.set()
  def compiled, do: @compiled
end

# Codegen: an Elixir struct per genesis type — DERIVED convenience for typed
# access (handlers never spelunk roles by string); the runtime authority stays
# in the store, and an evolved schema simply stops using the stale struct.
for {name, spec} <- Kyber.Schema.Genesis.compiled().schemas do
  fields =
    for {role, %{arity: arity}} <- Enum.sort(spec.fields) do
      {String.to_atom(role), if(arity == :many, do: [], else: nil)}
    end

  defmodule Module.concat(Kyber.Schema, name) do
    @moduledoc """
    Generated struct for the `#{name}` lifecycle type — DERIVED convenience
    (codegen from the genesis schema deltas); the runtime authority stays in
    the store and an evolved schema stops using this stale struct.
    """

    defstruct [:type, :author, :timestamp] ++ fields
  end
end
