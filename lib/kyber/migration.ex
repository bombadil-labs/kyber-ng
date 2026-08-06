defmodule Kyber.Migration do
  @moduledoc """
  The legacy log becomes claims (spec/07, T6): kyber's pre-rhizomatic delta
  log (`deltas.jsonl` — one `Kyber.Delta.to_map/1` map per line, string keys
  `id`/`ts`/`origin`/`kind`/`payload`/`parent_id`) is translated into signed
  rhizomatic claims and fed through the SAME door every other path uses
  (`Kyber.Federation.import/1`) — the same dedup, the same reporting.

  Legacy deltas are UNSIGNED. Migration cannot fabricate a signature that
  never existed, so the archivist answer (pinned): each legacy delta becomes
  a claim SIGNED BY THE AGENT KEY (the harness attesting "this delta existed
  in my history"); the legacy identity lives in the claim's pointers; the
  timestamp is the legacy `ts` coerced to float (D14).

  **Claim shape (pinned):**

      %{timestamp: float, author: agent_pubkey, pointers: [
        %{role: "legacy", target: {:entity, "delta:<legacy_id>", "legacy"}},
        %{role: "kind", target: {:string, kind}},
        %{role: "origin", target: {:string, JSON.encode!(origin)}},
        %{role: "parent", target: {:string, parent_id}},
        %{role: "content", target: {:string, JSON.encode!(payload)}}
      ]}

  The origin OBJECT is embedded as an encoded string (a map cannot be a
  string target — `Delta.validate` rejects `{:string, map}`). Optional
  fields (`origin`/`parent_id`/`payload`) absent or `null` in the legacy
  line -> their pointer is omitted. `translate_line/2` runs `Delta.validate`
  BEFORE signing (mirroring the `Kyber.Events` builders), so every refusal
  is a tagged tuple, never a Cbor crash.

  `migrate/2` is a pure translator feeding the existing pipeline: translate
  every legacy line to wire text, then one `Federation.import/1` call — the
  SAME door, the SAME dedup (re-migration is idempotent), the SAME
  reporting. Migration is BOUNDED: legacy logs are 10^3-10^4 lines, so the
  collect-then-import design is accepted (a streaming-import ticket is a
  later loop).
  """

  alias Kyber.{DurableStore, Federation, Keys, Wire}
  alias Rhizomatic.Delta

  @required_keys ~w(id ts kind)

  @type migration_report :: %{
          imported: non_neg_integer(),
          refused: [Federation.line_no()],
          skipped: non_neg_integer(),
          legacy_refused: [pos_integer()]
        }

  @doc """
  Translate one DECODED legacy delta map (string keys) into a signed claim,
  PURE (no I/O, no store, no process) — the archivist seed is a parameter.
  Deterministic over the decoded term: the same decoded map + the same seed
  always produce the same claims (and therefore the same id).
  """
  @spec translate_line(map(), String.t()) ::
          {:ok, {Delta.claims(), String.t()}} | {:error, term()}
  def translate_line(legacy, seed_hex) when is_map(legacy) do
    with :ok <- check_required(legacy),
         {:ok, ts} <- coerce_timestamp(Map.fetch!(legacy, "ts")),
         {:ok, author} <- author_for(seed_hex) do
      claims = build_claims(legacy, ts, author)

      with {:ok, claims} <- Delta.validate(claims),
           {:ok, sig} <- Keys.sign(claims, seed_hex) do
        {:ok, {claims, sig}}
      end
    end
  end

  def translate_line(_legacy, _seed_hex), do: {:error, :malformed_legacy}

  @doc """
  Migrate a legacy `deltas.jsonl` log at `legacy_path` into the running
  store, signing every translated claim with the archivist key loaded from
  `keyring_dir`. Store-down guard FIRST; a store-down mid-import passes
  through unchanged, with no partial report (the translated-but-unimported
  work is discarded — translation is pure and uncached, so a retry
  re-translates from scratch).
  """
  @spec migrate(Path.t(), Path.t()) :: {:ok, migration_report()} | {:error, term()}
  def migrate(legacy_path, keyring_dir) do
    if Process.whereis(DurableStore) do
      with {:ok, seed} <- Keys.load_agent_seed(keyring_dir),
           :ok <- check_regular(legacy_path),
           {:ok, io} <- open_legacy(legacy_path) do
        run_migration(io, seed)
      end
    else
      {:error, :store_not_running}
    end
  end

  # ---------------------------------------------------------------- translate

  defp check_required(legacy) do
    Enum.reduce_while(@required_keys, :ok, fn key, :ok ->
      case Map.fetch(legacy, key) do
        {:ok, _value} -> {:cont, :ok}
        :error -> {:halt, {:error, :missing_key, key}}
      end
    end)
  end

  # D14 / Events.timestamp/1's contract: the ONE coercion point, total over
  # any decoded JSON value — never a raise. An integer survives only through
  # the exact-f64 check; anything else that is not already a float is
  # :timestamp_not_a_number.
  defp coerce_timestamp(ts) when is_integer(ts) do
    try do
      f = 1.0 * ts
      if trunc(f) == ts, do: {:ok, f}, else: {:error, {:not_exact_f64, :timestamp}}
    rescue
      ArithmeticError -> {:error, {:not_exact_f64, :timestamp}}
    end
  end

  defp coerce_timestamp(ts) when is_float(ts), do: {:ok, ts}
  defp coerce_timestamp(_ts), do: {:error, :timestamp_not_a_number}

  # mirrors Kyber.Events' private author_for/1: decode-check BEFORE calling
  # Keys.author_for_seed/1, which raises on a malformed seed
  defp author_for(seed_hex) do
    case Base.decode16(seed_hex, case: :mixed) do
      {:ok, <<_::binary-32>>} -> {:ok, Keys.author_for_seed(seed_hex)}
      _ -> {:error, :invalid_seed}
    end
  end

  defp build_claims(legacy, ts, author) do
    kind = Map.fetch!(legacy, "kind")

    %{
      timestamp: ts,
      author: author,
      pointers: build_pointers(legacy, kind)
    }
  end

  defp build_pointers(legacy, kind) do
    legacy_id = Map.fetch!(legacy, "id")
    origin = Map.get(legacy, "origin")
    parent_id = Map.get(legacy, "parent_id")
    payload = Map.get(legacy, "payload")

    [%{role: "legacy", target: {:entity, legacy_ref(legacy_id), "legacy"}}]
    |> add_pointer("kind", {:string, kind})
    |> maybe_add_pointer("origin", origin, fn o -> {:string, JSON.encode!(o)} end)
    |> maybe_add_pointer("parent", parent_id, fn p -> {:string, p} end)
    |> maybe_add_pointer("content", payload, fn c -> {:string, JSON.encode!(c)} end)
  end

  defp add_pointer(pointers, role, target), do: pointers ++ [%{role: role, target: target}]

  defp maybe_add_pointer(pointers, _role, nil, _fun), do: pointers
  defp maybe_add_pointer(pointers, role, value, fun), do: add_pointer(pointers, role, fun.(value))

  # legacy id is documented as a hex string (rev 2); a defensive fallback
  # (never a raise on an unexpected shape — Delta.validate is the refusal
  # authority, not string concatenation)
  defp legacy_ref(legacy_id) when is_binary(legacy_id), do: "delta:" <> legacy_id
  defp legacy_ref(legacy_id), do: "delta:" <> inspect(legacy_id)

  # ------------------------------------------------------------------- file

  defp check_regular(path) do
    if File.regular?(path), do: :ok, else: {:error, {:no_legacy_log, path}}
  end

  defp open_legacy(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:unreadable_legacy, path, reason}}
    end
  catch
    :exit, reason -> {:error, {:unreadable_legacy, path, reason}}
  end

  defp run_migration(io, seed) do
    try do
      {wire_lines, legacy_refused} = translate_stream(io, seed)
      wire_text = Enum.join(wire_lines, "\n")

      case Federation.import(wire_text) do
        {:ok, import_report} -> {:ok, build_report(import_report, legacy_refused)}
        {:error, _reason} = err -> err
      end
    after
      File.close(io)
    end
  end

  defp build_report(import_report, legacy_refused) do
    %{
      imported: import_report.imported,
      refused: import_report.refused,
      skipped: import_report.skipped,
      legacy_refused: legacy_refused
    }
  end

  # CRLF parity with Kyber.Log.strip_eol/1: strip a trailing "\r" per line
  # BEFORE decode (the T5 parity lesson). Never fatal: a bad line is
  # collected as a legacy-refused line number, the stream continues.
  defp translate_stream(io, seed) do
    {wire_lines, legacy_refused} =
      io
      |> IO.stream(:line)
      |> Stream.map(&String.trim_trailing(&1, "\r"))
      |> Stream.with_index(1)
      |> Enum.reduce({[], []}, fn {raw_line, line_no}, {wire_acc, refused_acc} ->
        case decode_and_translate(raw_line, seed) do
          {:ok, wire_line} -> {[wire_line | wire_acc], refused_acc}
          :error -> {wire_acc, [line_no | refused_acc]}
        end
      end)

    {Enum.reverse(wire_lines), Enum.reverse(legacy_refused)}
  end

  defp decode_and_translate(raw_line, seed) do
    with {:ok, term} <- JSON.decode(raw_line),
         {:ok, signed} <- translate_line(term, seed),
         {:ok, json} <- Wire.encode(Wire.envelope(signed)) do
      {:ok, json}
    else
      _error -> :error
    end
  end
end
