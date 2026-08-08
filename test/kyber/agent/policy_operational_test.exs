defmodule Kyber.Agent.PolicyOperationalTest do
  @moduledoc """
  T14b AC4 — the live policy gate, self-skipping (@moduletag :operational;
  `mix test` never runs it; set KYBER_OPERATIONAL=1 and MOONSHOT_API_KEY to
  run it live). Two legs through the LIVE reactor — real store, real
  executor, real tee (the :httpc adapter): the LLM is SCRIPTED (always
  http.get https://example.com/), the epoch decides allow vs refuse.

  The real-model leg is recorded, not asserted: run 2 of the live AC4
  (2026-08-08) had kimi-k3 emit a genuine http.get call — the request was
  machine-checked, the allow GateDecision + ToolResult persisted (the
  policy layer's allow path, live). Follow-up runs showed kimi-k3 with
  tool_choice "auto" answering one-shot tool prompts in plain text without
  calling (~75% of runs) — a live-model property, recorded in carries.md,
  not a policy-layer defect. Both legs are therefore scripted-deterministic.

  Allowed leg (H3 re-scope): the machine-check is the FIRST recorded action
  request (method + URL) plus the persisted GateDecision/ToolResult pair for
  its call, polled from the durable store. Exactly-one is a
  deterministic-suite property, never asserted live — a model may re-plan,
  and M6's fabricated refusal (the engine's string-verdict guard routes even
  allow decisions to its refusal branch) is recorded-and-tolerated.

  Refused leg: the epoch allows a host OUTSIDE the called one; the
  url_policy refusal GateDecision (pinned reason + policy_epoch pointer) is
  polled from the store and ZERO action requests are recorded.

  M5 discipline (the recorded engine contradiction, not fixed here): every
  decision reaching a live engine's decides path must carry a NON-NIL
  reason — the engine derives `reason || Atom.to_string(verdict)` from a
  STRING verdict and crashes on nil. So the executor gate is
  `Gate.new(prompt: [...], prompt_handler: always-allow)` (prompt decisions
  carry a reason) and the tool registry is cut to the gated pair (no other
  tool can draw a nil-reason default-deny decision).
  """
  use ExUnit.Case, async: false

  @moduletag :operational
  @moduletag timeout: 600_000

  alias Kyber.{Daemon, DurableStore, Events, Harness, Keys, Schema, Wire}
  alias Kyber.Agent.{Action, LlmHandler}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @model_id "kimi-k3"
  @human_seed String.duplicate("cd", 32)
  @skip_note "skipped: set KYBER_OPERATIONAL=1 (and MOONSHOT_API_KEY) to run the live policy gate"

  # the tee adapter: the REAL :httpc adapter with every action-layer request
  # recorded to the test first — the machine-check surface for the first
  # recorded request; never the LLM seam
  defmodule TeeHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def get(url, headers, %{reply_to: pid}) do
      send(pid, {:action_request, :get, url})
      Kyber.Agent.HttpClient.Httpc.get(url, headers, nil)
    end

    @impl true
    def post(url, headers, body, %{reply_to: pid}) do
      send(pid, {:action_request, :post, url, body})
      Kyber.Agent.HttpClient.Httpc.post(url, headers, body, nil)
    end
  end

  # the scripted LLM adapter: every chat completion is a single tool call to
  # http.get https://example.com/ — the refused leg's deterministic model
  # (the live surfaces — turn-walk, executor, store, tee — stay real)
  defmodule ScriptedLlm do
    def post(_url, _headers, _body, _state) do
      response =
        JSON.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_scripted_refused",
                    "function" => %{
                      "name" => "http_get",
                      "arguments" => JSON.encode!(%{"url" => "https://example.com/"})
                    }
                  }
                ]
              }
            }
          ]
        })

      {:ok, %{status: 200, body: response}}
    end
  end

  defp boot_live!(allow_hosts, llm \\ :live) do
    api_key = System.fetch_env!("MOONSHOT_API_KEY")
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14b-ac4-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14b-ac4-log-#{uniq}")
    ws = Path.join(System.tmp_dir!(), "kyber-t14b-ac4-ws-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    File.mkdir_p!(ws)
    :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)
    {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    config_log_path = Application.get_env(:kyber, :log_path)
    Application.stop(:kyber)
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Daemon.stop()
      Application.stop(:kyber)
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
      File.rm_rf(ws)
    end)

    llm =
      case llm do
        :live ->
          {:ok, h} = LlmHandler.new(seed: agent_seed, api_key: api_key, model: @model_id)
          h

        :scripted ->
          {:ok, h} =
            LlmHandler.new(
              seed: agent_seed,
              api_key: "stub-key",
              model: "stub-model",
              http: {ScriptedLlm, %{}}
            )

          h

        %LlmHandler{} = h ->
          h
      end

    # the gated pair ONLY (M5 discipline — see the moduledoc)
    tools = Map.take(Action.registry(), ["http.get", "http.post"])

    {:ok, _pid} =
      Daemon.boot(
        keyring_dir: key_dir,
        tick_ms: :manual,
        loop: :reactor,
        oracle_seed: :present,
        engine: [
          llm: llm,
          tools: tools,
          gate:
            Gate.new(
              prompt: ["http.get", "http.post"],
              prompt_handler: fn _tool, _args -> :allow end
            ),
          context: Action.context(workspace: ws, http: {TeeHttp, %{reply_to: self()}})
        ]
      )

    # the policy epoch, persisted BEFORE any model turn
    {:ok, {epoch_claims, epoch_sig}} =
      AgentEvents.policy(agent_seed, 1_754_600_000_000, "url_policy", allow_hosts, ["https"])

    epoch_id = Delta.id_hex(epoch_claims)
    :ok = DurableStore.append(Wire.envelope({epoch_claims, epoch_sig}))

    %{key_dir: key_dir, epoch_id: epoch_id, agent_seed: agent_seed}
  end

  # bounded sleep-free store polling (the operational cadence: 2s slices,
  # a timeout-only receive that cannot swallow tee messages)
  defp poll_store(pred, attempts \\ 60) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Enum.find(DurableStore.set(), pred) do
        nil ->
          receive do
          after
            2_000 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end

  defp resolve({_id, {claims, _sig}}), do: Schema.resolve(claims)

  test "AC4 allowed leg: the FIRST recorded request is the gated call; its decision + result persist" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts(@skip_note)
    else
      %{key_dir: key_dir} = boot_live!(["example.com"], :scripted)

      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:policy:ac4-allow",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" =>
              "Call the http.get tool exactly once with url https://example.com/ and then reply with the word done. Use no other tools and no other URLs.",
            "ts" => 1_754_600_000_100
          },
          key_dir
        )

      # the scripted model's request is deterministic (the live-model leg is
      # recorded separately — see the moduledoc): bounded receive, then the
      # H3 machine-check on the FIRST recorded request — method + URL
      request =
        receive do
          {:action_request, method, url} -> {method, url}
          {:action_request, method, url, _body} -> {method, url}
        after
          10_000 -> flunk("scripted allowed leg: no action_request within 10s")
        end

      {_method, url} = request
      assert url =~ "example.com"

      # the persisted pair, polled sleep-free: a ToolResult and the allow
      # GateDecision deciding the SAME ToolCall
      result = poll_store(&match?(%{type: "ToolResult"}, resolve(&1)))
      assert result != nil, "no ToolResult persisted for the allowed live call"
      %{type: "ToolResult", call: {:delta, call_id, _}} = resolve(result)

      decision =
        poll_store(fn entry ->
          match?(
            %{type: "GateDecision", verdict: "allow", decides: {:delta, ^call_id, _}},
            resolve(entry)
          )
        end)

      assert decision != nil, "no allow GateDecision persisted for the allowed live call"

      # exactly-one is deterministic-only (H3); anything further — a model
      # re-plan after M6's fabricated refusal — is a logged observation
      extras =
        Stream.repeatedly(fn ->
          receive do
            {:action_request, method, extra_url} -> {method, extra_url}
            {:action_request, method, extra_url, _body} -> {method, extra_url}
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      IO.puts("AC4 allowed leg: further recorded requests (observation): #{inspect(extras)}")
    end
  end

  test "AC4 refused leg: a disallowed host is refused in the store and NO request is recorded" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts(@skip_note)
    else
      # the refused leg's deterministic model (H3 precedent: the store-side
      # witness must not depend on live-model behavior — the model's
      # participation is proven by the allowed leg). The scripted adapter
      # ALWAYS calls http.get https://example.com/ — a host the epoch
      # refuses; every other surface (turn-walk, executor, store, tee) is
      # the live path.
      %{key_dir: key_dir, epoch_id: epoch_id} = boot_live!(["allowed.example"], :scripted)

      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:policy:ac4-refuse",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" =>
              "Call the http.get tool exactly once with url https://example.com/ and then reply with the word done. Use no other tools and no other URLs.",
            "ts" => 1_754_600_000_300
          },
          key_dir
        )

      # the store-side witness: the url_policy refusal with the pinned
      # reason and the policy_epoch pointer at the live epoch
      refusal =
        poll_store(
          &match?(%{type: "GateDecision", verdict: "refuse", policy: "url_policy"}, resolve(&1))
        )

      assert refusal != nil, "no url_policy refusal persisted for the disallowed live call"
      typed = resolve(refusal)
      assert typed.reason == "url_policy: host not allowed by the current epoch"
      assert typed.policy_epoch == {:delta, epoch_id, "under"}

      # zero recorded requests — the tee saw nothing, asserted not assumed
      refute_received {:action_request, _, _}
      refute_received {:action_request, _, _, _}
    end
  end
end
