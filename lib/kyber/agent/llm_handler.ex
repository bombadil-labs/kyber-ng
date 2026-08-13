defmodule Kyber.Agent.LlmHandler do
  @moduledoc """
  The real model as a gather handler (T11b AC1): an OpenAI-compatible client
  against Moonshot (base `https://api.moonshot.ai/v1`, model `kimi-k3`),
  stdlib `:httpc`/`:ssl` only, implementing the gather contract
  `(delta[]) -> delta[]` — conversation deltas in, ONE signed `llm.response`
  wire out, carrying the model's real, non-deterministic content.

  The HTTP client is the `Kyber.Agent.HttpClient` behaviour, injected at
  construction (`{module, state}`); the API key is an explicit constructor
  argument — the handler never reads the environment itself (the CLI reads
  `MOONSHOT_API_KEY` for the live run; tests pass a fake key to a stub).

  Refusals over repairs: a non-200 answer, a malformed body, a transport
  failure, or a prompt-less context each surface as a tagged error — never a
  fabricated response claim.
  """

  alias Kyber.{Events, Keys, Wire}

  @base_url "https://api.moonshot.ai/v1"
  @model "kimi-k3"
  @system_prompt "You are kyber, an agent living in a claims substrate. " <>
                   "Answer the user's latest message, grounded in the conversation so far."

  @enforce_keys [:seed, :author, :api_key, :http]
  defstruct [
    :seed,
    :author,
    :api_key,
    :http,
    base_url: @base_url,
    model: @model,
    system_prompt: @system_prompt
  ]

  @type t :: %__MODULE__{
          seed: String.t(),
          author: String.t(),
          api_key: String.t(),
          http: {module(), term()},
          base_url: String.t(),
          model: String.t(),
          system_prompt: String.t()
        }

  @doc """
  Build a handler. Options: `:seed` (agent signing seed, 32-byte hex,
  required), `:api_key` (required — an absent key is refused, never fetched
  from the environment here), `:http` (`{module, state}`, default the real
  `:httpc` adapter), `:base_url`, `:model`, `:system_prompt` (per-agent
  persona voice; defaults to the kyber substrate prompt — T15).
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    seed = Keyword.get(opts, :seed)
    api_key = Keyword.get(opts, :api_key)

    cond do
      not valid_seed?(seed) ->
        {:error, :invalid_seed}

      not is_binary(api_key) or api_key == "" ->
        {:error, :no_api_key}

      true ->
        {:ok,
         %__MODULE__{
           seed: seed,
           author: Keys.author_for_seed(seed),
           api_key: api_key,
           http: Keyword.get(opts, :http, {Kyber.Agent.HttpClient.Httpc, nil}),
           base_url: Keyword.get(opts, :base_url, @base_url),
           model: Keyword.get(opts, :model, @model),
           system_prompt: Keyword.get(opts, :system_prompt, @system_prompt)
         }}
    end
  end

  @doc """
  The gather contract: verified conversation deltas in (log order), signed
  response wires out. The latest `message.received` is the prompt the
  response points back at; prior received/sent/response deltas ride as the
  chat history the model sees.
  """
  @spec gather(t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def gather(%__MODULE__{} = handler, deltas) when is_list(deltas) do
    with {:ok, messages, prompt_id} <- conversation(handler, deltas),
         {:ok, content} <- chat(handler, messages) do
      respond(handler, prompt_id, content)
    end
  end

  # ---------------------------------------------------------- conversation

  # deltas -> OpenAI messages, by kind (the first pointer's role): received
  # is the user, sent/responds are the agent's own prior turns; everything
  # else (checkpoints, ticks, annotations) is mechanism, not conversation
  defp conversation(handler, deltas) do
    messages =
      deltas
      |> Enum.flat_map(fn delta ->
        case {kind(delta), content_of(delta)} do
          {"received", {:ok, text}} -> [%{"role" => "user", "content" => text}]
          {"sent", {:ok, text}} -> [%{"role" => "assistant", "content" => text}]
          {"responds", {:ok, text}} -> [%{"role" => "assistant", "content" => text}]
          _other -> []
        end
      end)

    prompt =
      deltas
      |> Enum.reverse()
      |> Enum.find(&(kind(&1) == "received"))

    case {messages, prompt} do
      {_messages, nil} ->
        {:error, :no_prompt}

      {messages, %{id: prompt_id}} ->
        {:ok, [%{"role" => "system", "content" => handler.system_prompt} | messages], prompt_id}
    end
  end

  defp kind(%{claims: %{pointers: [%{role: role} | _rest]}}), do: role
  defp kind(_delta), do: nil

  defp content_of(%{claims: %{pointers: pointers}}) do
    case Enum.find(pointers, &(&1.role == "content")) do
      %{target: {:string, text}} -> {:ok, text}
      _other -> :no_content
    end
  end

  # ------------------------------------------------------------------ call

  @doc """
  One chat completion at the message level (the engine's entry: it builds
  its own windowed context): OpenAI messages in, the model's content out —
  or `{:ok, {:tool_calls, [{id, name, arguments}]}}` when the model asks
  for tools (native function calling; `arguments` is the JSON string).
  """
  @spec chat(t(), [map()]) ::
          {:ok, String.t()}
          | {:ok, {:tool_calls, [{String.t(), String.t(), String.t()}]}}
          | {:error, term()}
  def chat(%__MODULE__{} = handler, messages), do: chat(handler, messages, tools: [])

  @spec chat(t(), [map()], keyword()) ::
          {:ok, String.t()}
          | {:ok, {:tool_calls, [{String.t(), String.t(), String.t()}]}}
          | {:error, term()}
  def chat(%__MODULE__{} = handler, messages, opts) do
    tools = Keyword.get(opts, :tools, [])

    body = %{
      "model" => handler.model,
      "messages" => messages,
      # kimi-k3's API accepts ONLY temperature 1 — anything else is a 400
      # (a live-API constraint no stub test can catch; verified 2026-08-06)
      "temperature" => 1.0
    }

    body =
      if tools == [],
        do: body,
        else: Map.merge(body, %{"tools" => tools, "tool_choice" => "auto"})

    {adapter, state} = handler.http
    headers = [{~c"authorization", String.to_charlist("Bearer " <> handler.api_key)}]

    case adapter.post(handler.base_url <> "/chat/completions", headers, JSON.encode!(body), state) do
      {:ok, %{status: 200, body: response_body}} ->
        parse(response_body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:llm_http, status, response_body}}

      {:error, reason} ->
        {:error, {:llm_transport, reason}}
    end
  end

  defp parse(response_body) do
    case JSON.decode(response_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _rest]}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, %{"choices" => [%{"message" => %{"tool_calls" => calls}} | _rest]}}
      when is_list(calls) ->
        parse_tool_calls(calls)

      {:ok, other} ->
        {:error, {:llm_malformed, other}}

      {:error, reason} ->
        {:error, {:llm_malformed, reason}}
    end
  end

  # every entry must be a well-shaped function call — a malformed entry is a
  # refusal, never a partial call (reject, never repair)
  defp parse_tool_calls(calls) do
    parsed =
      for %{
            "id" => id,
            "function" => %{"name" => name, "arguments" => arguments}
          } <- calls,
          is_binary(id),
          is_binary(name),
          is_binary(arguments),
          do: {id, name, arguments}

    if length(parsed) == length(calls),
      do: {:ok, {:tool_calls, parsed}},
      else: {:error, {:llm_malformed, calls}}
  end

  # -------------------------------------------------------------- response

  defp respond(handler, prompt_id, content) do
    ts = 1.0 * System.system_time(:millisecond)

    with {:ok, signed} <- Events.llm_response(handler.seed, ts, prompt_id, content) do
      {:ok, [Wire.envelope(signed)]}
    end
  end

  defp valid_seed?(seed) when is_binary(seed) do
    match?({:ok, <<_::binary-32>>}, Base.decode16(seed, case: :mixed))
  end

  defp valid_seed?(_seed), do: false
end
