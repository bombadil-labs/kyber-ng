defmodule Kyber.Agent.Projection do
  @moduledoc """
  The exchange lens (T11b AC8): a pure reading of a delta set that renders
  one prompt's chain as prompt + final response with the tool steps
  available — collapsed and expanded are VIEWS of the same store, never a
  special store path. Pointer-walk only: prompt → `InferenceRequested`
  (promptRef) → `ToolCall`s (requestRef) → `ToolResult`s (call) →
  `ResponseDelta` (requestRef).
  """

  alias Kyber.Schema

  @type step :: %{
          tool: String.t(),
          args: String.t(),
          result: String.t() | nil,
          status: String.t() | nil
        }
  @type exchange :: %{
          prompt: String.t(),
          response: String.t() | nil,
          steps: [step()]
        }

  @doc """
  Project one exchange out of the set by its prompt delta id. An in-flight
  chain answers `response: nil` with the steps so far; an unknown prompt or
  a prompt with no request yet is `{:error, :not_found}`.
  """
  @spec exchange(Kyber.DeltaSet.t(), String.t()) :: {:ok, exchange()} | {:error, :not_found}
  def exchange(set, prompt_id) do
    with {prompt_claims, _sig} <- Map.get(set, prompt_id),
         {:string, prompt_text} <- pointer(prompt_claims, "content"),
         {:ok, request_id} <- request_for(set, prompt_id) do
      {:ok,
       %{
         prompt: prompt_text,
         response: response_for(set, request_id),
         steps: steps_for(set, request_id)
       }}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Render an exchange: `:collapsed` hides the tool steps, `:expanded` shows them."
  @spec render(exchange(), :collapsed | :expanded) :: [String.t()]
  def render(exchange, :collapsed) do
    ["user: " <> exchange.prompt] ++ response_line(exchange)
  end

  def render(exchange, :expanded) do
    ["user: " <> exchange.prompt] ++
      Enum.map(exchange.steps, fn step ->
        "tool #{step.tool}(#{step.args}) -> #{step.result || "…"} [#{step.status || "in flight"}]"
      end) ++ response_line(exchange)
  end

  defp response_line(%{response: nil}), do: []
  defp response_line(%{response: text}), do: ["agent: " <> text]

  # ------------------------------------------------------------ pointer-walk

  defp request_for(set, prompt_id) do
    set
    |> typed_where("InferenceRequested", fn typed ->
      match?({:delta, ^prompt_id, _ctx}, typed.promptRef)
    end)
    |> case do
      [{id, _typed} | _rest] -> {:ok, id}
      [] -> :error
    end
  end

  defp response_for(set, request_id) do
    set
    |> typed_where("ResponseDelta", fn typed ->
      match?({:delta, ^request_id, _ctx}, typed.requestRef)
    end)
    |> case do
      [{_id, typed} | _rest] -> typed.content
      [] -> nil
    end
  end

  defp steps_for(set, request_id) do
    set
    |> typed_where("ToolCall", fn typed ->
      match?({:delta, ^request_id, _ctx}, typed.requestRef)
    end)
    |> Enum.map(fn {call_id, call} ->
      {:entity, tool_id, _ctx} = call.tool

      {result, status} =
        set
        |> typed_where("ToolResult", fn typed ->
          match?({:delta, ^call_id, _ctx}, typed.call)
        end)
        |> case do
          [{_id, typed} | _rest] -> {typed.result, typed.status}
          [] -> {nil, nil}
        end

      %{tool: tool_id, args: call.args, result: result, status: status}
    end)
  end

  # every delta of a declared type matching the filter, oldest first — the
  # bounded projection walk stays deterministic under map ordering
  defp typed_where(set, type, filter) do
    for {id, {claims, _sig}} <-
          Enum.sort_by(set, fn {_id, {c, _s}} -> {c.timestamp, _id = 0} end),
        %{type: ^type} = typed <- [Schema.resolve(claims)],
        filter.(typed),
        do: {id, typed}
  end

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
