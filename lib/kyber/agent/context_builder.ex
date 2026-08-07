defmodule Kyber.Agent.ContextBuilder do
  @moduledoc """
  The session-side of the inference chain (T11b): a gather handler on
  `"received"` that turns each human prompt into ONE thin
  `InferenceRequested` delta — the prompt, the conversation head, and the
  memories as POINTERS (primitives ride, composites point; the genesis
  schema's closed validation refuses any role that could carry the
  conversation text).

  Memories come through the `Kyber.Agent.MemoryPort` seam (`{module,
  state}`); the store is read through an injectable thunk (the daemon's
  durable set by default). The emission is DETERMINISTIC: the request claims
  the prompt's timestamp and every pointer is a function of the store below
  the prompt, so a crash-window re-fire is byte-identical and dedupes at the
  sink by content address (AC3).
  """

  alias Kyber.{DurableStore, Gather, Wire}
  alias Kyber.Agent.{Events, MemoryPort}

  @model "kimi-k3"

  @doc """
  The gather handler closure. Options: `:seed` (required), `:memory`
  (`{module, state}`, default the stub), `:store` (a thunk answering the
  delta set), `:model` (default #{inspect(@model)}).
  """
  @spec handler(keyword()) :: Gather.handler()
  def handler(opts) do
    seed = Keyword.fetch!(opts, :seed)
    model = Keyword.get(opts, :model, @model)
    store = Keyword.get(opts, :store, fn -> DurableStore.set() end)
    memory = Keyword.get(opts, :memory, {MemoryPort.Stub, %{}})

    fn view -> Enum.flat_map(view, &request(&1, seed, model, store, memory)) end
  end

  @doc """
  The conversation lens over a delta set (shared with the engine's
  rehydration): the session's `message.received` turns and the
  `ResponseDelta` answers to the session's requests, ordered by
  `{timestamp, id}` — a derived reading, never a store property.
  """
  @spec conversation(Kyber.DeltaSet.t(), String.t()) :: [
          %{id: String.t(), role: String.t(), content: String.t(), timestamp: float()}
        ]
  def conversation(set, session_id) do
    request_ids =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "promptRef",
          points_at?(claims, "sessionId", session_id),
          into: MapSet.new(),
          do: id

    turns =
      Enum.flat_map(set, fn {id, {claims, _sig}} ->
        case kind(claims) do
          "received" ->
            if points_at?(claims, "session", session_id),
              do: turn(id, claims, "user"),
              else: []

          "requestRef" ->
            case pointer(claims, "requestRef") do
              {:delta, request_id, _ctx} ->
                if MapSet.member?(request_ids, request_id),
                  do: turn(id, claims, "assistant"),
                  else: []

              _other ->
                []
            end

          _other ->
            []
        end
      end)

    Enum.sort_by(turns, &{&1.timestamp, &1.id})
  end

  @doc """
  The window lens split (the T11b pin, N=8): `{elided, windowed}` — the
  exact tail split the engine's `build_messages/4` applies, extracted so
  the engine and `Assoc.Saturation` share one N and one split.
  """
  @spec window([map()], non_neg_integer()) :: {[map()], [map()]}
  def window(turns, n \\ 8), do: Enum.split(turns, max(length(turns) - n, 0))

  @doc """
  Normalize a retriever answer to the associative shape (T13): the T11c
  list gains empty channels; the associative map passes through.
  """
  @spec normalize({:ok, [String.t()] | map()}) :: map()
  def normalize({:ok, memory_ids}) when is_list(memory_ids) do
    %{memory_ids: memory_ids, associations: %{seeds: [], resonant: [], divergent: []}}
  end

  def normalize({:ok, %{memory_ids: _ids, associations: _channels} = shaped}), do: shaped

  # ----------------------------------------------------------------- request

  defp request(%{id: prompt_id, claims: claims}, seed, model, store, {retriever, mem_state}) do
    with {:entity, session_id, _ctx} <- pointer(claims, "session"),
         {:string, prompt_text} <- pointer(claims, "content"),
         {:ok, _answer} = retrieved <-
           retriever.retrieve(%{session_id: session_id, prompt: prompt_text}, mem_state),
         %{memory_ids: memory_ids, associations: associations} = normalize(retrieved),
         {:ok, signed} <-
           Events.inference_requested(
             seed,
             claims.timestamp,
             model,
             session_id,
             conversation_ref(store.(), session_id, claims.timestamp, prompt_id),
             prompt_id,
             memory_pointers(memory_ids, associations)
           ) do
      [Wire.envelope(signed)]
    else
      # reject, never repair: a prompt with no session (or a refusing
      # retriever) yields no request rather than an invented one
      _refused -> []
    end
  end

  # precision never truncated, seeds ride the wire, divergent last — the
  # associative tail is ≤ 4+8+2 by construction, so the channel can never
  # drown precision recall
  defp memory_pointers(memory_ids, %{seeds: seeds, resonant: resonant, divergent: divergent}) do
    memory_ids ++
      ((seeds ++ resonant ++ divergent) |> Enum.uniq() |> Enum.reject(&(&1 in memory_ids)))
  end

  # the conversation head: the latest conversation delta STRICTLY BELOW the
  # prompt's timestamp — the persisted answer to this very prompt (a crash
  # window's leftovers) sits above it, so the re-fire stays byte-identical;
  # a session's first prompt grounds on itself
  defp conversation_ref(set, session_id, prompt_ts, prompt_id) do
    set
    |> conversation(session_id)
    |> Enum.filter(&(&1.timestamp < prompt_ts))
    |> List.last()
    |> case do
      %{id: id} -> id
      nil -> prompt_id
    end
  end

  # -------------------------------------------------------------- machinery

  defp turn(id, claims, role) do
    case pointer(claims, "content") do
      {:string, content} -> [%{id: id, role: role, content: content, timestamp: claims.timestamp}]
      _other -> []
    end
  end

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp points_at?(claims, role, entity_id) do
    match?({:entity, ^entity_id, _ctx}, pointer(claims, role))
  end
end
