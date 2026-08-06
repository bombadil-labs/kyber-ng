defmodule Kyber.Keys do
  @moduledoc """
  The keyring (spec/02-identity.md §2, §5). The ONLY module that touches key
  material — and the only file I/O in the event layer.

  Seeds are 32 raw bytes, hex-encoded (lowercase). The agent seed lives at
  `home_dir/agent.seed` (0600, never printed); the imported human seed at
  `home_dir/human.seed` (0600). `KYBER_SEED` (hex) imports on first load when
  no `agent.seed` file exists yet (containers, mirrors `LOAM_SEED`).
  """

  alias Rhizomatic.{Ed25519, Signer}

  @agent_seed_file "agent.seed"
  @human_seed_file "human.seed"
  @seed_byte_size 32

  @doc """
  Mint a fresh agent seed: create the home dir and write `agent.seed` (0600,
  hex). Refuses to clobber an existing seed atomically (O_EXCL — no
  check-then-write race; the agent's identity is not silently replaced).
  Never prints.
  """
  @spec mint_agent_seed(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def mint_agent_seed(home_dir) do
    file = agent_seed_path(home_dir)

    with :ok <- ensure_home(home_dir) do
      seed_hex = random_seed_hex()

      with :ok <- write_secret_exclusive(file, seed_hex) do
        {:ok, seed_hex}
      end
    end
  end

  @doc """
  Load the agent seed: existing `agent.seed` wins; otherwise `KYBER_SEED`
  (hex) imports on first load and is persisted to `agent.seed`.
  """
  @spec load_agent_seed(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def load_agent_seed(home_dir) do
    file = agent_seed_path(home_dir)

    case read_secret(file) do
      {:ok, seed_hex} ->
        {:ok, seed_hex}

      {:error, :enoent} ->
        case System.get_env("KYBER_SEED") do
          nil ->
            {:error, :no_agent_seed}

          env_seed ->
            with {:ok, seed_hex} <- validate_seed_hex(String.trim(env_seed)),
                 :ok <- ensure_home(home_dir),
                 :ok <- write_secret_overwrite(file, seed_hex) do
              {:ok, seed_hex}
            end
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Import the human's seed (0600 at `home_dir/human.seed`) — the key kyber
  signs human-origin events with. An explicit operator action, so an existing
  file is overwritten (rotation is the human's call).
  """
  @spec import_human_seed(String.t(), Path.t()) :: :ok | {:error, term()}
  def import_human_seed(seed_hex, home_dir) do
    with {:ok, seed_hex} <- validate_seed_hex(seed_hex),
         :ok <- ensure_home(home_dir),
         :ok <- write_secret_overwrite(human_seed_path(home_dir), seed_hex) do
      :ok
    end
  end

  @doc """
  Load the human seed: read `home_dir/human.seed` (0600). Read-only — NO env
  fallback and NO write-on-load (rev 2, identity-confusion hazard): unlike
  `load_agent_seed/1` it never consults `KYBER_SEED`, and
  `import_human_seed/2` is the ONLY import path for the human identity.
  Missing keyring dir -> `{:error, {:keyring_dir_missing, home_dir}}`;
  dir present but seed absent -> `{:error, :no_human_seed}` (distinct, AC6).
  """
  @spec load_human_seed(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def load_human_seed(home_dir) do
    if File.dir?(home_dir) do
      case read_secret(human_seed_path(home_dir)) do
        {:ok, _seed} = ok -> ok
        {:error, :enoent} -> {:error, :no_human_seed}
        {:error, _reason} = err -> err
      end
    else
      {:error, {:keyring_dir_missing, home_dir}}
    end
  end

  @doc "Derive the author id `ed25519:<hex>` from a seed (pure, via `Rhizomatic.Ed25519`)."
  @spec author_for_seed(String.t()) :: String.t()
  def author_for_seed(seed_hex) do
    seed = seed_bytes!(seed_hex)
    pub_hex = Base.encode16(Ed25519.public_key(seed), case: :lower)
    "ed25519:" <> pub_hex
  end

  @doc "Sign validated claims with the seed — wraps `Rhizomatic.Signer.sign/2`."
  @spec sign(Rhizomatic.Delta.claims(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(claims, seed_hex) do
    with {:ok, seed} <- decode_seed(seed_hex), do: Signer.sign(claims, seed)
  end

  # ---------------------------------------------------------------- helpers

  defp agent_seed_path(home_dir), do: Path.join(home_dir, @agent_seed_file)
  defp human_seed_path(home_dir), do: Path.join(home_dir, @human_seed_file)

  defp ensure_home(home_dir) do
    case File.mkdir_p(home_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp random_seed_hex do
    Base.encode16(:crypto.strong_rand_bytes(@seed_byte_size), case: :lower)
  end

  # mint path: create atomically (O_EXCL — the exists-check and create are one
  # operation, no TOCTOU), chmod BEFORE any bytes are written so the file is
  # 0600 from birth (no world-readable window), and delete on any failure so no
  # broken state can block a re-mint
  defp write_secret_exclusive(file, content) do
    case File.open(file, [:write, :exclusive, :binary]) do
      {:ok, io} -> write_with_mode(io, file, content)
      {:error, :eexist} -> {:error, :already_exists}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  # import path: an explicit operator action — overwrite is rotation
  defp write_secret_overwrite(file, content) do
    case File.open(file, [:write, :binary]) do
      {:ok, io} -> write_with_mode(io, file, content)
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp write_with_mode(io, file, content) do
    with :ok <- :file.change_mode(file, 0o600),
         :ok <- IO.binwrite(io, content) do
      File.close(io)
      :ok
    else
      {:error, reason} ->
        File.close(io)
        File.rm(file)
        {:error, {:write_failed, reason}}
    end
  end

  defp read_secret(file) do
    case File.read(file) do
      {:ok, content} -> validate_seed_hex(String.trim(content))
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_seed_hex(seed_hex) when is_binary(seed_hex) do
    case Base.decode16(seed_hex, case: :mixed) do
      {:ok, <<_::binary-32>>} -> {:ok, String.downcase(seed_hex)}
      _ -> {:error, :invalid_seed}
    end
  end

  defp validate_seed_hex(_), do: {:error, :invalid_seed}

  defp decode_seed(seed_hex) when is_binary(seed_hex) do
    case Base.decode16(seed_hex, case: :mixed) do
      {:ok, <<seed::binary-32>>} -> {:ok, seed}
      _ -> {:error, :invalid_seed}
    end
  end

  defp decode_seed(_), do: {:error, :invalid_seed}

  defp seed_bytes!(seed_hex) do
    case decode_seed(seed_hex) do
      {:ok, seed} -> seed
      {:error, _} -> raise ArgumentError, "invalid seed: expected 32 raw bytes, hex-encoded"
    end
  end
end
