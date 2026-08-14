defmodule Kyber.Agent.T17LlmBoundaryTest do
  @moduledoc """
  T17 — the engine default flip (deepseek, user verdict 2026-08-13) and the
  inference-boundary redaction (AC22): inside LlmHandler, in the unlogged
  usage window, immediately before the provider request is built, the
  context is scanned and known secret VALUES (plus conservative unknown
  shapes) are replaced with `[REDACTED]` — while 64-hex content ids and
  `ed25519:` authors ride the wire untouched.
  """
  use ExUnit.Case, async: true

  alias Kyber.Agent.LlmHandler

  @seed String.duplicate("ab", 32)

  defmodule CaptureHttp do
    @behaviour Kyber.Agent.HttpClient
    @impl true
    def post(url, _headers, body, %{reply_to: pid}) do
      send(pid, {:request, url, JSON.decode!(body)})

      {:ok,
       %{
         status: 200,
         body: JSON.encode!(%{"choices" => [%{"message" => %{"content" => "ok"}}]})
       }}
    end
  end

  test "the hardcoded engine default is deepseek — the terminal step-back state" do
    {:ok, h} = LlmHandler.new(seed: @seed, api_key: "test-key-not-real")
    assert h.base_url == "https://api.deepseek.com/v1"
    assert h.model == "deepseek-v4-flash"
  end

  test "AC22: a known secret value in the context reaches the wire as [REDACTED]; 64-hex ids ride intact" do
    key = "real-provider-key-abcdef-123456"
    {:ok, h} = LlmHandler.new(seed: @seed, api_key: key, http: {CaptureHttp, %{reply_to: self()}})

    hex_id = String.duplicate("cd", 32)
    author = "ed25519:" <> String.duplicate("ef", 32)

    messages = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "memory note: the key is #{key}; delta #{hex_id} by #{author}"}
    ]

    {:ok, _} = LlmHandler.chat(h, messages)
    assert_receive {:request, _url, body}

    [_sys, user] = body["messages"]
    assert user["content"] =~ "[REDACTED]"
    refute user["content"] =~ key
    assert user["content"] =~ hex_id
    assert user["content"] =~ author
  end

  test "AC22: extra known values (:redact — operator seed et al.) and unknown sk- shapes are both redacted" do
    {:ok, h} =
      LlmHandler.new(
        seed: @seed,
        api_key: "test-key-not-real",
        redact: ["operator-seed-value-9876543210"],
        http: {CaptureHttp, %{reply_to: self()}}
      )

    messages = [
      %{"role" => "user",
        "content" => "tok sk-abcdefghijklmnop1234 and operator-seed-value-9876543210 end"}
    ]

    {:ok, _} = LlmHandler.chat(h, messages)
    assert_receive {:request, _url, body}

    [user] = body["messages"]
    refute user["content"] =~ "sk-abcdefghijklmnop1234"
    refute user["content"] =~ "operator-seed-value-9876543210"
    assert user["content"] =~ "[REDACTED]"
  end
end
