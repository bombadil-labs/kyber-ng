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

  alias Kyber.{DurableStore, Gather, Keys}
  alias Kyber.Agent.{Action, ContextBuilder, Engine, LlmHandler, MemoryPort, Profile, ToolExecutor}
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
  workspace), `:notify` (pid for engine events), `:profile` (T14g G5 — a
  declared ProfileSet name; an unknown/undeclared name — whitespace-only
  included (M7) — refuses loudly with `{:error, {:unknown_profile, name}}`;
  default = the ABSENCE of selection), `:operator_seed` (T14g R1 — the
  operator's attestation seed; `author_for_seed/1` is derived ONCE from it
  at boot into the boot context's `operator_author`; the nil-seed leg is
  FAIL-CLOSED — no operator seed => no identity block, no crash). Returns
  `{:ok, engine_pid, resume_report}`.
  """
  @spec attach(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def attach(opts) do
    keyring_dir = Keyword.fetch!(opts, :keyring_dir)

    with {:ok, seed} <- Keys.load_agent_seed(keyring_dir),
         {:ok, llm} <- llm_handler(opts, seed),
         {:ok, boot} <- boot_context(opts) do
      memory = Keyword.get(opts, :memory, {MemoryPort.Stub, %{}})
      tools = Keyword.get(opts, :tools, default_tools(opts))
      # T14g (G6/L1): the profile's capability subset NARROWS the registry —
      # Map.take(registry, allow_tool) on the SINGLE `tools` var feeding
      # BOTH the engine specs AND the executor registry (a one-sided
      # intersect either advertises dead tools or leaves profile-excluded
      # tools executable); the boot gate is preserved (agent.ex:67) — a
      # profile can never conjure an allow via Gate.new.
      tools = profile_tools(tools, boot)

      {:ok, engine} =
        Engine.start_link(
          name: nil,
          llm: llm,
          window: Keyword.get(opts, :window, 8),
          tools: ToolExecutor.tool_specs(tools),
          tool_keys: ToolExecutor.tool_key_map(tools),
          notify: Keyword.get(opts, :notify),
          boot: boot
        )

      {:ok, _ref} =
        Gather.subscribe("received", ContextBuilder.handler(seed: seed, memory: memory))

      {:ok, _ref} = Gather.subscribe("promptRef", Engine.handler(engine))
      {:ok, _ref} = Gather.subscribe("call", Engine.handler(engine))
      # the refusal loop (T14 carry #1): GateDecision deltas route to the
      # engine so a denied/refused call comes back to the model — without
      # this the turn waits forever on a ToolResult that never comes
      {:ok, _ref} = Gather.subscribe("decides", Engine.handler(engine))

      {:ok, _ref} =
        Gather.subscribe(
          "tool",
          ToolExecutor.handler(
            seed: seed,
            tools: tools,
            gate: Keyword.get(opts, :gate, Gate.new()),
            context: Keyword.get(opts, :context, default_context(opts)),
            # T14g (M2): the R1 boot context threads into the executor too —
            # the tool-side policy layers are profile-aware under a profile
            boot: boot
          )
        )

      {:ok, engine, Engine.resume(engine)}
    end
  end

  # T14g (R1/G5): derive the ONE boot context {profile | nil, operator_author
  # | nil} at attach. The operator_author is derived ONCE from the
  # :operator_seed — author_for_seed(nil) RAISES, so the nil-seed leg never
  # calls it: no operator seed => operator_author nil => no identity block,
  # never a crash (fail-closed). A :profile name resolves against the
  # boot-constant author's ProfileSet stream; unresolvable (unknown OR
  # whitespace-only (M7) OR no operator seed to attest with) refuses LOUDLY
  # with {:error, {:unknown_profile, name}} — no silent fallback to a
  # profile-less boot (that is the leak).
  defp boot_context(opts) do
    profile = Keyword.get(opts, :profile)
    operator_seed = Keyword.get(opts, :operator_seed)

    case {profile, operator_seed} do
      {nil, _seed} ->
        {:ok, {nil, maybe_author(operator_seed)}}

      {_name, nil} ->
        {:error, {:unknown_profile, profile}}

      {name, seed} ->
        author = Keys.author_for_seed(seed)

        case Profile.resolve(store_set(), author, name) do
          {:ok, _view} -> {:ok, {name, author}}
          :not_found -> {:error, {:unknown_profile, name}}
        end
    end
  end

  # the G6 construction-time intersect: under a profile the registry is
  # Map.take(registry, allow_tool) — NARROWS only; a tool absent from the
  # boot registry cannot be conjured. Profile-less boots pass through.
  defp profile_tools(tools, {nil, _author}), do: tools

  defp profile_tools(tools, {name, author}) do
    case Profile.resolve(store_set(), author, name) do
      {:ok, view} -> Map.take(tools, view.allow_tool)
      # unreachable at attach (boot_context already refused); fail-closed
      # if the fold changed under us
      :not_found -> %{}
    end
  end

  defp maybe_author(nil), do: nil
  defp maybe_author(seed), do: Keys.author_for_seed(seed)

  defp store_set do
    case Process.whereis(Kyber.DurableStore) do
      nil -> %{}
      _pid -> Kyber.DurableStore.set()
    end
  end

  # a workspace boot opts into the real action registry AND the memory +
  # skill tool surfaces (T14f D9/H4): the ATTACH surface is the only
  # workspace-aware surface in the repo — a workspace attach boot sees
  # `memory.read` and the skill tools by default; the stub remains the
  # no-workspace default (A/B behind the one `:tools` seam). The url/memory
  # policy layers abstain on skill ids by membership and the registry keys
  # don't collide (Action.registry() is fs/sh/http), so the merge's blast
  # radius is clean. Both boot paths still default to `Gate.new()` —
  # fail-closed on every call (L7).
  defp default_tools(opts) do
    case Keyword.get(opts, :workspace) do
      nil ->
        ToolExecutor.stub_tools()

      _workspace ->
        store_fn = fn -> DurableStore.set() end

        Action.registry()
        |> Map.merge(ToolExecutor.memory_tools(store_fn))
        |> Map.merge(ToolExecutor.skill_tools(store_fn))
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
