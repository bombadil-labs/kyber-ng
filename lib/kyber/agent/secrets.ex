defmodule Kyber.Agent.Secrets do
  @moduledoc """
  Encrypted-at-rest secret handling (T17 D9/AC20): AEAD (AES-256-GCM)
  encrypt/decrypt for `{"enc": ...}` delta values, keyed by HKDF-SHA256
  derivation from the OPERATOR SEED (info label `kyber:agent-config:v1` —
  the seed is the agent's root secret, already env-held and required at
  every usage point; no new master key to manage).

  Decryption happens ONLY at the usage point (building the LlmHandler /
  provider request): the plaintext exists in that narrow, unlogged window,
  never in daemon state, never in `show`/`status`/`list`, never in the
  prompt, never re-entering the store. A wrong seed fails LOUDLY
  (`{:error, :decrypt_failed}`), never a wrong-key fallback. The operator
  seed itself is NEVER a delta value (AC21) — env-held only.
  """

  @info "kyber:agent-config:v1"
  @nonce_bytes 12
  @tag_bytes 16

  @doc """
  HKDF-SHA256 (extract + one expand block) from the operator seed under
  the `#{@info}` info label — deterministic, 32 bytes.
  """
  @spec derive_key(String.t()) :: binary()
  def derive_key(operator_seed) do
    ikm = seed_bytes(operator_seed)
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
    :crypto.mac(:hmac, :sha256, prk, @info <> <<1>>)
  end

  @doc "AEAD-encrypt a secret value: base64(nonce(12) || ciphertext || tag(16))."
  @spec encrypt(String.t(), String.t()) :: {:ok, String.t()}
  def encrypt(plaintext, operator_seed) when is_binary(plaintext) do
    key = derive_key(operator_seed)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @info, true)

    {:ok, Base.encode64(nonce <> ciphertext <> tag)}
  end

  @doc """
  Decrypt an `{"enc": ...}` payload under the operator seed. Fails LOUDLY
  on a wrong seed or malformed ciphertext — never a wrong-key fallback.
  """
  @spec decrypt(String.t(), String.t()) :: {:ok, String.t()} | {:error, :decrypt_failed}
  def decrypt(encoded, operator_seed) when is_binary(encoded) do
    with {:ok, bin} <- Base.decode64(encoded),
         true <- byte_size(bin) > @nonce_bytes + @tag_bytes do
      <<nonce::binary-size(@nonce_bytes), rest::binary>> = bin
      ciphertext_len = byte_size(rest) - @tag_bytes
      <<ciphertext::binary-size(ciphertext_len), tag::binary-size(@tag_bytes)>> = rest

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             derive_key(operator_seed),
             nonce,
             ciphertext,
             @info,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :decrypt_failed}
      end
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  @doc """
  The door's shape check (AC17): valid base64 of at least nonce+tag+1
  bytes that is NOT text-shaped. Real AEAD output (random nonce +
  ciphertext + tag) is uniformly random — an all-printable decode at 29+
  bytes has probability ~(95/256)^29 ≈ 1e-13, so rejecting text-shaped
  blobs never refuses genuine ciphertext but catches the P5 LOW-1 hole:
  a base64'd PLAINTEXT key smuggled into `api_key_enc`.
  """
  @spec well_formed?(String.t()) :: boolean()
  def well_formed?(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bin} -> byte_size(bin) > @nonce_bytes + @tag_bytes and not text_shaped?(bin)
      :error -> false
    end
  end

  def well_formed?(_), do: false

  defp text_shaped?(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in 32..126 or byte in [9, 10, 13] end)
  end

  # the seed rides as 64-hex (the house convention); decode when it does,
  # take the raw bytes otherwise — deterministic either way
  defp seed_bytes(seed) do
    case Base.decode16(seed, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> seed
    end
  end
end
