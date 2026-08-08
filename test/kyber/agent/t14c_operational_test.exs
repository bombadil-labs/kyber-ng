defmodule Kyber.Agent.T14cOperationalTest do
  @moduledoc """
  T14c AC4 — the live memory seam, self-skipping (@moduletag :operational;
  `mix test` never runs it; set KYBER_OPERATIONAL=1 and MOONSHOT_API_KEY to
  run it live). Per the T14b precedent (commit 875ad38): the seam legs are
  SCRIPTED-deterministic through the LIVE reactor — real store, real
  executor, real tee — scripted allow + refuse `memory.read` dispatches
  whose assertions are the AC2 shapes. ONE real-model turn whose assertions
  are store-facts only and conditional: (i) a `PromptAssembled` exists for
  the issued request and decodes to a message list headed by the system
  prompt; (ii) for every `memory.read` ToolCall in the store,
  content-flow <=> allow-GateDecision consistency per call_id — the verdict
  itself NEVER asserted; (iii) exactly one `BootAttestation` with the
  expected pointers. No leg ever asserts the model calls the tool (the
  recorded kimi-k3 tool_choice-auto unreliability makes that a flake by
  construction).

  M5-avoidance discipline verbatim: prompt gates carry reasons (every
  decision a live engine can see has a non-nil reason), the tool registry
  is the gated pair + `"memory.read"` only, and fabricated-refusal behavior
  is tolerated, never asserted on.
  """
  use ExUnit.Case, async: false

  @moduletag :operational
  @moduletag timeout: 600_000

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Schema, Wire}
  alias Kyber.Agent.{Action, Attestation, LlmHandler, Prompt, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @model_id "kimi-k3"
  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)
  @skip_note "skipped: set KYBER_OPERATIONAL=1 (and MOONSHOT_API_KEY) to run the live memory seam"

  # the tee adapter: the REAL :httpc adapter with every action-layer request
  # recorded to the test first — never the LLM seam
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

  # the scripted LLM adapter: every chat completion is a single tool call
  # to memory.read <entity from the adapter state> until the refusal/result
  # loops back (a "tool" role message is present), then a plain answer —
  # the scripted legs' deterministic model
  defmodule ScriptedLlm do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      decoded = JSON.decode!(body)

      response =
        if Enum.any?(decoded["messages"], &match?(%{"role" => "tool"}, &1)) do
          JSON.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "scripted reply"}}
            ]
          })
        else
          JSON.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "tool_calls" => [
                    %{
                      "id" => "call_scripted_memory",
                      "function" => %{
                        "name" => "memory_read",
                        "arguments" => JSON.encode!(%{"entity" => state.entity})
                      }
                    }
                  ]
                }
              }
            ]
          })
        end

      {:ok, %{status: 200, body: response}}
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # bounded sleep-free store polling (the operational cadence: 2s slices, a
  # timeout-only receive that cannot swallow tee messages)
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

  # the live boot: real store/executor/tee; M5-discipline gate (prompt
  # gates carry reasons), the gated pair + memory.read only; operator_seed
  # wired so the boot attestation is part of the live surface
  defp boot_live!(llm) do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14c-ac4-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14c-ac4-log-#{uniq}")
    ws = Path.join(System.tmp_dir!(), "kyber-t14c-ac4-ws-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    File.mkdir_p!(ws)
    :ok = Keys.import_human_seed(@human_seed, key_dir)
    {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    config_log_path = Application.get_env(:kyber, :log_path)
    stop_app()
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
      File.rm_rf(ws)
    end)

    # the gated pair + "memory.read" ONLY (M5 discipline — see the moduledoc)
    tools =
      Action.registry()
      |> Map.take(["http.get", "http.post"])
      |> Map.merge(ToolExecutor.memory_tools(fn -> DurableStore.set() end))

    {:ok, _pid} =
      Daemon.boot(
        keyring_dir: key_dir,
        tick_ms: :manual,
        loop: :reactor,
        oracle_seed: :present,
        operator_seed: @operator_seed,
        budget_cap: 32,
        engine: [
          llm: llm,
          tools: tools,
          gate:
            Gate.new(
              prompt: ["http.get", "http.post", "memory.read"],
              prompt_handler: fn _tool, _args -> :allow end
            ),
          context: Action.context(workspace: ws, http: {TeeHttp, %{reply_to: self()}})
        ]
      )

    %{key_dir: key_dir, agent_seed: agent_seed}
  end

  # the memory canon + the governing epoch, persisted BEFORE any turn
  defp seed_memory!(allow_entities, canon_entity, canon_content) do
    {:ok, {mem_claims, mem_sig}} =
      AgentEvents.memory_entity(@human_seed, 1_754_600_000_000, canon_entity, canon_content, [])

    :ok = DurableStore.append(Wire.envelope({mem_claims, mem_sig}))

    {:ok, {epoch_claims, epoch_sig}} =
      AgentEvents.memory_policy(@human_seed, 1_754_600_000_001, allow_entities)

    epoch_id = Delta.id_hex(epoch_claims)
    :ok = DurableStore.append(Wire.envelope({epoch_claims, epoch_sig}))
    epoch_id
  end

  defp scripted_llm(entity) do
    {:ok, llm} =
      LlmHandler.new(
        seed: @human_seed,
        api_key: "stub-key",
        model: "stub-model",
        http: {ScriptedLlm, %{entity: entity}}
      )

    llm
  end

  test "AC4 scripted allow leg: the allowed memory.read persists the allow GateDecision + a ToolResult equal to the canon (the AC2 allow shape, live)" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts(@skip_note)
    else
      ctx = boot_live!(scripted_llm("e1"))
      seed_memory!(["e1"], "e1", "the live canon: AC4 allow")

      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:t14c:ac4-allow",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" =>
              "Use the memory.read tool exactly once with entity e1 and then reply with the word done.",
            "ts" => 1_754_600_000_100
          },
          ctx.key_dir
        )

      # the AC2 allow shape, store-side: a ToolResult whose content equals
      # the canon, and the allow GateDecision deciding the SAME call
      result =
        poll_store(
          &match?(%{type: "ToolResult", result: "the live canon: AC4 allow"}, resolve(&1))
        )

      assert result != nil, "no canon-equal ToolResult persisted"
      %{type: "ToolResult", call: {:delta, call_id, _}} = resolve(result)

      decision =
        poll_store(fn entry ->
          match?(
            %{type: "GateDecision", verdict: "allow", decides: {:delta, ^call_id, _}},
            resolve(entry)
          )
        end)

      assert decision != nil, "no allow GateDecision for the allowed live read"

      # the operator attestation is part of the live surface
      assert [_one] = attestations()
    end
  end

  test "AC4 scripted refuse leg: a disallowed memory.read persists the memory_policy refusal (pinned reason) and NO ToolResult (the AC2 refuse shape, live)" do
    if System.get_env("KYBER_OPERATIONAL") != "1" do
      IO.puts(@skip_note)
    else
      ctx = boot_live!(scripted_llm("e-secret"))
      epoch_id = seed_memory!(["e1"], "e-secret", "classified: AC4 refuse")

      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:t14c:ac4-refuse",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" =>
              "Use the memory.read tool exactly once with entity e-secret and then reply with the word done.",
            "ts" => 1_754_600_000_300
          },
          ctx.key_dir
        )

      refusal =
        poll_store(
          &match?(
            %{type: "GateDecision", verdict: "refuse", policy: "memory_policy"},
            resolve(&1)
          )
        )

      assert refusal != nil, "no memory_policy refusal persisted"
      typed = resolve(refusal)
      assert typed.reason == "memory_policy: entity not allowed by the current epoch"
      assert typed.policy_epoch == {:delta, epoch_id, "under"}

      %{type: "GateDecision", decides: {:delta, call_id, _}} = typed

      # NO ToolResult for the refused call — the read never happened
      refute Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               match?(%{type: "ToolResult", call: {:delta, ^call_id, _}}, Schema.resolve(claims))
             end)
    end
  end

  test "AC4 real-model turn: store-facts only — PromptAssembled headed by the system prompt, memory.read consistency per call_id, exactly one BootAttestation" do
    if System.get_env("KYBER_OPERATIONAL") != "1" or is_nil(System.get_env("MOONSHOT_API_KEY")) do
      IO.puts(@skip_note)
    else
      api_key = System.fetch_env!("MOONSHOT_API_KEY")

      {:ok, llm} =
        LlmHandler.new(
          seed: @human_seed,
          api_key: api_key,
          model: @model_id
        )

      ctx = boot_live!(llm)
      seed_memory!(["e1"], "e1", "the live canon: AC4 real")

      {:ok, received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:t14c:ac4-real",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" =>
              "Read the memory for entity e1 with the memory.read tool and report what it says.",
            "ts" => 1_754_600_000_500
          },
          ctx.key_dir
        )

      # (i) a PromptAssembled exists for the issued request and decodes to
      # a message list headed by the system prompt
      request =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(
            %{type: "InferenceRequested", promptRef: {:delta, ^received_id, _}},
            Schema.resolve(claims)
          )
        end)

      assert request != nil, "no InferenceRequested for the live request"
      {req_delta_id, _req_claims} = request

      assembled =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(
            %{type: "PromptAssembled", requestRef: {:delta, ^req_delta_id, _}},
            Schema.resolve(claims)
          )
        end)

      assert assembled != nil, "no PromptAssembled for the live request"
      %{type: "PromptAssembled", content: canonical} = resolve(assembled)

      assert {:ok, [%{"role" => "system", "content" => system_prompt} | _]} =
               Prompt.decode(canonical)

      assert system_prompt == Prompt.system_prompt()

      # (ii) for every memory.read ToolCall in the store: content-flow <=>
      # allow-GateDecision consistency per call_id — the verdict itself is
      # never asserted
      calls =
        Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} ->
          match?(%{type: "ToolCall", tool: {:entity, "memory.read", _}}, Schema.resolve(claims))
        end)

      for {call_id, _claims_sig} <- calls do
        decision =
          Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} ->
            match?(
              %{type: "GateDecision", decides: {:delta, ^call_id, _}},
              Schema.resolve(claims)
            )
          end)

        result =
          Enum.find(DurableStore.set(), fn {_id, {claims, _sig}} ->
            match?(%{type: "ToolResult", call: {:delta, ^call_id, _}}, Schema.resolve(claims))
          end)

        allowed =
          case decision do
            nil -> false
            {_id, {d_claims, _sig}} -> match?(%{verdict: "allow"}, Schema.resolve(d_claims))
          end

        assert allowed == (result != nil),
               "memory.read call #{call_id}: content flow and the allow decision disagree"
      end

      # (iii) exactly one BootAttestation with the expected pointers
      assert [_one] = attestations()
      {_att_id, {att_claims, _att_sig}} = hd(attestations())
      att = Schema.resolve(att_claims)
      assert att.operator == {:entity, Keys.author_for_seed(@operator_seed), "attests"}
      assert att.agent == {:entity, Keys.author_for_seed(ctx.agent_seed), "attested"}
      assert Attestation.verified?(DurableStore.set(), Keys.author_for_seed(ctx.agent_seed))
    end
  end

  defp attestations do
    Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} ->
      match?(%{type: "BootAttestation"}, Schema.resolve(claims))
    end)
  end
end
