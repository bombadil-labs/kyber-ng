defmodule Kyber.Agent.Memory.Watcher do
  @moduledoc """
  The out-of-band edit observer (T11c): a human editing a projected memory
  file is a first-class event. `tick/1` — the on-demand, no-sleep drive —
  compares each resolved memory's projected file against its canon and
  answers one signed `MemoryEdited` wire per divergence: attested
  (`reason: "human_edit"`), NEW content inline, OLD content by the `edits`
  pointer to the superseded canon head. The caller admits the wires through
  the one door; the watcher never writes the store.

  Only the exact paths the store's memories name are ever looked at (the
  `Kyber.Vault.refresh/1` policy — a foreign file is never read), and a
  file whose body already matches its canon emits nothing, so a tick after
  admission is a no-op: the observation is idempotent.
  """

  alias Kyber.Agent.{Events, Memory}
  alias Kyber.Agent.Memory.Projector
  alias Kyber.Wire

  @type opts :: [
          store: Kyber.DeltaSet.t() | (-> Kyber.DeltaSet.t()),
          vault_dir: Path.t(),
          seed: String.t(),
          human_seed: String.t() | nil,
          ts: number()
        ]

  @doc """
  One observation pass over `vault_dir` against `store`. Returns the signed
  `MemoryEdited` wires for every human-diverged file, in entity order
  (deterministic — a pure function of the set, the files, and `ts`).
  """
  @spec tick(opts()) :: {:ok, [Wire.wire()]} | {:error, term()}
  def tick(opts) do
    set = opts |> Keyword.fetch!(:store) |> materialize()
    vault_dir = Keyword.fetch!(opts, :vault_dir)
    seed = Keyword.fetch!(opts, :seed)
    human_seed = Keyword.get(opts, :human_seed)
    ts = Keyword.fetch!(opts, :ts)

    set
    |> Memory.resolve_set()
    |> Enum.reduce_while({:ok, []}, fn memory, {:ok, wires} ->
      case observe(memory, vault_dir, human_seed || seed, ts) do
        :unchanged -> {:cont, {:ok, wires}}
        {:ok, wire} -> {:cont, {:ok, wires ++ [wire]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp materialize(store) when is_function(store, 0), do: store.()
  defp materialize(store), do: store

  defp observe(memory, vault_dir, seed, ts) do
    with {:ok, raw} <- File.read(Projector.path(vault_dir, memory.entity)),
         {:ok, body} <- parse_body(raw),
         true <- body != canonical(memory.content) do
      with {:ok, signed} <- Events.memory_edited(seed, ts, memory.head, body, "human_edit") do
        {:ok, Wire.envelope(signed)}
      end
    else
      # a missing or unparseable file is not an edit — the projector owns
      # the shape; the watcher only ever attests a diverged BODY
      {:error, _posix} -> :unchanged
      :malformed -> :unchanged
      false -> :unchanged
    end
  end

  # the projector's shape: frontmatter, then the body with one trailing
  # newline. EOL canonicalization (premortem C2 2026-08-06, pinned in AC6):
  # BOTH the file body and the canon are normalized the same way — CRLF to
  # LF, trailing EOLs stripped — so a human save that only touches line
  # endings mints NO edit, and the stored content never embeds `\r` bytes.
  defp parse_body(raw) do
    # canonicalize the WHOLE file first — the frontmatter delimiter is
    # CRLF-mangled too on a Windows save, not just the body
    case String.split(canonical(raw), "\n---\n", parts: 2) do
      [_frontmatter, body] -> {:ok, body}
      _ -> :malformed
    end
  end

  defp canonical(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim_trailing("\n")
  end
end
