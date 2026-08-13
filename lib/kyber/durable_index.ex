defmodule Kyber.DurableIndex do
  @moduledoc """
  T16 (F4) — the pure, side-effect-free dedup index projection over the
  append-only store.

  The store only learns, so this index is APPEND-ONLY: `add/3` folds one
  admitted delta into the derived maps and nothing is ever deleted. It is
  deliberately a *projection* — the same pure fold can back the in-process
  store index (F1) or any spawned `IndexServer` hyperview (F3) fed by the
  subscribe seam (F2).

  What it tracks (the T15c triple-send contract, two-hop):

    - `messages :: %{content => %{id => ts}}` — every `MessageReceived`,
      keyed by its content pointer, so a re-send can be matched in O(1)
      (content-derived identity: same content => same dedup key).
    - `inf_by_prompt :: %{msg_id => [inf_id]}` — the first hop: every
      `InferenceRequested` whose `promptRef` points at a message. A message
      can have several (failed-then-retried turns).
    - `resp_by_request :: %{inf_id => true}` — the second hop: every
      `ResponseDelta` whose `requestRef` points at an inference.

  `answered?(index, msg_id)` = the message has an inference that got a
  response — the two-hop bridge that makes the round-4 retry-safe semantics
  exact (a failed-then-retried attempt still counts as answered).

  Claim shapes: atom-keyed `%{timestamp: float, author: ..., pointers: [...]}`
  with pointer targets as tuples (`{:entity, id, ctx}` / `{:delta, id, ctx}` /
  `{:string, content}`). See `Kyber.Agent.Events` / `Kyber.Events`.
  """

  alias Kyber.DeltaSet

  @type t :: %__MODULE__{
          messages: %{optional(String.t()) => %{optional(String.t()) => float()}},
          inf_by_prompt: %{optional(String.t()) => [String.t()]},
          resp_by_request: %{optional(String.t()) => true}
        }

  defstruct messages: %{}, inf_by_prompt: %{}, resp_by_request: %{}

  @doc "The empty index."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Fold ONE admitted delta into the index. `delta` is the
  `%{id: id_hex, claims: claims}` shape from `Store.verify/1`. Only the
  three dedup-relevant kinds contribute; everything else is ignored (the
  index is bounded — AC4).
  """
  @spec add(t(), %{id: String.t(), claims: map()}) :: t()
  def add(index, %{id: id, claims: claims}) do
    case kind(claims) do
      "MessageReceived" -> add_message(index, id, claims)
      "InferenceRequested" -> add_inference(index, id, claims)
      "ResponseDelta" -> add_response(index, id, claims)
      _other -> index
    end
  end

  @doc "Rebuild the index from a delta set in one pass (boot replay)."
  @spec build(DeltaSet.t()) :: t()
  def build(set) do
    Enum.reduce(set, new(), fn {id, {claims, _sig}}, index -> add(index, %{id: id, claims: claims}) end)
  end

  @doc """
  Is `content` an open (recent, unanswered) duplicate? Recent = a
  `MessageReceived` with that content inside the caller's window; unanswered
  = the two-hop bridge says no inference for it was answered.
  """
  @spec open_duplicate?(t(), String.t(), number(), number()) :: boolean()
  def open_duplicate?(index, content, now, window_ms) do
    Enum.any?(messages_for(index, content), fn {msg_id, ts} ->
      recent?(ts, now, window_ms) and not answered?(index, msg_id)
    end)
  end

  @doc "True iff the MessageReceived has an answered inference (two-hop)."
  @spec answered?(t(), String.t()) :: boolean()
  def answered?(index, msg_id) do
    index.inf_by_prompt
    |> Map.get(msg_id, [])
    |> Enum.any?(&Map.has_key?(index.resp_by_request, &1))
  end

  @doc "The number of tracked messages (boundedness observable for tests)."
  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{messages: messages}) do
    messages |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum()
  end

  # ------------------------------------------------------------- folding

  defp kind(claims) do
    Enum.find_value(claims.pointers, fn
      %{role: "type", target: {:entity, kind, _ctx}} -> kind
      _other -> nil
    end)
  end

  defp add_message(index, id, claims) do
    case content_of(claims) do
      nil ->
        index

      content ->
        # messages :: %{content => %{msg_id => ts}} — a second message with
        # identical content is a re-send the dedup window handles; both are
        # kept (append-only). Map.update/4 already returns the whole outer
        # map — do NOT re-wrap it under content (the T16 build bug: a
        # double-nested %{content => %{content => ...}} never matched).
        messages =
          Map.update(index.messages, content, %{id => ts(claims)}, fn inner ->
            Map.put(inner, id, ts(claims))
          end)

        %{index | messages: messages}
    end
  end

  defp add_inference(index, id, claims) do
    case pointer_target(claims, "promptRef") do
      {:delta, msg_id, _ctx} ->
        %{index | inf_by_prompt: Map.update(index.inf_by_prompt, msg_id, [id], &[id | &1])}

      _other ->
        index
    end
  end

  defp add_response(index, _id, claims) do
    case pointer_target(claims, "requestRef") do
      {:delta, inf_id, _ctx} -> %{index | resp_by_request: Map.put(index.resp_by_request, inf_id, true)}
      _other -> index
    end
  end

  # ------------------------------------------------------------- helpers

  defp messages_for(%__MODULE__{messages: messages}, content), do: Map.get(messages, content, %{})

  defp recent?(ts, now, window_ms) when is_number(ts), do: now - ts <= window_ms
  defp recent?(_ts, _now, _window_ms), do: false

  defp ts(%{timestamp: ts}) when is_number(ts), do: ts
  defp ts(_claims), do: 0.0

  defp content_of(claims) do
    case pointer_target(claims, "content") do
      {:string, content} -> content
      _other -> nil
    end
  end

  # the first pointer with the given role (the kind marker rides first, but
  # role+target matching is order-independent — round-4 finding)
  defp pointer_target(claims, role) do
    Enum.find_value(claims.pointers, fn
      %{role: ^role, target: target} -> target
      _other -> nil
    end)
  end
end
