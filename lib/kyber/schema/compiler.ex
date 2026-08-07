defmodule Kyber.Schema.Compiler do
  @moduledoc """
  The pure schema core (T11a): compile a schema delta's claims into a field
  spec, and validate/resolve instance claims against a compiled set. No
  process, no I/O — the container (`Kyber.Schema`) and the genesis data
  (`Kyber.Schema.Genesis`) both lean on this module.

  Schema deltas use the substrate's normative envelope vocabulary
  (`rhizomatic.hyperschema.*` — rhizomatic SPEC-3 §5): `name`/`defines`/`alg`/
  `term`, where `term` is the hex of canonical CBOR. The term's `kind` is
  `"schema"` (fields: `name`, `kind`, `required`, `repeat`) or `"hyperschema"`
  (entity-resolution reading: `schema`, `root`). The inner term payload is
  kyber's T11a shape algebra (`alg` 0.0) — the substrate's L1/L3 evaluator has
  not landed in Elixir; the ENVELOPE is the substrate's normative vocabulary.

  A delta declares its lifecycle type with a `type` pointer,
  `{:entity, name, "instances"}` — the type IS an entity, and its instances
  are its backlink. Primitives (`string`/`number`/`boolean`) RIDE — small
  facts of the act, embedded; composites (`entity`/`delta`) POINT —
  references only.

  Validation is closed, like the witness's profile: a role the schema does
  not name is refused, never ignored — which is what structurally prevents
  any delta from embedding the conversation history. Reject, never repair.
  """

  alias Rhizomatic.{Cbor, Delta}

  @hyperschema "Schema"
  @envelope_roles ~w(type rhizomatic.hyperschema.name rhizomatic.hyperschema.defines
                     rhizomatic.hyperschema.alg rhizomatic.hyperschema.term retracts negates)
  @kinds %{
    "string" => :string,
    "number" => :number,
    "boolean" => :boolean,
    "entity" => :entity,
    "delta" => :delta
  }

  @type field :: %{kind: atom(), arity: :one | :maybe | :many}
  @type spec :: %{
          name: String.t(),
          version: float(),
          delta_id: String.t(),
          retracts: String.t() | nil,
          fields: %{String.t() => field()}
        }
  @type hyperschema :: %{
          name: String.t(),
          version: float(),
          delta_id: String.t(),
          retracts: String.t() | nil,
          schema: String.t() | nil,
          root: String.t() | nil
        }
  @type set :: %{schemas: %{String.t() => spec()}, hyperschemas: %{String.t() => hyperschema()}}
  @type hyperview :: %{id: String.t(), props: %{optional(String.t()) => [String.t()]}, reading: String.t() | nil}

  # ---------------------------------------------------------------- compile

  @doc """
  Compile a schema delta's claims into a spec. The schema delta is an
  instance of the hyperschema (`type` → `Schema`) carrying the envelope roles.
  Returns `{:ok, {:schema, spec}}`, `{:ok, {:hyperschema, hs}}`,
  `{:ok, {:negation, delta_id}}` (a negation delta retracting a schema by
  content address), or `{:error, reason}`.
  """
  @spec compile(Delta.claims(), String.t()) ::
          {:ok, {:schema, spec()} | {:hyperschema, hyperschema()} | {:negation, String.t()}}
          | {:error, term()}
  def compile(%{pointers: pointers}, delta_id) when is_list(pointers) do
    case declared_type(pointers) do
      {:ok, @hyperschema} -> compile_envelope(pointers, delta_id)
      _ -> negation(pointers)
    end
  end

  def compile(_, _), do: {:error, :malformed_claims}

  defp compile_envelope(pointers, delta_id) do
    with :ok <- envelope_roles_only(pointers),
         {:ok, name} <- one(pointers, "rhizomatic.hyperschema.name", &string_target/1),
         {:ok, _defines} <- one(pointers, "rhizomatic.hyperschema.defines", &defines_target/1),
         {:ok, _alg} <- maybe(pointers, "rhizomatic.hyperschema.alg", &number_target/1),
         {:ok, term_hex} <- one(pointers, "rhizomatic.hyperschema.term", &string_target/1),
         {:ok, retracts} <- maybe(pointers, "retracts", &retracts_target/1) do
      with {:ok, term} <- decode_term(term_hex) do
        case term do
          %{kind: "schema", name: ^name, version: version, fields: fields} ->
            spec = %{
              name: name,
              version: version,
              delta_id: delta_id,
              retracts: retracts,
              fields: Map.new(fields, &field_from_term/1)
            }

            {:ok, {:schema, spec}}

          %{kind: "hyperschema", name: ^name, version: version, schema: schema, root: root} ->
            {:ok,
             {:hyperschema,
              %{
                name: name,
                version: version,
                delta_id: delta_id,
                retracts: retracts,
                schema: schema,
                root: root
              }}}

          %{kind: kind} ->
            {:error, {:unknown_schema_kind, kind}}

          %{name: other} ->
            {:error, {:inconsistent_schema_delta, name, other}}
        end
      end
    end
  end

  defp negation(pointers) do
    case targets_for(pointers, "negates") do
      [] -> {:error, :not_a_schema_delta}
      [{:delta, id, _ctx} | _] -> {:ok, {:negation, id}}
      _ -> {:error, {:bad_negation_target}}
    end
  end

  defp decode_term(hex) do
    with {:ok, bin} <- Base.decode16(hex, case: :lower),
         {:ok, {:map, pairs}} <- Cbor.decode_exact(bin) do
      term_map(pairs)
    end
  end

  defp term_map(pairs) do
    fields =
      case List.keyfind(pairs, {:tstr, "fields"}, 0) do
        {_, {:arr, items}} -> Enum.map(items, &field_map/1)
        _ -> nil
      end

    with {:ok, kind} <- term_get(pairs, "kind"),
         {:ok, name} <- term_get(pairs, "name"),
         {:ok, version} <- term_get(pairs, "version"),
         :ok <- term_kind_check(kind) do
      case kind do
        "schema" when fields != nil ->
          {:ok, %{kind: kind, name: name, version: version, fields: fields}}

        "hyperschema" ->
          with {:ok, schema} <- term_get(pairs, "schema"),
               {:ok, root} <- term_get(pairs, "root") do
            {:ok, %{kind: kind, name: name, version: version, schema: schema, root: root}}
          end

        _ ->
          {:error, :malformed_schema_term}
      end
    end
  end

  defp term_kind_check("schema"), do: :ok
  defp term_kind_check("hyperschema"), do: :ok
  defp term_kind_check(other), do: {:error, {:unknown_schema_kind, other}}

  defp field_map({:map, pairs}) do
    with {:ok, name} <- term_get(pairs, "name"),
         {:ok, kind} <- term_get(pairs, "kind"),
         {:ok, required} <- term_get(pairs, "required"),
         {:ok, repeat} <- term_get(pairs, "repeat") do
      %{"name" => name, "kind" => kind, "required" => required, "repeat" => repeat}
    end
  end

  defp field_map(_), do: %{}

  defp term_get(pairs, key) do
    case List.keyfind(pairs, {:tstr, key}, 0) do
      {_k, value} -> unwrap(value)
      nil -> {:error, {:missing_term_key, key}}
    end
  end

  defp unwrap({:tstr, s}), do: {:ok, s}
  defp unwrap({:float, f}), do: {:ok, f}
  defp unwrap({:bool, b}), do: {:ok, b}
  defp unwrap({:arr, items}), do: {:ok, items}
  defp unwrap(_), do: {:error, :malformed_term_value}

  defp field_from_term(%{"name" => role, "kind" => kind, "required" => required, "repeat" => repeat}) do
    arity = if required, do: :one, else: if(repeat, do: :many, else: :maybe)

    case Map.fetch(@kinds, kind) do
      {:ok, kind_atom} -> {role, %{kind: kind_atom, arity: arity}}
      :error -> {role, %{kind: :invalid, arity: arity}}
    end
  end

  defp one(pointers, role, extract) do
    case targets_for(pointers, role) do
      [target] -> extract_or(extract, target, role)
      [] -> {:error, {:missing_role, role}}
      _ -> {:error, {:duplicate_role, role}}
    end
  end

  defp maybe(pointers, role, extract) do
    case targets_for(pointers, role) do
      [] -> {:ok, nil}
      [target] -> extract_or(extract, target, role)
      _ -> {:error, {:duplicate_role, role}}
    end
  end

  defp targets_for(pointers, role), do: for(%{role: ^role, target: t} <- pointers, do: t)

  defp extract_or(extract, target, role) do
    case extract.(target) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:bad_target, role}}
    end
  end

  defp string_target({:string, s}) when is_binary(s), do: {:ok, s}
  defp string_target(_), do: :error

  defp number_target({:number, n}) when is_float(n), do: {:ok, n}
  defp number_target(_), do: :error

  defp defines_target({:entity, name, "schema"}) when is_binary(name), do: {:ok, name}
  defp defines_target(_), do: :error

  defp retracts_target({:delta, id, "retracted"}) when is_binary(id), do: {:ok, id}
  defp retracts_target(_), do: :error

  defp envelope_roles_only(pointers) do
    case Enum.find(pointers, &(&1.role not in @envelope_roles)) do
      nil -> :ok
      %{role: role} -> {:error, {:unknown_role, role}}
    end
  end

  # --------------------------------------------------------------- validate

  @doc """
  Validate instance claims against a compiled schema set. A delta that
  declares a known type is checked strictly and resolved to its typed
  object; a delta that declares an unknown type — or declares none — is
  admitted `:raw` and never saturates typed handlers. Ill-shaped against a
  known schema: refused.
  """
  @spec validate(term(), %{optional(String.t()) => spec()}) ::
          {:ok, term()} | {:ok, :raw} | {:error, term()}
  def validate(%{timestamp: _, author: _, pointers: pointers} = claims, schemas)
      when is_list(pointers) do
    case declared_type(pointers) do
      :undeclared ->
        {:ok, :raw}

      {:error, _} = err ->
        err

      {:ok, name} ->
        case Map.fetch(schemas, name) do
          :error ->
            {:ok, :raw}

          {:ok, spec} ->
            with :ok <- check_fields(pointers, spec), do: {:ok, typed(claims, spec)}
        end
    end
  end

  def validate(_, _), do: {:error, :malformed_claims}

  defp declared_type(pointers) do
    case Enum.filter(pointers, &match?(%{role: "type"}, &1)) do
      [] -> :undeclared
      [%{target: {:entity, name, "instances"}}] when is_binary(name) -> {:ok, name}
      _ -> {:error, :bad_type_declaration}
    end
  end

  defp check_fields(pointers, spec) do
    groups = target_groups(pointers)

    with :ok <- closed(groups, spec),
         :ok <- arities(groups, spec) do
      kinds(groups, spec)
    end
  end

  defp target_groups(pointers) do
    pointers
    |> Enum.reject(&(&1.role == "type"))
    |> Enum.group_by(& &1.role, & &1.target)
  end

  defp closed(groups, spec) do
    case Enum.find(Map.keys(groups), &(not Map.has_key?(spec.fields, &1))) do
      nil -> :ok
      role -> {:error, {:unknown_role, role}}
    end
  end

  defp arities(groups, spec) do
    Enum.reduce_while(spec.fields, :ok, fn {role, %{arity: arity}}, :ok ->
      case {arity, length(Map.get(groups, role, []))} do
        {:one, 1} -> {:cont, :ok}
        {:one, 0} -> {:halt, {:error, {:missing_role, role}}}
        {:one, _} -> {:halt, {:error, {:duplicate_role, role}}}
        {:maybe, n} when n <= 1 -> {:cont, :ok}
        {:maybe, _} -> {:halt, {:error, {:duplicate_role, role}}}
        {:many, _} -> {:cont, :ok}
      end
    end)
  end

  defp kinds(groups, spec) do
    Enum.reduce_while(groups, :ok, fn {role, targets}, :ok ->
      %{kind: kind} = spec.fields[role]

      case Enum.find(targets, &(kind_of(&1) != kind)) do
        nil -> {:cont, :ok}
        _ -> {:halt, {:error, {:bad_target_kind, role, kind}}}
      end
    end)
  end

  defp kind_of({:string, _}), do: :string
  defp kind_of({:number, _}), do: :number
  defp kind_of({:boolean, _}), do: :boolean
  defp kind_of({:entity, _, _}), do: :entity
  defp kind_of({:delta, _, _}), do: :delta
  defp kind_of(_), do: :invalid

  # ---------------------------------------------------------------- resolve

  # Build the typed object: ride kinds shed their tag, point kinds stay
  # tagged tuples (the witness's idiom — never coerced). The generated struct
  # is used only when it still fits the live schema; the runtime authority
  # stays in the store, so an evolved schema falls back to a plain typed map
  # rather than trusting a stale compile-time struct.
  defp typed(claims, spec) do
    groups = target_groups(claims.pointers)

    fields =
      Map.new(spec.fields, fn {role, %{kind: kind, arity: arity}} ->
        values = groups |> Map.get(role, []) |> Enum.map(&unwrap(kind, &1))

        value =
          case arity do
            :many -> values
            :one -> hd(values)
            :maybe -> List.first(values)
          end

        {String.to_atom(role), value}
      end)

    attrs =
      Map.merge(%{type: spec.name, author: claims.author, timestamp: claims.timestamp}, fields)

    mod = Module.concat(Kyber.Schema, spec.name)

    if fitting_struct?(mod, attrs), do: struct(mod, attrs), else: attrs
  end

  defp unwrap(:string, {:string, s}), do: s
  defp unwrap(:number, {:number, n}), do: n
  defp unwrap(:boolean, {:boolean, b}), do: b
  defp unwrap(_point, target), do: target

  defp fitting_struct?(mod, attrs) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 1) and
      Enum.all?(Map.keys(attrs), &Map.has_key?(struct(mod), &1))
  end

  # -------------------------------------------------------- entity gathering

  @doc """
  The bounded entity gather (spine 2, T11): every delta in `delta_set`
  pointing at `entity_id`, grouped by pointer role, plus the reading
  hyperschema that named the resolution (by root prefix — `session:…`
  resolves at the `Session` reading). Provenance-complete — entries are
  delta ids, never resolved views.
  """
  @spec resolve_entity(String.t(), Kyber.DeltaSet.t(), %{optional(String.t()) => hyperschema()}) ::
          {:ok, hyperview()}
  def resolve_entity(entity_id, delta_set, hyperschemas) do
    root = entity_id |> String.split(":") |> hd()

    reading =
      hyperschemas
      |> Map.values()
      |> Enum.find(fn hs -> hs.root == root end)
      |> case do
        nil -> nil
        hs -> hs.name
      end

    props =
      Enum.reduce(delta_set, %{}, fn {delta_id, {claims, _sig}}, acc ->
        Enum.reduce(claims.pointers, acc, fn %{role: role, target: target}, acc ->
          case target do
            {:entity, ^entity_id, _} -> Map.update(acc, role, [delta_id], &[delta_id | &1])
            _ -> acc
          end
        end)
      end)
      |> Map.new(fn {role, ids} -> {role, Enum.sort(ids)} end)

    {:ok, %{id: entity_id, props: props, reading: reading}}
  end
end
