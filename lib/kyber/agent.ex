defmodule Kyber.Agent do
  @moduledoc """
  The inference-chain stack (T11b), wired onto a BOOTED daemon: the context
  builder on `"received"`, the engine on `"promptRef"` (requests) and
  `"call"` (tool results), the tool executor on `"tool"`. The daemon must be
  booted with `loop: :none` — otherwise the T10 ack loop answers first (the
  deterministic fallback, AC9).

  `attach/1` subscribes the handlers into the CURRENT gather (subscriptions
  are runtime state — a re-booted daemon needs a re-attach), starts an
  anonymous engine, and resumes any chains the store left unfinished (the
  chain is the state).
  """

  alias Kyber.{Gather, Keys}
  alias Kyber.Agent.{Action, ContextBuilder, Engine, LlmHandler, MemoryPort, ToolExecutor}
  alias Kyber.Agent.Action.Gate

  @doc """
  Wire the stack. Options: `:keyring_dir` (required — the agent seed the
  daemon minted), `:llm` (a built `Kyber.Agent.LlmHandler`; or pass
  `:api_key` and one is built on the Moonshot defaults), `:window`,
  `:memory` (`{module, state}`, default the stub retriever), `:tools`
  (executor registry — stub closures or the T12 action registry; with
  `:workspace` and no `:tools` the real action registry is the default),
  `:workspace` (the T12 action surface's workspace root), `:gate` (a
  `Kyber.Agent.Action.Gate`, default an empty gate — fail closed),
  `:context` (the action context, default `Action.context/1` on the
  workspace), `:notify` (pid for engine events). Returns
  `{:ok, engine_pid, resume_report}`.
  """
  @spec attach(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def attach(opts) do
    keyring_dir = Keyword.fetch!(opts, :keyring_dir)

    with {:ok, seed} <- Keys.load_agent_seed(keyring_dir),
         {:ok, llm} <- llm_handler(opts, seed) do
      memory = Keyword.get(opts, :memory, {MemoryPort.Stub, %{}})
      tools = Keyword.get(opts, :tools, default_tools(opts))

      {:ok, engine} =
        Engine.start_link(
          name: nil,
          llm: llm,
          window: Keyword.get(opts, :window, 8),
          tools: ToolExecutor.tool_specs(tools),
          tool_keys: ToolExecutor.tool_key_map(tools),
          notify: Keyword.get(opts, :notify)
        )

      {:ok, _ref} =
        Gather.subscribe("received", ContextBuilder.handler(seed: seed, memory: memory))

      {:ok, _ref} = Gather.subscribe("promptRef", Engine.handler(engine))
      {:ok, _ref} = Gather.subscribe("call", Engine.handler(engine))

      {:ok, _ref} =
        Gather.subscribe(
          "tool",
          ToolExecutor.handler(
            seed: seed,
            tools: tools,
            gate: Keyword.get(opts, :gate, Gate.new()),
            context: Keyword.get(opts, :context, default_context(opts))
          )
        )

      {:ok, engine, Engine.resume(engine)}
    end
  end

  # a workspace boot opts into the real action registry; without one the
  # T11b stub tools stay the default (A/B behind the one `:tools` seam)
  defp default_tools(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> ToolExecutor.stub_tools()
      _workspace -> Action.registry()
    end
  end

  defp default_context(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> %{}
      workspace -> Action.context(workspace: workspace)
    end
  end

  defp llm_handler(opts, seed) do
    case Keyword.get(opts, :llm) do
      %LlmHandler{} = llm -> {:ok, llm}
      nil -> LlmHandler.new(seed: seed, api_key: Keyword.get(opts, :api_key))
    end
  end
end
