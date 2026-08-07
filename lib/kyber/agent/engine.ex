defmodule Kyber.Agent.Engine do
  @moduledoc """
  The stateful turn holder (T11b): fires on `InferenceRequested`, rehydrates
  the context by pointer-walk (session conversation + summaries + memory
  pointers — the store is the model's memory, AC5), applies the window lens
  (last N turns; a `ConversationSummary` covers the elided head), calls the
  model through the injected `Kyber.Agent.LlmHandler`, and emits
  `ResponseDelta` + `message.sent` — or a `ToolCall` mid-turn, resuming on
  the matching `ToolResult`.

  The engine is ASYNC behind the gather: its handler casts and returns `[]`
  immediately (the gather's route call must never wait on an HTTP exchange),
  and finished wires go out through the sink (`Kyber.Daemon.emit/1` by
  default — the one admission point).

  Idempotence (AC3): a request whose `ResponseDelta` is already in the store
  is a COUNTED SKIP, never a second model call. Restart (AC8): in-flight
  turn state lives in this process, but the CHAIN is the durable state —
  `resume/1` pointer-walks unanswered requests out of the store and picks
  each up exactly where its chain stopped (after a persisted `ToolResult`,
  or from the top when no tool was in flight).
  """

  use GenServer

  alias Kyber.{DurableStore, Schema, Wire}
  alias Kyber.Agent.{ContextBuilder, Events, LlmHandler, ToolExecutor}

  @default_window 8
  @system_prompt "You are kyber, an agent living in a claims substrate. " <>
                   "Ground your answer in the conversation and memory notes provided. " <>
                   "Use the provided tools when they help."

  @type status :: %{
          answered: non_neg_integer(),
          skipped: non_neg_integer(),
          tool_calls: non_neg_integer(),
          pending: non_neg_integer()
        }

  # ------------------------------------------------------------------- api

  @doc """
  Start the engine. Options: `:llm` (a `Kyber.Agent.LlmHandler` struct,
  required), `:window` (last-N turn lens, default #{@default_window}),
  `:tools` (OpenAI function specs, default `ToolExecutor.tool_specs/0`),
  `:tool_keys` (the registry-accurate model-name -> action-id map, default
  nil — the syntactic `ToolExecutor.tool_key/1` fallback; T12 action ids
  carry dots, so a real registry wires this map),
  `:store` (thunk answering the delta set, default the durable store),
  `:sink` (wire consumer, default `Kyber.Daemon.emit/1`), `:name` (default
  `#{inspect(__MODULE__)}`; `nil` for anonymous).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The gather handler closure: casts each routed delta into the engine and
  returns no outputs — the sink carries the results (async by design).
  Subscribe it to `"promptRef"` (requests) AND `"call"` (tool results).
  """
  @spec handler(GenServer.server()) :: Kyber.Gather.handler()
  def handler(engine \\ __MODULE__) do
    fn view ->
      Enum.each(view, &GenServer.cast(engine, {:delta, &1}))
      []
    end
  end

  @doc "Counters: answered, skipped (already-answered re-fires), tool_calls, pending."
  @spec status(GenServer.server()) :: status()
  def status(engine \\ __MODULE__), do: GenServer.call(engine, :status)

  @doc """
  Boot-time recovery (the chain is the state): walk the store for
  `InferenceRequested` deltas with no `ResponseDelta`, resume each — from
  its persisted `ToolResult` when one exists, from the top otherwise. A
  chain whose `ToolCall` still awaits its result is left for the executor.
  Returns `%{resumed: n, waiting: n}`.
  """
  @spec resume(GenServer.server()) :: %{resumed: non_neg_integer(), waiting: non_neg_integer()}
  def resume(engine \\ __MODULE__), do: GenServer.call(engine, :resume, :infinity)

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    {:ok,
     %{
       llm: Keyword.fetch!(opts, :llm),
       window: Keyword.get(opts, :window, @default_window),
       tools: Keyword.get(opts, :tools, ToolExecutor.tool_specs()),
       tool_keys: Keyword.get(opts, :tool_keys),
       store: Keyword.get(opts, :store, fn -> DurableStore.set() end),
       sink: Keyword.get(opts, :sink, &Kyber.Daemon.emit/1),
       notify: Keyword.get(opts, :notify),
       pending: %{},
       answered: 0,
       skipped: 0,
       tool_calls: 0
     }}
  end

  @impl true
  def handle_cast({:delta, delta}, state) do
    {:noreply, dispatch(delta, state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    counters = Map.take(state, [:answered, :skipped, :tool_calls])
    {:reply, Map.put(counters, :pending, map_size(state.pending)), state}
  end

  def handle_call(:resume, _from, state) do
    set = state.store.()

    unanswered =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "promptRef",
          match?(%{type: "InferenceRequested"}, Schema.resolve(claims)),
          not answered?(set, id),
          do: {id, claims}

    {report, state} =
      Enum.reduce(unanswered, {%{resumed: 0, waiting: 0}, state}, fn {id, claims},
                                                                     {report, state} ->
        case chain_position(set, id) do
          {:tool_result, result_delta} ->
            {%{report | resumed: report.resumed + 1},
             dispatch(%{id: result_delta.id, claims: result_delta.claims}, state)}

          :tool_waiting ->
            {%{report | waiting: report.waiting + 1}, state}

          :top ->
            {%{report | resumed: report.resumed + 1}, dispatch(%{id: id, claims: claims}, state)}
        end
      end)

    {:reply, report, state}
  end

  # -------------------------------------------------------------- dispatch

  defp dispatch(%{id: id, claims: claims}, state) do
    case {kind(claims), Schema.resolve(claims)} do
      {"promptRef", %{type: "InferenceRequested"} = typed} ->
        infer(id, typed, state)

      {"call", %{type: "ToolResult"} = typed} ->
        tool_result(id, typed, state)

      {"decides",
       %{type: "GateDecision", verdict: verdict, decides: {:delta, call_id, _ctx}} = typed}
      when verdict != :allow ->
        refusal(call_id, typed, state)

      _other ->
        state
    end
  end

  # ------------------------------------------------------------- inference

  defp infer(request_id, typed, state) do
    set = state.store.()

    if answered?(set, request_id) do
      notify(state, {:skipped, request_id})
      %{state | skipped: state.skipped + 1}
    else
      {:delta, prompt_id, _} = typed.promptRef
      {:entity, session_id, _} = typed.sessionId
      memory_ids = for {:delta, id, _ctx} <- typed.memoryPointers, do: id

      turn = %{
        request_id: request_id,
        prompt_id: prompt_id,
        session_id: session_id,
        memory_ids: memory_ids,
        messages: build_messages(set, session_id, memory_ids, state.window)
      }

      complete(turn, set, state)
    end
  end

  defp complete(turn, set, state) do
    case LlmHandler.chat(state.llm, turn.messages, tools: state.tools) do
      {:ok, {:tool_calls, calls}} ->
        # native function calling (folded from B): one ToolCall delta per
        # model call, emitted as it happens — never batched at turn end; the
        # delta carries the SEMANTIC args (the `args` property unwrapped from
        # the native arguments JSON — never the raw envelope)
        Enum.reduce(calls, state, fn {_provider_id, name, arguments}, state ->
          call_tool(turn, tool_key(state, name), native_args(arguments), state)
        end)

      {:ok, content} ->
        answer(turn, content, set, state)

      {:error, reason} ->
        # a failed exchange leaves the chain unanswered in the store;
        # resume/1 (or the next re-fire) picks it up — reject, never repair
        notify(state, {:llm_error, reason})
        state
    end
  end

  defp answer(turn, content, set, state) do
    ts = now()

    {:ok, signed} =
      Events.response_delta(state.llm.seed, ts, turn.request_id, 0.0, content, turn.memory_ids)

    response_wire = Wire.envelope(signed)
    state.sink.(response_wire)
    deliver(turn, response_wire["id"], content, set, ts, state)
    notify(state, {:answered, turn.request_id})

    state = %{
      state
      | answered: state.answered + 1,
        pending: Map.delete(state.pending, turn.request_id)
    }

    maybe_summarize(turn, set, ts, state)
  end

  # the delivery leg: message.sent via the prompt's channel — a prompt with
  # no channel gets a ResponseDelta but no delivery (never an invented one)
  defp deliver(turn, response_id, content, set, ts, state) do
    with {_claims, _sig} = element <- Map.get(set, turn.prompt_id),
         {:entity, channel_id, _ctx} <- pointer(elem(element, 0), "at"),
         {:ok, signed} <-
           Kyber.Events.message_sent(
             state.llm.seed,
             ts,
             response_id,
             "message:reply:" <> turn.prompt_id,
             channel_id,
             content
           ) do
      state.sink.(Wire.envelope(signed))
    else
      _no_channel -> :ok
    end
  end

  # ------------------------------------------------------------ tool chain

  defp call_tool(turn, tool_id, args, state) do
    {:ok, signed} = Events.tool_call(state.llm.seed, now(), tool_id, args, turn.request_id)
    wire = Wire.envelope(signed)
    state.sink.(wire)

    pending = Map.put(state.pending, wire["id"], %{turn: turn, tool_id: tool_id, args: args})
    notify(state, {:tool_called, wire["id"]})
    %{state | tool_calls: state.tool_calls + 1, pending: pending}
  end

  defp tool_result(_result_id, typed, state) do
    {:delta, call_id, _ctx} = typed.call

    case Map.get(state.pending, call_id) || rebuild_pending(state, call_id) do
      nil ->
        state

      %{turn: turn, tool_id: tool_id, args: args} ->
        set = state.store.()

        if answered?(set, turn.request_id) do
          %{state | skipped: state.skipped + 1, pending: Map.delete(state.pending, call_id)}
        else
          turn = %{
            turn
            | messages:
                turn.messages ++
                  [
                    %{
                      "role" => "assistant",
                      "content" => nil,
                      "tool_calls" => [
                        %{
                          "id" => provider_id(call_id),
                          "type" => "function",
                          "function" => %{
                            "name" => ToolExecutor.tool_name(tool_id),
                            "arguments" => args
                          }
                        }
                      ]
                    },
                    %{
                      "role" => "tool",
                      "tool_call_id" => provider_id(call_id),
                      "content" => typed.result
                    }
                  ]
          }

          state = %{state | pending: Map.delete(state.pending, call_id)}
          complete(turn, set, state)
        end
    end
  end

  # the refusal loop (T14 carry #1, closed pre-merge — proven live by the
  # AC4 run: with the default deny-all gate every tool call was refused and
  # the turn hung forever). A denied/refused GateDecision for a pending
  # call feeds the model the SAME assistant tool_calls message plus a
  # tool-role refusal, then re-completes the turn — the model re-plans
  # instead of the chain waiting on a ToolResult that never comes. The
  # executor's contract is untouched (still no ToolResult for refusals).
  defp refusal(call_id, typed, state) do
    case Map.get(state.pending, call_id) do
      nil ->
        state

      %{turn: turn, tool_id: tool_id, args: args} ->
        set = state.store.()

        if answered?(set, turn.request_id) do
          %{state | skipped: state.skipped + 1, pending: Map.delete(state.pending, call_id)}
        else
          reason = typed.reason || Atom.to_string(typed.verdict)

          turn = %{
            turn
            | messages:
                turn.messages ++
                  [
                    %{
                      "role" => "assistant",
                      "content" => nil,
                      "tool_calls" => [
                        %{
                          "id" => provider_id(call_id),
                          "type" => "function",
                          "function" => %{
                            "name" => ToolExecutor.tool_name(tool_id),
                            "arguments" => args
                          }
                        }
                      ]
                    },
                    %{
                      "role" => "tool",
                      "tool_call_id" => provider_id(call_id),
                      "content" => "refused: " <> reason
                    }
                  ]
          }

          state = %{state | pending: Map.delete(state.pending, call_id)}
          complete(turn, set, state)
        end
    end
  end

  # the registry-accurate name -> action-id map when wired (T12 action ids
  # carry dots — the syntactic fallback would misread `fs_read` as
  # `fs:read`); the T11b stub shape resolves syntactically either way
  defp tool_key(%{tool_keys: nil}, name), do: ToolExecutor.tool_key(name)
  defp tool_key(%{tool_keys: map}, name), do: Map.get(map, name, ToolExecutor.tool_key(name))

  # the provider tool-call id is a DETERMINISTIC function of the ToolCall
  # delta's content address — restart-stable, so a resumed chain reconstructs
  # the same assistant tool_calls message the API accepted (B's posture)
  defp provider_id(call_delta_id), do: "call_" <> String.slice(call_delta_id, 0, 24)

  # unwrap the `args` property from the native arguments JSON; anything not
  # shaped as {"args": <string>} rides through raw (reject, never repair —
  # the delta carries exactly what the model sent)
  defp native_args(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{"args" => args}} when is_binary(args) -> args
      _other -> arguments
    end
  end

  # the chain is the state: a restart lost the pending map, but the ToolCall
  # delta points at its request, and the request rebuilds the whole turn
  defp rebuild_pending(state, call_id) do
    set = state.store.()

    with {claims, _sig} <- Map.get(set, call_id),
         %{type: "ToolCall"} = call <- Schema.resolve(claims),
         {:delta, request_id, _} <- call.requestRef,
         {request_claims, _sig} <- Map.get(set, request_id),
         %{type: "InferenceRequested"} = request <- Schema.resolve(request_claims) do
      {:delta, prompt_id, _} = request.promptRef
      {:entity, session_id, _} = request.sessionId
      {:entity, tool_id, _} = call.tool
      memory_ids = for {:delta, id, _ctx} <- request.memoryPointers, do: id

      %{
        turn: %{
          request_id: request_id,
          prompt_id: prompt_id,
          session_id: session_id,
          memory_ids: memory_ids,
          messages: build_messages(set, session_id, memory_ids, state.window)
        },
        tool_id: tool_id,
        args: call.args
      }
    else
      _not_rebuildable -> nil
    end
  end

  # where did this request's chain stop? (resume/1's classification)
  defp chain_position(set, request_id) do
    calls =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "tool",
          match?(
            %{type: "ToolCall", requestRef: {:delta, ^request_id, _}},
            Schema.resolve(claims)
          ),
          do: {id, claims}

    case Enum.sort_by(calls, fn {_id, claims} -> claims.timestamp end) |> List.last() do
      nil ->
        :top

      {call_id, _claims} ->
        set
        |> Enum.find(fn {_id, {claims, _sig}} ->
          kind(claims) == "call" and
            match?(%{type: "ToolResult", call: {:delta, ^call_id, _}}, Schema.resolve(claims))
        end)
        |> case do
          {id, {claims, _sig}} -> {:tool_result, %{id: id, claims: claims}}
          nil -> :tool_waiting
        end
    end
  end

  # ----------------------------------------------------------- rehydration

  defp build_messages(set, session_id, memory_ids, window) do
    turns = ContextBuilder.conversation(set, session_id)
    {elided, windowed} = ContextBuilder.window(turns, window)

    memory_notes =
      for id <- memory_ids,
          {claims, _sig} <- [Map.get(set, id)],
          {:string, content} <- [pointer(claims, "content")],
          do: %{"role" => "system", "content" => "Memory: " <> content}

    summary_notes =
      for {_id, {claims, _sig}} <- Enum.sort_by(set, fn {_id, {c, _s}} -> c.timestamp end),
          declared_type(claims) == "ConversationSummary",
          match?({:entity, ^session_id, _}, pointer(claims, "sessionId")),
          {:string, content} <- [pointer(claims, "content")],
          do: %{"role" => "system", "content" => "Summary of earlier turns: " <> content}

    elision_note =
      case elided do
        [] -> []
        turns -> [%{"role" => "system", "content" => "#{length(turns)} earlier turns elided."}]
      end

    [%{"role" => "system", "content" => @system_prompt}] ++
      memory_notes ++
      summary_notes ++
      elision_note ++
      Enum.map(windowed, &%{"role" => &1.role, "content" => &1.content})
  end

  # -------------------------------------------------------------- machinery

  defp answered?(set, request_id) do
    Enum.any?(set, fn {_id, {claims, _sig}} ->
      kind(claims) == "requestRef" and
        match?({:delta, ^request_id, _ctx}, pointer(claims, "requestRef"))
    end)
  end

  # spine-8 checkpoint (folded from B): once a session's conversation exceeds
  # twice the window, emit ONE deterministic ConversationSummary covering the
  # elided head — the lens prefers it beyond its bound. Deterministic: the
  # summary claims the RESPONSE's timestamp and digests the covered turns, so
  # replaying the same store reproduces the same claim byte-for-byte (the
  # LLM-backed summarizer reactor is T11c's job).
  defp maybe_summarize(turn, set, ts, state) do
    turns = ContextBuilder.conversation(set, turn.session_id)

    if length(turns) > 2 * state.window and not summarized?(set, turn.session_id) do
      {elided, _kept} = Enum.split(turns, length(turns) - state.window)
      covered = Enum.map(elided, & &1.id)

      digest =
        elided
        |> Enum.map_join("|", & &1.content)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      first = elided |> hd() |> Map.fetch!(:timestamp) |> trunc()
      last = elided |> List.last() |> Map.fetch!(:timestamp) |> trunc()
      content = "Summary of turns #{first}..#{last}: #{digest}"

      case Events.conversation_summary(state.llm.seed, ts, turn.session_id, content, covered) do
        {:ok, signed} -> state.sink.(Wire.envelope(signed))
        _error -> :ok
      end
    end

    state
  end

  defp summarized?(set, session_id) do
    Enum.any?(set, fn {_id, {claims, _sig}} ->
      declared_type(claims) == "ConversationSummary" and
        match?({:entity, ^session_id, _ctx}, pointer(claims, "sessionId"))
    end)
  end

  # the no-sleep observation seam: tests (and the CLI's narrate mode) get a
  # message per completed engine action instead of polling
  defp notify(%{notify: pid}, event) when is_pid(pid), do: send(pid, {:engine, event})
  defp notify(_state, _event), do: :ok

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp declared_type(%{pointers: pointers}) do
    Enum.find_value(pointers, fn
      %{role: "type", target: {:entity, name, _ctx}} -> name
      _other -> nil
    end)
  end

  defp now, do: 1.0 * System.system_time(:millisecond)
end
