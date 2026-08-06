defmodule Kyber.Vault do
  @moduledoc """
  The vault-as-view (T7, rev 2): the claims store is the truth; the vault is
  derived state — one Obsidian-compatible markdown file per claim, rendered
  from `Kyber.DurableStore.set/0` alone. Nothing here is a source of record:
  `render/1` rebuilds a vault dir from scratch and `refresh/1` re-renders
  in place, so the vault is always reconstructible from the store (AC6).

  **Rendered shape (PINNED BYTE-EXACT):** one file per claim,
  `claims/claim_<id_hex>.md` (the underscore — `:` is forbidden on NTFS) —

      ---
      id: <id_hex>
      author: <claims.author>
      timestamp: <:erlang.float_to_binary(ts, decimals: 0) — decimal, never scientific>
      role: <the literal FIRST pointer's role — never a kind name>
      pointers: <Wire.claims_json(claims)["pointers"], JSON-encoded verbatim>
      ---
      <the content pointer's string value, or "no content pointer">

  **Spec-contradiction note (recorded, not papered over):** the ticket pins
  BOTH the `pointers:` frontmatter field to raw `Wire.claims_json/1` JSON
  (unmodified target shapes) AND the body to exactly the content pointer's
  *string* value — yet it also requires `{:delta, hex, _}` pointer targets
  to render as `[[claim_<hex>]]` wikilinks and `{:entity, id, _}` targets as
  plain text, yet neither of those two pinned surfaces has any room left for
  that syntax once `Wire.claims_json` (a hard byte-exact pin) and the body's
  pure-string definition (equally byte-exact, per AC2's golden fixture) are
  taken literally. Every current builder's `content` pointer is a `:string`
  target (`Kyber.Events`, `Kyber.Migration`), so this is unreachable in
  practice today — the resolution here generalizes "the content pointer's
  *value*" from string-only to whatever `Rhizomatic.Delta.validate/1`
  actually allows a `content`-role pointer to target: a `:string` target
  renders as-is (the pinned case, byte-exact for every existing builder); a
  `:delta` target renders as its wikilink; an `:entity` target renders as
  its plain-text id. The `pointers:` frontmatter field is left untouched —
  it stays the literal `Wire.claims_json` shape, exactly as pinned.
  """

  alias Kyber.{DurableStore, Wire}

  @claims_subdir "claims"

  @type render_report :: %{files: non_neg_integer()}
  @type refresh_report :: %{
          files: non_neg_integer(),
          unchanged: non_neg_integer(),
          overwritten: [Path.t()]
        }

  @doc """
  Materialize every claim in the store as a markdown file under
  `vault_dir/claims/`. Store-down guard FIRST, then the set() call is
  exit-protected (`set_with_catch/0` — same TOCTOU closure shape as
  `Kyber.Harness.persist/1`), then the vault dirs are created. A write
  failure stops the render where it stands — files written so far stay
  (partial-render policy; no count is returned on error).
  """
  @spec render(Path.t()) :: {:ok, render_report()} | {:error, term()}
  def render(vault_dir) do
    with :ok <- guard_store(),
         {:ok, set} <- set_with_catch(),
         {:ok, claims_dir} <- ensure_dirs(vault_dir) do
      write_all(sorted_claims(set), claims_dir)
    end
  end

  @doc """
  Re-render into `vault_dir`: compare-then-write per file — the ONLY
  idempotence mechanism (mtime is granularity-blind). A file whose rendered
  bytes already match is left untouched (`unchanged`); a file that differs
  (a hand edit, a stale render, or one that doesn't exist yet) is written
  and its path reported in `overwritten`. A foreign file is never looked at
  — this only ever touches the exact `claim_<id_hex>.md` paths the store's
  claims name.
  """
  @spec refresh(Path.t()) :: {:ok, refresh_report()} | {:error, term()}
  def refresh(vault_dir) do
    with :ok <- guard_store(),
         {:ok, set} <- set_with_catch(),
         {:ok, claims_dir} <- ensure_dirs(vault_dir) do
      refresh_all(sorted_claims(set), claims_dir)
    end
  end

  # ------------------------------------------------------------------ guard

  defp guard_store do
    if Process.whereis(DurableStore), do: :ok, else: {:error, :store_not_running}
  end

  # the TOCTOU closure (T4 Harness.persist/1 shape): the whereis guard runs
  # BEFORE this call — a store stopping in the window between the guard and
  # here would otherwise raise exit(:noproc) out of a bare GenServer.call.
  # Shared by render/1 and refresh/1 (rev 2).
  defp set_with_catch do
    try do
      {:ok, DurableStore.set()}
    catch
      :exit, {:noproc, _} -> {:error, :store_not_running}
      :exit, reason -> {:error, {:store_exit, reason}}
    end
  end

  # -------------------------------------------------------------------- dirs

  defp ensure_dirs(vault_dir) do
    claims_dir = Path.join(vault_dir, @claims_subdir)

    try do
      File.mkdir_p!(vault_dir)
      File.mkdir_p!(claims_dir)
      {:ok, claims_dir}
    rescue
      e in File.Error -> {:error, {:vault_dir_not_dir, e.path}}
    end
  end

  defp sorted_claims(set) do
    set
    |> Enum.map(fn {id_hex, {claims, _sig}} -> {id_hex, claims} end)
    |> Enum.sort_by(fn {id_hex, _claims} -> id_hex end)
  end

  defp claim_path(claims_dir, id_hex), do: Path.join(claims_dir, "claim_#{id_hex}.md")

  # ------------------------------------------------------------------ render

  defp write_all(claims, claims_dir) do
    Enum.reduce_while(claims, {:ok, %{files: 0}}, fn {id_hex, claim}, {:ok, acc} ->
      path = claim_path(claims_dir, id_hex)

      case File.write(path, render_markdown(id_hex, claim)) do
        :ok -> {:cont, {:ok, %{acc | files: acc.files + 1}}}
        {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
      end
    end)
  end

  # ----------------------------------------------------------------- refresh

  defp refresh_all(claims, claims_dir) do
    init = {:ok, %{files: 0, unchanged: 0, overwritten: []}}

    Enum.reduce_while(claims, init, fn {id_hex, claim}, {:ok, acc} ->
      path = claim_path(claims_dir, id_hex)
      content = render_markdown(id_hex, claim)

      case File.read(path) do
        {:ok, ^content} ->
          {:cont, {:ok, %{acc | files: acc.files + 1, unchanged: acc.unchanged + 1}}}

        _ ->
          case File.write(path, content) do
            :ok ->
              acc = %{acc | files: acc.files + 1, overwritten: acc.overwritten ++ [path]}
              {:cont, {:ok, acc}}

            {:error, reason} ->
              {:halt, {:error, {:write_failed, path, reason}}}
          end
      end
    end)
  end

  # ------------------------------------------------------------------ shape

  defp render_markdown(id_hex, claims) do
    role = claims.pointers |> List.first() |> Map.fetch!(:role)
    pointers_json = claims |> Wire.claims_json() |> Map.fetch!("pointers") |> JSON.encode!()
    ts_text = :erlang.float_to_binary(claims.timestamp, decimals: 0)
    body = render_body(claims.pointers)

    [
      "---",
      "id: " <> yaml_scalar(id_hex),
      "author: " <> yaml_scalar(claims.author),
      "timestamp: " <> ts_text,
      "role: " <> yaml_scalar(role),
      "pointers: " <> pointers_json,
      "---",
      body
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # the content pointer's rendered value: a :string target is the pinned
  # case (byte-exact for every current builder); a :delta/:entity target —
  # unreachable today, but a valid claims shape Delta.validate admits —
  # extends the Wikilinks rule to the one place free-form prose lives (see
  # moduledoc's spec-contradiction note)
  defp render_body(pointers) do
    case Enum.find(pointers, &(&1.role == "content")) do
      nil -> "no content pointer"
      %{target: {:string, s}} -> s
      %{target: target} -> wikilink(target)
    end
  end

  defp wikilink({:delta, hex, _ctx}), do: "[[claim_#{hex}]]"
  defp wikilink({:entity, id, _ctx}), do: id
  defp wikilink(_other), do: "no content pointer"

  # the invented YAML subset (rev 2): bare scalars, single-quoted scalars
  # ('' escaping), and (pointers: only) the flow literals JSON.encode!
  # produces — never block YAML, so no parser needs to exist in the frozen
  # deps for a human (or Obsidian) to read it.
  defp yaml_scalar(s) do
    if needs_quoting?(s) do
      "'" <> String.replace(s, "'", "''") <> "'"
    else
      s
    end
  end

  defp needs_quoting?(s) do
    String.starts_with?(s, "{") or
      String.starts_with?(s, "[") or
      String.starts_with?(s, "'") or
      String.starts_with?(s, "\"") or
      String.contains?(s, "\": \"")
  end
end
