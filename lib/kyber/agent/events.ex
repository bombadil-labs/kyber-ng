defmodule Kyber.Agent.Events do
  @moduledoc """
  Claim templates for the T11b inference chain, mirroring `Kyber.Events`:
  each builder returns `{:ok, {claims, sig_hex}}`, validated at the boundary
  and signed by the agent's key. Every template matches its genesis schema
  (`Kyber.Schema.Genesis`) exactly — closed validation is what structurally
  keeps conversation text out of these deltas (composites point).

  Pointer order is the template (array order is part of the content
  address): the KIND MARKER — the role the gather routes on — rides first,
  the T11a `type` declaration rides last. Kind markers: `InferenceRequested`
  routes as `"promptRef"`, `ResponseDelta` as `"requestRef"`, `ToolCall` as
  `"tool"`, `ToolResult` as `"call"`, `ConversationSummary` as
  `"sessionId"`, `MemoryEntity` as `"entity"`, `MemoryEdited` as `"edits"`.
  """

  alias Rhizomatic.Delta
  alias Kyber.Keys

  @type signed :: {Delta.claims(), String.t()}

  @doc """
  `InferenceRequested` — the context builder asks for a model turn. THIN by
  schema: the prompt, the conversation head, and the memories are pointers;
  the engine rehydrates content from the store.
  """
  @spec inference_requested(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [
            String.t()
          ]
        ) :: {:ok, signed()} | {:error, term()}
  def inference_requested(seed, ts, model, session_id, conversation_ref, prompt_id, memory_ids) do
    build(seed, ts, "InferenceRequested", [
      %{role: "promptRef", target: {:delta, prompt_id, "requested"}},
      %{role: "model", target: {:string, model}},
      %{role: "sessionId", target: {:entity, session_id, "inferences"}},
      %{role: "conversationRef", target: {:delta, conversation_ref, "context_of"}},
      Enum.map(memory_ids, &%{role: "memoryPointers", target: {:delta, &1, "informed"}})
    ])
  end

  @doc "`ResponseDelta` — the model's answer, pointer-linked to its request."
  @spec response_delta(String.t(), number(), String.t(), number(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def response_delta(seed, ts, request_id, index, content, memory_used) do
    build(seed, ts, "ResponseDelta", [
      %{role: "requestRef", target: {:delta, request_id, "answered"}},
      %{role: "index", target: {:number, 1.0 * index}},
      %{role: "content", target: {:string, content}},
      Enum.map(memory_used, &%{role: "memoryUsed", target: {:delta, &1, "informed"}})
    ])
  end

  @doc "`ToolCall` — the model wants a tool run mid-turn, linked to its request."
  @spec tool_call(String.t(), number(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def tool_call(seed, ts, tool_id, args, request_id) do
    build(seed, ts, "ToolCall", [
      %{role: "tool", target: {:entity, tool_id, "calls"}},
      %{role: "args", target: {:string, args}},
      %{role: "requestRef", target: {:delta, request_id, "tool_use"}}
    ])
  end

  @doc "`ToolResult` — the executor's answer, pointer-linked to its call."
  @spec tool_result(String.t(), number(), String.t(), String.t(), String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def tool_result(seed, ts, call_id, result, status \\ nil) do
    build(seed, ts, "ToolResult", [
      %{role: "call", target: {:delta, call_id, "result"}},
      %{role: "result", target: {:string, result}},
      if(status, do: [%{role: "status", target: {:string, status}}], else: [])
    ])
  end

  @doc "`ConversationSummary` — a lens artifact covering elided turns."
  @spec conversation_summary(String.t(), number(), String.t(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def conversation_summary(seed, ts, session_id, content, covers) do
    build(seed, ts, "ConversationSummary", [
      %{role: "sessionId", target: {:entity, session_id, "summaries"}},
      %{role: "content", target: {:string, content}},
      Enum.map(covers, &%{role: "covers", target: {:delta, &1, "summarized"}})
    ])
  end

  @doc "`MemoryEntity` — a remembered fact about an entity (T11c's container will emit these)."
  @spec memory_entity(String.t(), number(), String.t(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def memory_entity(seed, ts, entity_id, content, sources) do
    build(seed, ts, "MemoryEntity", [
      %{role: "entity", target: {:entity, entity_id, "memories"}},
      %{role: "content", target: {:string, content}},
      Enum.map(sources, &%{role: "source", target: {:delta, &1, "remembered"}})
    ])
  end

  @doc """
  `MemoryEdited` — a memory's canon superseded by an edit (T11c's watcher
  emits these for out-of-band human edits). The genesis schema is closed:
  the OLD content rides by pointer (`edits` targets the superseded canon
  delta — composites point), the NEW content rides inline, and the source
  attestation (`human_edit`) rides the schema's `reason` role.
  """
  @spec memory_edited(String.t(), number(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def memory_edited(seed, ts, edited_id, content, reason \\ "human_edit") do
    build(seed, ts, "MemoryEdited", [
      %{role: "edits", target: {:delta, edited_id, "edited"}},
      %{role: "content", target: {:string, content}},
      %{role: "reason", target: {:string, reason}}
    ])
  end

  # ---------------------------------------------------------------- helpers

  defp build(seed, ts, type, pointers) do
    with {:ok, ts} <- timestamp(ts) do
      claims = %{
        timestamp: ts,
        author: Keys.author_for_seed(seed),
        pointers:
          List.flatten(pointers) ++ [%{role: "type", target: {:entity, type, "instances"}}]
      }

      with {:ok, claims} <- Delta.validate(claims),
           {:ok, sig_hex} <- Keys.sign(claims, seed) do
        {:ok, {claims, sig_hex}}
      end
    end
  end

  # D14, mirroring Kyber.Events: floats only past the builder
  defp timestamp(ts) when is_integer(ts) do
    f = 1.0 * ts
    if trunc(f) == ts, do: {:ok, f}, else: {:error, {:not_exact_f64, :timestamp}}
  end

  defp timestamp(ts) when is_float(ts), do: {:ok, ts}
  defp timestamp(_), do: {:error, :timestamp_not_a_number}
end
