defmodule Kyber.Agent.ToolExecutor do
  @moduledoc """
  The executor leg of the tool chain (T11b AC8): a PURE gather handler on
  role `"tool"` that fires on `ToolCall` deltas (declared type checked —
  `ToolInvoked` shares the kind marker and must not fire it) and returns one
  `ToolResult` wire per call, pointer-linked to it.

  Determinism (the AC3 posture): the result claims the CALL's timestamp, so
  a crash-window re-fire of the same call with the same registry produces
  the byte-identical result and dedupes at the sink.

  The registry is `%{tool_id => (args -> result)}`; this slice ships a stub
  `tool:echo`. An unknown tool or a raising tool yields a `ToolResult` with
  a non-`"ok"` status — the chain always completes, the failure is recorded,
  never repaired.
  """

  alias Kyber.{Gather, Schema, Wire}
  alias Kyber.Agent.Events

  @doc "The stub registry: `tool:echo` answers its args."
  @spec stub_tools() :: %{String.t() => (String.t() -> String.t())}
  def stub_tools, do: %{"tool:echo" => fn args -> args end}

  @doc """
  OpenAI function specs for the registry (native tool calling, B's posture):
  the model sees a sanitized name (`tool_echo`), the registry keeps the
  entity id (`tool:echo`); `tool_key/1` maps back. Each spec takes one
  `args` string parameter.
  """
  @spec tool_specs(%{optional(String.t()) => term()}) :: [map()]
  def tool_specs(registry \\ stub_tools()) do
    for {key, _fun} <- registry do
      %{
        "type" => "function",
        "function" => %{
          "name" => tool_name(key),
          "description" => "Runs #{key} with its arguments and returns the result.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"args" => %{"type" => "string"}},
            "required" => ["args"]
          }
        }
      }
    end
  end

  @doc "Registry key -> OpenAI tool name (the colon is not a valid function name)."
  @spec tool_name(String.t()) :: String.t()
  def tool_name(key), do: String.replace(key, ":", "_")

  @doc "OpenAI tool name -> registry key."
  @spec tool_key(String.t()) :: String.t()
  def tool_key(name), do: String.replace(name, "_", ":")

  @doc """
  The gather handler closure. Options: `:seed` (required), `:tools`
  (the registry, default `stub_tools/0`).
  """
  @spec handler(keyword()) :: Gather.handler()
  def handler(opts) do
    seed = Keyword.fetch!(opts, :seed)
    tools = Keyword.get(opts, :tools, stub_tools())

    fn view -> Enum.flat_map(view, &execute(&1, seed, tools)) end
  end

  defp execute(%{id: call_id, claims: claims}, seed, tools) do
    case Schema.resolve(claims) do
      %{type: "ToolCall", tool: {:entity, tool_id, _ctx}, args: args} ->
        {result, status} = run(tools, tool_id, args)

        case Events.tool_result(seed, claims.timestamp, call_id, result, status) do
          {:ok, signed} -> [Wire.envelope(signed)]
          {:error, _reason} -> []
        end

      _not_a_tool_call ->
        []
    end
  end

  defp run(tools, tool_id, args) do
    case Map.fetch(tools, tool_id) do
      {:ok, fun} ->
        try do
          {fun.(args), "ok"}
        rescue
          e -> {Exception.message(e), "error"}
        end

      :error ->
        {"unknown tool " <> tool_id, "unknown_tool"}
    end
  end
end
