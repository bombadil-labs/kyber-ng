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
  alias Kyber.Agent.{ContextBuilder, Engine, LlmHandler, MemoryPort, ToolExecutor}

  @doc """
  Wire the stack. Options: `:keyring_dir` (required — the agent seed the
  daemon minted), `:llm` (a built `Kyber.Agent.LlmHandler`; or pass
  `:api_key` and one is built on the Moonshot defaults), `:window`,
  `:memory` (`{module, state}`, default the stub retriever), `:tools`
  (executor registry), `:notify` (pid for engine events). Returns
  `{:ok, engine_pid, resume_report}`.
  """
  @spec attach(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def attach(opts) do
    keyring_dir = Keyword.fetch!(opts, :keyring_dir)

    with {:ok, seed} <- Keys.load_agent_seed(keyring_dir),
         {:ok, llm} <- llm_handler(opts, seed) do
      memory = Keyword.get(opts, :memory, {MemoryPort.Stub, %{}})

      {:ok, engine} =
        Engine.start_link(
          name: nil,
          llm: llm,
          window: Keyword.get(opts, :window, 8),
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
            tools: Keyword.get(opts, :tools, ToolExecutor.stub_tools())
          )
        )

      {:ok, engine, Engine.resume(engine)}
    end
  end

  defp llm_handler(opts, seed) do
    case Keyword.get(opts, :llm) do
      %LlmHandler{} = llm -> {:ok, llm}
      nil -> LlmHandler.new(seed: seed, api_key: Keyword.get(opts, :api_key))
    end
  end
end
