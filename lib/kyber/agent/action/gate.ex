defmodule Kyber.Agent.Action.Gate do
  @moduledoc """
  The permission gate (T12): the boundary every action crosses BEFORE it
  runs — no action executes without a gate decision, and every decision the
  executor acts on is attested as a `GateDecision` delta (auditable).

  Policies are `:allow` / `:deny` / `:prompt` per action name, resolved at
  boot from opts — human-issued authority, never learned from the store
  (provenance as authority, the T11c rule extended to actions: an
  agent-written claim cannot grant itself a permission).

  Fail closed: an action with no policy entry takes the `:default`
  (`:deny` unless the boot opts say otherwise), and a `:prompt` policy with
  no prompt answer wired is a REFUSE. A denied or refused call emits NO
  `ToolResult` — reject, never repair.
  """

  @type policy :: :allow | :deny | :prompt
  @type verdict :: :allow | :deny | :refuse
  @type decision :: %{verdict: verdict(), policy: policy(), reason: String.t() | nil}
  @type prompt_handler :: (String.t(), String.t() | nil -> :allow | :deny)
  @type t :: %__MODULE__{
          policies: %{String.t() => policy()},
          default: policy(),
          prompt_handler: prompt_handler() | nil
        }

  defstruct policies: %{}, default: :deny, prompt_handler: nil

  @doc """
  Resolve a gate from boot opts. Two forms: a plain `%{action => policy}`
  map, or a keyword list with `:allow` / `:deny` / `:prompt` name lists
  plus `:default` (the unlisted-action policy, itself `:deny` by default —
  fail closed) and `:prompt_handler` (the wired prompt answer,
  `(action, args -> :allow | :deny)`).
  """
  @spec new(map() | keyword()) :: t()
  def new(opts \\ [])

  def new(policies) when is_map(policies) do
    %__MODULE__{policies: policies}
  end

  def new(opts) when is_list(opts) do
    policies =
      for {policy, names} <- Keyword.take(opts, [:allow, :deny, :prompt]),
          name <- names,
          into: %{},
          do: {name, policy}

    %__MODULE__{
      policies: policies,
      default: Keyword.get(opts, :default, :deny),
      prompt_handler: Keyword.get(opts, :prompt_handler)
    }
  end

  @doc """
  The decision for one action call. `decide/2` decides on the action name
  alone; `decide/3` also hands the raw args to a wired prompt handler.
  """
  @spec decide(t(), String.t()) :: decision()
  def decide(gate, action), do: decide(gate, action, nil)

  @spec decide(t(), String.t(), String.t() | nil) :: decision()
  def decide(%__MODULE__{} = gate, action, args) do
    case Map.fetch(gate.policies, action) do
      {:ok, :allow} ->
        %{verdict: :allow, policy: :allow, reason: nil}

      {:ok, :deny} ->
        %{verdict: :deny, policy: :deny, reason: "denied by policy"}

      {:ok, :prompt} ->
        prompt_decision(gate.prompt_handler, action, args)

      :error ->
        default_decision(gate, action, args)
    end
  end

  # an unlisted action takes the boot-resolved default, audited AS a default
  defp default_decision(%__MODULE__{default: :allow}, _action, _args),
    do: %{verdict: :allow, policy: :allow, reason: "allowed by the default policy"}

  defp default_decision(%__MODULE__{default: :deny}, _action, _args),
    do: %{verdict: :deny, policy: :deny, reason: "no policy entry (default deny — fail closed)"}

  defp default_decision(%__MODULE__{default: :prompt} = gate, action, args),
    do: prompt_decision(gate.prompt_handler, action, args)

  # fail closed: no wired answer, or an answer the gate cannot read, refuses
  defp prompt_decision(nil, _action, _args) do
    %{
      verdict: :refuse,
      policy: :prompt,
      reason: "prompt policy with no prompt answer wired (fail closed)"
    }
  end

  defp prompt_decision(handler, action, args) do
    case handler.(action, args) do
      :allow ->
        %{verdict: :allow, policy: :prompt, reason: "prompt answer wired: allow"}

      :deny ->
        %{verdict: :deny, policy: :prompt, reason: "prompt answer wired: deny"}

      other ->
        %{
          verdict: :refuse,
          policy: :prompt,
          reason: "unreadable prompt answer " <> inspect(other) <> " (fail closed)"
        }
    end
  end
end
