defmodule Kyber.Agent.LlmHandlerTest do
  @moduledoc """
  AC1 — the LLM handler is real and dependency-light. The handler implements
  the gather contract `(delta[]) -> delta[]` against Moonshot's OpenAI-
  compatible chat API; the HTTP client is a behaviour seam injected at
  construction. Tests run against a CANNED response through the stub adapter
  only — the live smoke is Hermes's job (AC4), never a test's.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Events, Keys, Store, Wire}
  alias Kyber.Agent.LlmHandler

  # deterministic test seeds (32-byte hex) — never the real keyring
  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)

  @question "What is the capital of France?"
  @canned_answer "Paris is the capital of France."

  defmodule StubHttp do
    @moduledoc """
    The injectable HTTP adapter (Kyber.Agent.HttpClient behaviour): captures
    the request by messaging the test pid carried in its state, answers with
    the canned Moonshot-shaped body from the same state.
    """
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(url, headers, body, state) do
      send(state.reply_to, {:llm_request, url, headers, JSON.decode!(body)})
      state.respond
    end
  end

  defp moonshot_body(content) do
    JSON.encode!(%{
      "id" => "chatcmpl-stub-1",
      "object" => "chat.completion",
      "model" => "kimi-k3",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 7, "total_tokens" => 19}
    })
  end

  defp handler(respond) do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: self(), respond: respond}}
      )

    handler
  end

  defp received_delta(content) do
    {:ok, signed} =
      Events.message_received(@human_seed, 1_700_000_000_000, "msg-1", "chan-1", "sess-1", content)

    {:ok, delta} = signed |> Wire.envelope() |> Store.verify()
    delta
  end

  test "gather calls Moonshot's chat API through the injected adapter and answers a signed response wire" do
    delta = received_delta(@question)
    ok = {:ok, %{status: 200, body: moonshot_body(@canned_answer)}}

    assert {:ok, [wire]} = LlmHandler.gather(handler(ok), [delta])

    # the request that crossed the seam is OpenAI-compatible, Moonshot-based
    assert_receive {:llm_request, url, headers, body}
    assert url == "https://api.moonshot.ai/v1/chat/completions"

    auth = List.keyfind(headers, ~c"authorization", 0)
    assert auth != nil
    assert List.to_string(elem(auth, 1)) == "Bearer test-key-never-real"

    assert body["model"] == "kimi-k3"
    assert List.last(body["messages"]) == %{"role" => "user", "content" => @question}

    # the output is an ordinary signed claim: door-verified, agent-authored,
    # carrying the model's content and pointing back at the prompt delta
    assert {:ok, response} = Store.verify(wire)
    assert response.claims.author == Keys.author_for_seed(@agent_seed)

    assert %{target: {:string, @canned_answer}} =
             Enum.find(response.claims.pointers, &(&1.role == "content"))

    assert %{target: {:delta, responds_to, _ctx}} =
             Enum.find(response.claims.pointers, &(&1.role == "responds"))

    assert responds_to == delta.id
  end

  test "prior agent turns ride as assistant messages (the store is the model's memory)" do
    first = received_delta("Remember the number 41.")

    {:ok, signed} =
      Events.message_sent(@agent_seed, 1_700_000_001_000, first.id, "msg-out-1", "chan-1", "Noted: 41.")

    {:ok, sent} = signed |> Wire.envelope() |> Store.verify()
    followup = received_delta("What number did I just ask you to remember?")

    ok = {:ok, %{status: 200, body: moonshot_body("You said 41.")}}
    assert {:ok, [_wire]} = LlmHandler.gather(handler(ok), [first, sent, followup])

    assert_receive {:llm_request, _url, _headers, body}

    assert [
             %{"role" => "user", "content" => "Remember the number 41."},
             %{"role" => "assistant", "content" => "Noted: 41."},
             %{"role" => "user", "content" => "What number did I just ask you to remember?"}
           ] = Enum.take(body["messages"], -3)
  end

  test "a non-200 answer is refused, never repaired" do
    delta = received_delta(@question)
    bad = {:ok, %{status: 500, body: "upstream exploded"}}

    assert {:error, {:llm_http, 500, _body}} = LlmHandler.gather(handler(bad), [delta])
  end

  test "a body without choices is refused, never repaired" do
    delta = received_delta(@question)
    empty = {:ok, %{status: 200, body: JSON.encode!(%{"choices" => []})}}

    assert {:error, {:llm_malformed, _}} = LlmHandler.gather(handler(empty), [delta])
  end

  test "a transport error surfaces as an error, not a crash" do
    delta = received_delta(@question)
    down = {:error, :econnrefused}

    assert {:error, {:llm_transport, :econnrefused}} = LlmHandler.gather(handler(down), [delta])
  end

  test "the constructor refuses a missing api key rather than reading the environment" do
    assert {:error, :no_api_key} = LlmHandler.new(seed: @agent_seed, api_key: nil, http: {StubHttp, %{}})
  end
end
