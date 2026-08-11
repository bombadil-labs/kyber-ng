defmodule Kyber.Agent.Tools do
  @moduledoc """
  The workspace-aware default tool seam (T14j C1 — the completion gate's
  `lib/kyber/agent/tools.ex` deliverable). The ONE implementation of
  `default_tools/1` joins the tool-map family (stub | the real action
  registry + memory + skill tools) and the boot-resolved action context,
  returning the `{tools, context}` TUPLE. `ToolExecutor.default_tools/1`
  delegates here — the executor is the spec-cited consumer home
  (reactor.ex:451 / :503 / :510); this module is the file home.

  Absent `:workspace` => stub tools + `%{}` context, byte-identical to
  today. EXPLICIT-TOOLS-WINS (M1): `Keyword.get(:tools, default)` keeps the
  seam — an explicit `:tools` registry is used AS-IS (the profile intersect
  still narrows it); the workspace default applies ONLY when `:tools` is
  absent. The tools value is ALWAYS a MAP (M5) — never a list registry,
  which the executor's `Map.fetch` crashes on with BadMapError.
  """

  alias Kyber.Agent.{Action, ToolExecutor}

  @doc """
  The workspace-aware default: `{tools, context}`. Explicit `:tools` and
  `:context` win; absent `:workspace` => the stub + `%{}` (byte-identical).
  """
  @spec default_tools(keyword()) :: {map(), map()}
  def default_tools(opts) do
    tools = Keyword.get(opts, :tools, workspace_tools(opts))
    context = Keyword.get(opts, :context, workspace_context(opts))
    {tools, context}
  end

  # a workspace boot opts into the real action registry AND the memory +
  # skill tool surfaces (the T14f D9 family — attach's private default,
  # re-homed so the reactor path threads the SAME default); no workspace =>
  # the stub, byte-identical to today
  defp workspace_tools(opts) do
    case Keyword.get(opts, :workspace) do
      nil ->
        ToolExecutor.stub_tools()

      _workspace ->
        store_fn = fn -> Kyber.DurableStore.set() end

        Action.registry()
        |> Map.merge(ToolExecutor.memory_tools(store_fn))
        |> Map.merge(ToolExecutor.skill_tools(store_fn))
    end
  end

  # the boot-resolved action context: a workspace boot binds the actions to
  # the workspace root (the context-parity half of C1 — an unthreaded
  # context answers the arg-error-string class on every fs/sh call)
  defp workspace_context(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> %{}
      workspace -> Action.context(workspace: workspace)
    end
  end
end
