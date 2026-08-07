defmodule Kyber.Agent.Memory.Projector do
  @moduledoc """
  The memory rendering lens (T11c, spine 7): each resolved memory becomes
  one Obsidian-compatible markdown file under `vault_dir/memories/` —
  derived state, always reconstructible from the delta set, never a source
  of record. The vault dir is caller-configured (tmp in tests), never
  `~/.kyber`.

  Rendered shape — the same invented YAML subset as `Kyber.Vault` (bare
  scalars; no block YAML), body = the canon content:

      ---
      entity: <entity id>
      provenance: <human | auto>
      head: <canon head delta id hex>
      ---
      <canon content>

  The filename is `memory_<hex of entity id>.md` (mirroring the vault's
  `claim_<id_hex>.md` — entity ids carry `:`, forbidden on NTFS); the
  human-readable entity id rides the frontmatter.
  """

  alias Kyber.Agent.Memory
  alias Kyber.DeltaSet

  @memories_subdir "memories"

  @type report :: %{files: non_neg_integer()}

  @doc "The rendered path for an entity's memory file."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(vault_dir, entity_id) do
    encoded = Base.encode16(entity_id, case: :lower)
    Path.join([vault_dir, @memories_subdir, "memory_#{encoded}.md"])
  end

  @doc """
  Project every resolved memory in `set` to its markdown file. A write
  failure stops the projection where it stands (partial-render policy,
  matching `Kyber.Vault.render/1`).
  """
  @spec project(DeltaSet.t(), Path.t()) :: {:ok, report()} | {:error, term()}
  def project(set, vault_dir) do
    with {:ok, _dir} <- ensure_dir(vault_dir) do
      set
      |> Memory.resolve_set()
      |> Enum.reduce_while({:ok, %{files: 0}}, fn memory, {:ok, acc} ->
        file = path(vault_dir, memory.entity)

        case File.write(file, render(memory)) do
          :ok -> {:cont, {:ok, %{acc | files: acc.files + 1}}}
          {:error, reason} -> {:halt, {:error, {:write_failed, file, reason}}}
        end
      end)
    end
  end

  @doc "The rendered markdown for one resolved memory."
  @spec render(Memory.memory()) :: String.t()
  def render(memory) do
    [
      "---",
      "entity: " <> memory.entity,
      "provenance: " <> Atom.to_string(memory.provenance),
      "head: " <> memory.head,
      "---",
      memory.content
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp ensure_dir(vault_dir) do
    dir = Path.join(vault_dir, @memories_subdir)

    try do
      File.mkdir_p!(dir)
      {:ok, dir}
    rescue
      e in File.Error -> {:error, {:vault_dir_not_dir, e.path}}
    end
  end
end
