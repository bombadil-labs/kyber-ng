defmodule Kyber.Agent.Attestation do
  @moduledoc """
  The operator-key boot attestation verification (T14c D5, P3's absorbed
  pin): `verified?/2` is PURE — pointer resolution + operator<>agent
  non-self guard + boot pointer targets an unretracted seed claim +
  author-field == operator-pointer binding + REAL Ed25519 verification on
  the claim bytes. Zero I/O, zero in-store pubkey seeding — the
  `claims.author` field IS the pubkey (`ed25519:<pubkey>`), so verification
  needs no keyring and no store-derived key material.

  This closes A2's third-party-forgery hole in P1's original pointer-scan:
  a claim that merely CARRIES the pinned pointers but is not signed by the
  operator it names fails the author-binding and the signature check.
  """

  alias Kyber.Schema
  alias Rhizomatic.Signer

  @doc """
  True iff the set holds a `BootAttestation` for `agent_author` that passes
  every check: the three pinned pointers resolve, operator <> agent
  (non-self — the operator cannot attest its own boot), the boot pointer
  targets an UNRETRACTED seed claim, the claim's author field binds the
  operator pointer, and the claim's signature verifies under that author
  (real Ed25519, deterministic — strict, pure, zero I/O).
  """
  @spec verified?(Kyber.DeltaSet.t(), String.t()) :: boolean()
  def verified?(set, agent_author) do
    Enum.any?(set, fn {_id, {claims, sig}} ->
      case Schema.resolve(claims) do
        %{type: "BootAttestation", agent: {:entity, ^agent_author, _}} = typed ->
          verify_claim(set, typed, claims, sig, agent_author)

        _other ->
          false
      end
    end)
  end

  defp verify_claim(set, typed, claims, sig, agent_author) do
    with {:entity, operator_author, _ctx} <- typed.operator,
         true <- operator_author != agent_author,
         true <- claims.author == operator_author,
         {:delta, seed_claim_id, _ctx} <- typed.boot,
         true <- unretracted_seed_claim?(set, seed_claim_id),
         true <- Signer.verify(claims, sig) do
      true
    else
      _other -> false
    end
  end

  # an unretracted seed claim: a role-"seed" delta at the id, with no
  # negates pointer targeting it anywhere in the set
  defp unretracted_seed_claim?(set, seed_claim_id) do
    case Map.get(set, seed_claim_id) do
      {claims, _sig} ->
        kind(claims) == "seed" and not retracted?(set, seed_claim_id)

      nil ->
        false
    end
  end

  defp retracted?(set, target_id) do
    Enum.any?(set, fn {_id, {claims, _sig}} ->
      Enum.any?(claims.pointers, &match?(%{role: "negates", target: {:delta, ^target_id, _}}, &1))
    end)
  end

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil
end
