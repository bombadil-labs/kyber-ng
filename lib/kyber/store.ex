defmodule Kyber.Store do
  @moduledoc """
  The door (spec/04-persistence.md §3): every delta enters through one door —
  **verify, then merge**. Input is the pinned wire envelope map (T1 rev 2):

      %{"id" => "<hex content address>",
        "claims" => %{"timestamp" => ts, "author" => "ed25519:<hex>", "pointers" => [...]},
        "sig" => "<hex ed25519 signature>"}

  The door's sequence: parse the claims (JSON debug profile) → recompute the
  id and refuse a mismatch with the envelope's `"id"` → refuse unsigned deltas
  (D1 — no internal dialect) → verify the signature with the witness's strict
  `Rhizomatic.Signer` (boolean; the door turns `false` into
  `{:error, :bad_signature}`) → merge into the in-memory delta set.

  The store only learns: a rejected delta leaves the set untouched; a
  duplicate is a no-op (union).

  Lifecycle: start the door with `start_link/1` (it holds the set in an
  Agent); `append/1` is the stateful entry, `admit/2` is the pure door for
  replay and tests.
  """

  use Agent

  alias Kyber.DeltaSet
  alias Rhizomatic.{Delta, Profile, Signer}

  @doc "Start the door with an empty delta set. Singleton (multi-store is a later ticket)."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> DeltaSet.new() end, name: __MODULE__)
  end

  @doc """
  The stateful door: verify, then merge. Returns `:ok` or `{:error, reason}`.
  Returns `{:error, :store_not_running}` when the door has not been started —
  never crashes the caller.
  """
  @spec append(map()) :: :ok | {:error, term()}
  def append(wire) when is_map(wire) do
    if Process.whereis(__MODULE__) do
      Agent.get_and_update(__MODULE__, fn set ->
        case admit(wire, set) do
          {:ok, new_set} -> {:ok, new_set}
          {:error, _} = err -> {err, set}
        end
      end)
    else
      {:error, :store_not_running}
    end
  end

  def append(_), do: {:error, :malformed_envelope}

  @doc """
  The pure door: verify, then merge into `set`. Returns `{:ok, set}` or
  `{:error, reason}` — the machinery `append/1` delegates to, and the shape
  replay will use (re-verify + re-merge, spec/04-persistence.md §2).
  """
  @spec admit(map(), DeltaSet.t()) :: {:ok, DeltaSet.t()} | {:error, term()}
  def admit(wire, set) when is_map(wire) do
    with :ok <- check_closed(wire),
         {:ok, claims} <- parse_claims(wire),
         :ok <- check_id(wire, claims),
         :ok <- check_signed(wire),
         :ok <- check_signature(wire, claims) do
      {:ok, DeltaSet.merge(set, %{Delta.id_hex(claims) => {claims, wire["sig"]}})}
    end
  end

  def admit(_, _), do: {:error, :malformed_envelope}

  @doc """
  The current delta set — explicit state polling for tests and views. Returns
  `{:error, :store_not_running}` when the door has not been started.
  """
  @spec set() :: DeltaSet.t() | {:error, :store_not_running}
  def set do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      {:error, :store_not_running}
    end
  end

  # ---------------------------------------------------------------- the door

  # the envelope is closed, exactly like the witness's closed profile: unknown
  # wire keys are refused, not ignored — asymmetric admission at the trust
  # boundary is how loam-compatible doors drift apart
  @envelope_keys ~w(id claims sig)

  defp check_closed(wire) do
    case Map.keys(wire) -- @envelope_keys do
      [] -> :ok
      [unknown | _] -> {:error, {:unknown_key, :envelope, unknown}}
    end
  end

  defp parse_claims(wire) do
    case Map.fetch(wire, "claims") do
      {:ok, claims} when is_map(claims) ->
        # the witness's parse uses fuzzy key-matching (jaro_distance) for
        # unknown-key suggestions and CRASHES (FunctionClauseError) on
        # non-string keys — the door refuses them BEFORE parsing (P5 finding
        # 3, discovered by the durable-refusal pin): reject, never repair
        if deep_string_keys?(claims) do
          Profile.parse_claims(claims)
        else
          {:error, :claims_non_string_key}
        end

      {:ok, _claims} ->
        {:error, :malformed_claims}

      :error ->
        {:error, {:missing_key, :envelope, "claims"}}
    end
  end

  # deep: a nested atom key inside pointers/targets would crash the same way
  defp deep_string_keys?(map) when is_map(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) -> deep_string_keys?(value)
      _ -> false
    end)
  end

  defp deep_string_keys?(list) when is_list(list) do
    Enum.all?(list, &deep_string_keys?/1)
  end

  defp deep_string_keys?(_), do: true

  # content addressing: a delta whose id does not match its claims never lands
  defp check_id(wire, claims) do
    case Map.fetch(wire, "id") do
      {:ok, id} when is_binary(id) ->
        if Delta.id_hex(claims) == id, do: :ok, else: {:error, :id_mismatch}

      _ ->
        {:error, :missing_id}
    end
  end

  # D1: unsigned deltas are refused at the door; an empty/garbage sig fails
  # the signature check, not the presence check
  defp check_signed(wire) do
    case Map.fetch(wire, "sig") do
      {:ok, sig} when is_binary(sig) -> :ok
      _ -> {:error, :unsigned}
    end
  end

  defp check_signature(wire, claims) do
    id_hex = Delta.id_hex(claims)

    if Signer.verify(claims, wire["sig"], id_hex) do
      :ok
    else
      {:error, :bad_signature}
    end
  end
end
