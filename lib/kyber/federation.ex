defmodule Kyber.Federation do
  @moduledoc """
  The wire speaks to itself (spec/07, T5): `export/0` renders the running
  store's delta set as wire JSONL; `import/1` feeds wire JSONL back through
  the door — the SAME door every other path uses (`Kyber.Store.admit/2` via
  `Kyber.DurableStore.append/1`), so a federation peer's claims are verified
  exactly as strictly as a locally-emitted one. This IS the migration path:
  a legacy shape translated to wire text is just another `import/1` call.

  **Byte shape (rev 2 pin):** one pinned envelope (`Kyber.Wire.envelope/1`,
  `Kyber.Wire.encode/1`) per line, sorted by id_hex (the same deterministic
  order `Kyber.Harness.view/0` uses), joined by `"\\n"` with NO trailing
  newline; the empty store exports `""`.

  `import/1` splits eagerly (`String.split/2` — federation texts are
  bounded), drops a final empty segment (a trailing `"\\n"` in the text is
  tolerated, never counted as a line), and strips a trailing `"\\r"` per line
  BEFORE decode (CRLF parity with `Kyber.Log.strip_eol/1`). Per line: blank
  is skipped; a `Wire.decode/1` failure is refused (1-based line number);
  decode-ok is pre-checked against `DurableStore.set/0` for membership
  (already present is skipped — the line is NOT re-appended; this is an
  O(n)-per-line documented cost, bounded to sync-sized texts — concurrent
  imports are out of scope, the GenServer serializes and the last import's
  report wins) — else `DurableStore.append/1` inside a `catch_exit` closure
  (the T4 TOCTOU pattern from `Kyber.Harness`): `:ok` is imported, a door
  refusal is refused. Import **never halts on an INPUT failure** (torn,
  tampered, non-envelope, door-refused); a **SINK failure** (the write
  itself fails) HALTS with `{:error, {:import_failed, line_no, reason}}` — a
  broken sink must not silently drop claims. A store dying mid-import (the
  catch_exit maps `exit(:noproc)`) halts with `{:error, :store_not_running}`,
  same as a store already down before the first line.

  `import_report/0` is a thin delegate to the store-owned observable
  (`DurableStore.import_report/0`) — the report is written atomically at
  import END (or at the point of a sink-failure HALT, while the store is
  still known alive; never on a store-down halt, when there is no live
  GenServer left to write it into).
  """

  alias Kyber.{DeltaSet, DurableStore, Wire}

  @type line_no :: pos_integer()
  @type import_report :: %{
          imported: non_neg_integer(),
          refused: [line_no()],
          skipped: non_neg_integer()
        }

  @doc """
  The store's delta set as wire JSONL, deterministic order (sorted by
  id_hex). Store-down -> `{:error, :store_not_running}` (the T4 guard shape,
  checked at call start).
  """
  @spec export() :: {:ok, binary()} | {:error, :store_not_running | {:export_failed, term()}}
  def export do
    if Process.whereis(DurableStore) do
      case set_with_catch() do
        {:exit, {:noproc, _}} ->
          {:error, :store_not_running}

        {:exit, _} = exit_info ->
          {:error, {:store_exit, exit_info}}

        set ->
          case render_export(set) do
            {:ok, text} -> {:ok, text}
            {:error, reason} -> {:error, {:export_failed, reason}}
          end
      end
    else
      {:error, :store_not_running}
    end
  end

  defp render_export(set) do
    sorted = Enum.sort_by(set, fn {id_hex, _element} -> id_hex end)

    Enum.reduce_while(sorted, {:ok, []}, fn {_id_hex, signed}, {:ok, acc} ->
      case Wire.encode(Wire.envelope(signed)) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines) |> Enum.join("\n")}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Import wire JSONL through the door. Never halts on an input failure; a
  sink (write) failure halts with the failed line number. See the moduledoc
  for the full per-line taxonomy.
  """
  @spec import(binary()) :: {:ok, import_report()} | {:error, term()}
  def import(text) when is_binary(text) do
    if Process.whereis(DurableStore) do
      lines = text |> split_lines() |> Enum.with_index(1)
      empty_report = %{imported: 0, refused: [], skipped: 0}

      case run_lines(lines, empty_report) do
        {:halted, report, reason} ->
          # a live sink (still-registered store) records the partial report;
          # a dead one (store_not_running) has no GenServer left to tell
          put_report_if_alive(report, reason)
          {:error, reason}

        report ->
          case put_report_with_catch(report) do
            :ok -> {:ok, report}
            {:exit, {:noproc, _}} -> {:error, :store_not_running}
            {:exit, _} = exit_info -> {:error, {:store_exit, exit_info}}
          end
      end
    else
      {:error, :store_not_running}
    end
  end

  def import(_), do: {:error, :malformed_text}

  # P5 low finding 4: precedence pinned — input validation wins over store
  # state: a non-binary can never be imported regardless of the store; the
  # store-down promise applies to binary input. See AC6 + the moduledoc.

  @doc "The last import's report, store-owned (rev 2). Zeros before any import has run."
  @spec import_report() :: import_report()
  def import_report, do: DurableStore.import_report()

  # ---------------------------------------------------------------- export

  # P5 low finding 3: encode failures fold into {:error, {:export_failed,
  # reason}} — a tagged tuple, never a MatchError crash (today unreachable:
  # the door admits only encodable {claims, sig} pairs; wire_test pins all 7
  # target shapes — but the export path must not be a crash class)

  # ---------------------------------------------------------------- import

  # eager split (federation texts are bounded); a trailing "\n" in the text
  # is tolerated, never counted — the final empty segment it produces is
  # dropped, not treated as a blank line
  defp split_lines(text) do
    lines = String.split(text, "\n")

    if List.last(lines) == "" do
      List.delete_at(lines, -1)
    else
      lines
    end
  end

  defp run_lines(lines, report) do
    Enum.reduce_while(lines, report, fn {line, line_no}, report ->
      case process_line(line, line_no, report) do
        {:cont, new_report} -> {:cont, new_report}
        {:halt, halted_report, reason} -> {:halt, {:halted, halted_report, reason}}
      end
    end)
  end

  # CRLF parity with Kyber.Log.strip_eol/1: strip a trailing "\r" BEFORE decode
  defp process_line(line, line_no, report) do
    line = String.trim_trailing(line, "\r")

    if String.trim(line) == "" do
      {:cont, %{report | skipped: report.skipped + 1}}
    else
      case Wire.decode(line) do
        {:ok, envelope} -> admit_line(envelope, line_no, report)
        {:error, _reason} -> {:cont, %{report | refused: report.refused ++ [line_no]}}
      end
    end
  end

  # membership pre-check (documented O(n)-per-line cost): a duplicate is
  # skipped, not re-appended; else the door decides, via the SAME TOCTOU
  # catch_exit closure Kyber.Harness uses for DurableStore.append/1
  defp admit_line(envelope, line_no, report) do
    case set_with_catch() do
      {:exit, {:noproc, _}} ->
        {:halt, report, :store_not_running}

      {:exit, _} = exit_info ->
        {:halt, report, {:store_exit, exit_info}}

      set ->
        id = envelope["id"]

        if is_binary(id) and DeltaSet.member?(set, id) do
          {:cont, %{report | skipped: report.skipped + 1}}
        else
          handle_append(append_with_catch(envelope), line_no, report)
        end
    end
  end

  # P5 medium finding 1: EVERY stateful call is exit-protected, not just the
  # append — a store death landing on set() (per-line pre-check or export) or
  # the success-path put_import_report raises exit(:noproc) from a bare call,
  # crashing the caller where the never-crash promise says tagged tuple.
  defp set_with_catch do
    DurableStore.set()
  catch
    :exit, reason -> {:exit, reason}
  end

  defp append_with_catch(envelope) do
    DurableStore.append(envelope)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp put_report_with_catch(report) do
    DurableStore.put_import_report(report)
  catch
    :exit, reason -> {:exit, reason}
  end

  # a SINK failure (the write itself) halts; every INPUT failure (a door
  # refusal) is reported and the loop continues
  defp handle_append(:ok, _line_no, report),
    do: {:cont, %{report | imported: report.imported + 1}}

  defp handle_append({:error, :persist_failed}, line_no, report) do
    {:halt, report, {:import_failed, line_no, :persist_failed}}
  end

  # P5 low finding 2: dead defense against store-contract drift — today
  # DurableStore.persist_then_merge normalizes EVERY Log.append failure
  # (write AND encode alike) to :persist_failed, so {:write, _} is
  # unreachable; kept so a future store change cannot silently leak a sink
  # failure into the continue/refused bucket.
  defp handle_append({:error, {:write, _} = reason}, line_no, report) do
    {:halt, report, {:import_failed, line_no, reason}}
  end

  defp handle_append({:error, _reason}, line_no, report) do
    {:cont, %{report | refused: report.refused ++ [line_no]}}
  end

  defp handle_append({:exit, {:noproc, _}}, _line_no, report) do
    {:halt, report, :store_not_running}
  end

  defp handle_append({:exit, _} = exit_info, _line_no, report) do
    {:halt, report, {:append_exit, exit_info}}
  end

  defp put_report_if_alive(_report, :store_not_running), do: :ok

  defp put_report_if_alive(report, _reason) do
    DurableStore.put_import_report(report)
  catch
    :exit, _reason -> :ok
  end
end
