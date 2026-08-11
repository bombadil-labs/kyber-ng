defmodule Kyber.Agent.Profile do
  @moduledoc """
  The profile machinery (T14g G5/G8): a profile is a POLICY-SHAPED BINDING
  — (identity view, epoch-bounded memory/skill visibility, capability
  subset) — declared as `ProfileSet` deltas, never a storage mechanism.
  The declaration carries the SAME author filter as identity primitives
  (H2c — an agent-declared newer ProfileSet under an expected name with
  `families: ["memory"]` would escalate visibility at the next attach; the
  filter closes it). `{timestamp, id}` ordering applies WITHIN the author's
  stream (H2); two live same-name heads resolve latest-wins — never a fork
  error (G2).

  Selection is the ATTACH surface (G5): the default profile is the ABSENCE
  of selection (no magic names); an unknown/undeclared name — whitespace-
  only included (M7/N3 — fold-inert at the LOOKUP) — refuses loudly at
  attach with `{:error, {:unknown_profile, name}}`.

  Writability (G1/G7): soul/user/operator AND profile declarations are
  OPERATOR-ATTESTED (the boot-constant author; agent-signed claims are
  door-admissible but fold-inert — AC3). Agent-writable per-profile state
  rides the MEMORY seam under the `profile:<id>:` NAMING CONVENTION (never
  a fifth primitive) — with EXACT-MATCH allowlist semantics (L4:
  `entity_id in allow_entities`, NO prefix matching — every
  `profile:<id>:` note entity must be individually allowlisted in the
  profile's memory epoch).

  The epoch wiring (G8) is LIVE family-name references: the ProfileSet
  carries family NAMES, resolved at read via `Policy.current/2` — never
  compiled-in allowlists. A profile that names no family gets its OWN
  derived fail-closed defaults `"memory:profile/<name>"` /
  `"skill:profile/<name>"` (empty-until-seeded epochs, never the broad boot
  epochs). Multi-family combination = UNION (M3): the profile sees an
  entity if ANY named family governs it; a forked or unseeded family
  contributes NOTHING (governs no entity — omit THAT family only, never
  omit-all when other families are clean, and never fail-open).
  """

  alias Kyber.{DeltaSet, Keys, Schema}
  alias Kyber.Agent.{Liveness, Policy}

  @type view :: %{
          name: String.t(),
          rules: String.t(),
          rides: [String.t()],
          allow_tool: [String.t()],
          families: [String.t()],
          head: String.t()
        }

  @doc """
  The ProfileSet fold: the LIVE order-head declaration of `name` over the
  boot-constant author's stream. `{:ok, view}` when the head is live;
  `:not_found` when the author has no `name` declaration (or the head is
  retracted), INCLUDING whitespace-only names (M7 — fold-inert at the
  lookup: door-admissible, never resolvable). Pure, deterministic.
  """
  @spec resolve(DeltaSet.t(), String.t(), String.t()) :: {:ok, view()} | :not_found
  def resolve(set, operator_author, name)
      when is_binary(operator_author) and is_binary(name) do
    if String.trim(name) == "" do
      :not_found
    else
      ordered =
        (for {id, {claims, _sig}} <- set,
             claims.author == operator_author,
             %{
               type: "ProfileSet",
               profile: {:entity, ^name, _ctx},
               rules: rules,
               rides: rides,
               allow_tool: allow_tool,
               families: families
             } <- [Schema.resolve(claims)],
             do: {id, rules, rides, allow_tool, families, claims.timestamp})
        |> Enum.sort_by(fn {id, _r, _rides, _tools, _fam, ts} -> {ts, id} end)

      case ordered do
        [] ->
          :not_found

        _ ->
          {head_id, rules, rides, allow_tool, families, _ts} = List.last(ordered)

          if Liveness.live?(set, head_id, author_filter(operator_author)) do
            {:ok,
             %{
               name: name,
               rules: rules,
               # the many-entity role resolves to TAGGED tuples — the view
               # carries the plain identity:<id> refs (M5b)
               rides: for({:entity, id, _ctx} <- rides, do: id),
               allow_tool: allow_tool,
               families: families,
               head: head_id
             }}
          else
            :not_found
          end
      end
    end
  end

  @doc """
  The profile's memory-family epoch: the UNION (M3) of `allow_entities`
  over the profile's named families that resolve to a live epoch — or the
  derived fail-closed default `"memory:profile/<name>"` when the profile
  names no family (G8). ALWAYS `{:ok, epoch}` under a profile: a union of
  nothing governs nothing — the `:none` gather arm is FLIPPED to omit-all
  (N1), never the legacy fail-open include-all.
  """
  @spec memory_epoch(DeltaSet.t(), view()) :: {:ok, Policy.epoch()}
  def memory_epoch(set, view), do: union_epoch(set, view, "memory:profile/")

  @doc """
  The profile's skill-family epoch: the same UNION over the profile's
  families — or the derived default `"skill:profile/<name>"` (G8/M2). The
  skill lens and the tool-side `skill_policy` layer both source from here
  under a profile.
  """
  @spec skill_epoch(DeltaSet.t(), view()) :: {:ok, Policy.epoch()}
  def skill_epoch(set, view), do: union_epoch(set, view, "skill:profile/")

  # M3: UNION over the live families; :none and {:error, :forked} families
  # contribute nothing (govern no entity — omit THAT family only). The
  # derived fail-closed default rides when the profile names no family.
  defp union_epoch(set, view, derived_prefix) do
    families =
      case view.families do
        [] -> [derived_prefix <> view.name]
        named -> named
      end

    allowed =
      for family <- families,
          {:ok, epoch} <- [Policy.current(set, family)],
          entity_id <- epoch.allow_entities,
          into: MapSet.new(),
          do: entity_id

    {:ok, %{id: nil, allow_hosts: [], allow_schemes: [], allow_entities: MapSet.to_list(allowed)}}
  end

  # the H2c author filter: ProfileSet declarations carry the SAME filter as
  # identity primitives (an agent cannot declare profiles out-of-band)
  defp author_filter(operator_author), do: fn claims -> claims.author == operator_author end

  # ------------------------------------------------------- the boot context

  @doc """
  The ONE boot-context resolution (T14i H7/H8 — shared by `Kyber.Agent.attach/1`,
  the reactor's engine construction, and the channel daemon's boot guard; T14g
  R1/G5): derive the boot tuple `{profile | nil, operator_author | nil}` from
  the `:profile` and `:operator_seed` opts. The operator_author is derived ONCE
  from the seed — `author_for_seed(nil)` RAISES, so the nil-seed leg never calls
  it. A `:profile` name resolves against the boot-constant author's ProfileSet
  stream; unresolvable (unknown OR whitespace-only (M7) OR no operator seed to
  attest with) refuses LOUDLY with `{:error, {:unknown_profile, name}}` — the
  `{_name, nil}` refusal — never a silent fallback to a profile-less boot.
  """
  @spec boot_context(keyword()) :: {:ok, {String.t() | nil, String.t() | nil}} | {:error, term()}
  def boot_context(opts) do
    profile = Keyword.get(opts, :profile)
    operator_seed = Keyword.get(opts, :operator_seed)

    case {profile, operator_seed} do
      {nil, _seed} ->
        {:ok, {nil, maybe_author(operator_seed)}}

      {_name, nil} ->
        {:error, {:unknown_profile, profile}}

      {name, seed} ->
        author = Keys.author_for_seed(seed)

        case resolve(store_set(), author, name) do
          {:ok, _view} -> {:ok, {name, author}}
          :not_found -> {:error, {:unknown_profile, name}}
        end
    end
  end

  @doc """
  The ONE construction-time capability intersect (T14i H8 — the shared helper
  extracted from attach's private `profile_tools/2`, agent.ex:127-137; T14g
  G6/L1): under a profile the registry is `Map.take(registry, allow_tool)` —
  NARROWS only; a tool absent from the boot registry cannot be conjured.
  Consumed by BOTH `Agent.attach/1` AND the reactor's engine construction
  (reactor.ex:441) — never two intersects, never a private duplicate.
  Profile-less boots pass through.
  """
  @spec intersect_tools(map(), {String.t() | nil, String.t() | nil}) :: map()
  def intersect_tools(tools, {nil, _author}), do: tools

  def intersect_tools(tools, {name, author}) do
    case resolve(store_set(), author, name) do
      {:ok, view} -> Map.take(tools, view.allow_tool)
      # unreachable at boot (boot_context already refused); fail-closed
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
end
