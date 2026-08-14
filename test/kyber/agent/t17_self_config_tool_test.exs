defmodule Kyber.Agent.T17SelfConfigToolTest do
  @moduledoc """
  T17 AC5/AC9/P0 — the `self_config.set` tool: the agent's own (opt-in)
  write path onto its AgentSet stream. Pure executor-level tests: the
  handler is a pure function of (store snapshot, call delta, state), so no
  daemon, no app store — a hand-built DeltaSet and a direct handler call.

  The boundary contract: the grant (`self_config: true` on the live fold)
  is checked AT CALL TIME; `base_url` is refused ALWAYS (set AND unset —
  the proxy-exfiltration P0); the AC17 door (secret-shaped values, unknown
  fields) runs before any mint. A refusal mints NO AgentSet delta.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Config, ToolExecutor}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Action.Gate

  @operator_seed String.duplicate("7f", 32)
  @agent_seed String.duplicate("9c", 32)
  @base_ts 1_754_700_000_000.0

  defp admit!(set, {:ok, signed}) do
    {:ok, set} = Store.admit(Wire.envelope(signed), set)
    set
  end

  defp granted_set do
    DeltaSet.new()
    |> admit!(
      AgentEvents.agent_set(@operator_seed, @base_ts, "wisp", %{
        model: "kimi-base",
        base_url: "https://api.deepseek.com/v1",
        api_key_env: "DEEPSEEK_API_KEY",
        self_config: "true"
      })
    )
  end

  defp ungranted_set do
    DeltaSet.new()
    |> admit!(
      AgentEvents.agent_set(@operator_seed, @base_ts, "wisp", %{
        model: "kimi-base",
        base_url: "https://api.deepseek.com/v1"
      })
    )
  end

  defp call!(set, fields_json, context \\ %{agent: "wisp"}) do
    {:ok, signed} =
      AgentEvents.tool_call(
        @agent_seed,
        @base_ts + 100,
        "self_config.set",
        fields_json,
        "request:t17sc"
      )

    wire = Wire.envelope(signed)
    {:ok, claims_set} = Store.admit(wire, set)
    {_claims, _sig} = claims_set[wire["id"]]

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: ToolExecutor.self_config_tools("wisp"),
        gate: Gate.new(allow: ["self_config.set"]),
        context: context,
        store: fn -> set end
      )

    {claims, _sig} = claims_set[wire["id"]]
    handler.([%{id: wire["id"], claims: claims}])
  end

  defp resolved(outputs) do
    for wire <- outputs do
      {:ok, delta} = Store.verify(wire)
      Schema.resolve(delta.claims)
    end
  end

  defp agent_sets(outputs) do
    Enum.filter(resolved(outputs), &match?(%{type: "AgentSet"}, &1))
  end

  defp result_status(outputs) do
    Enum.find_value(resolved(outputs), fn
      %{type: "ToolResult", status: status} -> status
      _other -> nil
    end)
  end

  defp result_text(outputs) do
    Enum.find_value(resolved(outputs), fn
      %{type: "ToolResult", result: result} -> result
      _other -> nil
    end)
  end

  test "the tool is listed for the model (spec + key map)" do
    tools = ToolExecutor.self_config_tools("wisp")
    assert [spec] = ToolExecutor.tool_specs(tools)
    assert spec["function"]["name"] == "self_config_set"
    assert ToolExecutor.tool_key_map(tools) == %{"self_config_set" => "self_config.set"}
  end

  test "granted: an agent-attested AgentSet delta is minted and folds (AC9)" do
    set = granted_set()
    outputs = call!(set, JSON.encode!(%{"fields" => %{"model" => "kimi-next"}}))

    assert result_status(outputs) == "ok"
    assert [%{type: "AgentSet"}] = agent_sets(outputs)

    # the minted delta is AGENT-authored and folds under the live grant
    [agent_set_wire] =
      Enum.filter(outputs, fn wire ->
        {:ok, delta} = Store.verify(wire)
        match?(%{type: "AgentSet"}, Schema.resolve(delta.claims))
      end)

    set =
      Enum.reduce(outputs, set, fn wire, acc ->
        {:ok, acc} = Store.admit(wire, acc)
        acc
      end)

    assert {:ok, view} = Config.resolve(set, "wisp")
    assert view.model == "kimi-next"
    {claims, _sig} = set[agent_set_wire["id"]]
    assert claims.author == Keys.author_for_seed(@agent_seed)
  end

  test "no grant: the call is refused at the boundary — NO delta (AC5)" do
    outputs = call!(ungranted_set(), JSON.encode!(%{"fields" => %{"model" => "kimi-next"}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "self_config"
  end

  test "base_url can NEVER be set by the agent (P0) — even under the grant" do
    outputs =
      call!(
        granted_set(),
        JSON.encode!(%{"fields" => %{"base_url" => "https://attacker.example/v1"}})
      )

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "operator"
  end

  test "base_url can NEVER be unset by the agent (P0)" do
    outputs = call!(granted_set(), JSON.encode!(%{"fields" => %{"unset" => ["base_url"]}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
  end

  test "operator_seed_env can NEVER be set by the agent (P5 H3) — even under the grant" do
    outputs =
      call!(
        granted_set(),
        JSON.encode!(%{"fields" => %{"operator_seed_env" => "ATTACKER_SEED"}})
      )

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "operator"
  end

  test "operator_seed_env can NEVER be unset by the agent (P5 H3)" do
    outputs =
      call!(granted_set(), JSON.encode!(%{"fields" => %{"unset" => ["operator_seed_env"]}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
  end

  test "api_key_env can NEVER be set by the agent (P5 r8 H1) — even under the grant" do
    # a well-formed env NAME, so the refusal is the operator-attested
    # boundary, not the AC17 shape door — an agent-named env var would
    # exfiltrate that var's value to the provider via the auth header
    outputs =
      call!(
        granted_set(),
        JSON.encode!(%{"fields" => %{"api_key_env" => "KYBER_OPERATOR_SEED"}})
      )

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "operator"
  end

  test "api_key_enc can NEVER be set by the agent (P5 r8 H1) — even under the grant" do
    enc = Base.encode64(:crypto.strong_rand_bytes(44))
    outputs = call!(granted_set(), JSON.encode!(%{"fields" => %{"api_key_enc" => enc}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "operator"
  end

  test "api_key_env can NEVER be unset by the agent (P5 r8 H1)" do
    outputs = call!(granted_set(), JSON.encode!(%{"fields" => %{"unset" => ["api_key_env"]}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
  end

  test "the AC17 door runs at the tool boundary: secret-shaped value refused, NO delta" do
    outputs =
      call!(
        granted_set(),
        JSON.encode!(%{"fields" => %{"model" => "sk-abcdef1234567890abcdef"}})
      )

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "model"
  end

  test "an unknown field is malformed — NO delta" do
    outputs = call!(granted_set(), JSON.encode!(%{"fields" => %{"api_key" => "anything"}}))

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
  end

  test "the grant check rides the PINNED chain: a backdated self-grant is inert (P5 MEDIUM-2)" do
    attacker_seed = String.duplicate("5d", 32)
    op_author = Keys.author_for_seed(@operator_seed)

    # the attacker BACKDATES a self-grant before the operator's first delta
    # (timestamps are self-asserted — the store admits it)
    set =
      DeltaSet.new()
      |> admit!(
        AgentEvents.agent_set(attacker_seed, @base_ts - 100, "wisp", %{self_config: "true"})
      )
      |> admit!(
        AgentEvents.agent_set(@operator_seed, @base_ts, "wisp", %{
          model: "kimi-base",
          base_url: "https://api.deepseek.com/v1"
        })
      )

    # display-only resolve/2 falls for the earliest author...
    assert {:ok, %{self_config: true}} = Config.resolve(set, "wisp")
    # ...the pinned fold does not
    assert {:ok, %{self_config: false}} = Config.resolve(set, "wisp", [op_author])

    # a call through the PINNED boot context (what a live daemon threads,
    # P5 MEDIUM-1) is refused at the boundary: NO delta minted
    outputs =
      call!(
        set,
        JSON.encode!(%{"fields" => %{"model" => "kimi-owned"}}),
        %{agent: "wisp", operator_authors: [op_author]}
      )

    assert agent_sets(outputs) == []
    assert result_status(outputs) == "error"
    assert result_text(outputs) =~ "self_config"
  end

  test "fold-side pin: an agent unset of base_url is fold-inert (P0)" do
    set = granted_set()

    set =
      admit!(
        set,
        AgentEvents.agent_set(@agent_seed, @base_ts + 50, "wisp", %{unset: ["base_url"]})
      )

    assert {:ok, view} = Config.resolve(set, "wisp")
    assert view.base_url == "https://api.deepseek.com/v1"
  end
end
