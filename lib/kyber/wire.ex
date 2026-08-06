defmodule Kyber.Wire do
  @moduledoc """
  The production envelope serializer (spec/04-persistence.md §2): the pinned
  wire envelope `%{"id" => ..., "claims" => ..., "sig" => ...}` rendered as
  Elixir's stdlib `JSON`. The witness has no serializer; `Kyber.TestWire`
  (test-only) is the FORMAT ORACLE until deleted — `envelope/1` and
  `claims_json/1` must render byte-identically to it on the same signed
  event.

  `encode/1` is strict where the stdlib is coercive (reject, never repair):
  non-map input is refused (`:not_a_map`); a map with ANY non-string key at
  ANY DEPTH is refused (`:non_string_key`), because the stdlib encoder
  silently stringifies nested atom keys, which would break the term-identical
  round-trip; a value with no `JSON.Encoder` implementation (a PID, a tuple,
  a reference) is refused with a tagged error. NaN/Infinity are not
  representable as Elixir floats at all (see `Rhizomatic.Delta`), so that
  case is unreachable on the BEAM.

  `decode/1` mirrors `encode/1`: malformed JSON is refused
  (`{:error, {:decode, _}}`) and VALID JSON that is not a map is refused
  (`{:error, {:decode, :not_a_map}}`). `encode/1` then `decode/1` is
  term-identical. Pure — no file I/O.
  """

  alias Rhizomatic.{Base64Url, Delta}

  @type wire :: %{required(String.t()) => term()}

  @doc "Wrap a signed delta `{claims, sig_hex}` in the wire envelope."
  @spec envelope({Delta.claims(), String.t()}) :: wire()
  def envelope({claims, sig_hex}) do
    %{
      "id" => Delta.id_hex(claims),
      "claims" => claims_json(claims),
      "sig" => sig_hex
    }
  end

  @doc "Render in-memory claims to the JSON debug profile shape (string-keyed)."
  @spec claims_json(Delta.claims()) :: map()
  def claims_json(%{timestamp: ts, author: author, pointers: pointers}) do
    %{
      "timestamp" => ts,
      "author" => author,
      "pointers" => Enum.map(pointers, &pointer_json/1)
    }
  end

  @doc "Encode a wire envelope map to JSON text. See moduledoc for the refusals."
  @spec encode(term()) :: {:ok, binary()} | {:error, {:encode, term()}}
  def encode(wire) when is_map(wire) do
    with :ok <- check_string_keys(wire) do
      encode_strict(wire)
    end
  end

  def encode(_), do: {:error, {:encode, :not_a_map}}

  @doc "Decode JSON text back into a wire envelope map."
  @spec decode(binary()) :: {:ok, map()} | {:error, {:decode, term()}}
  def decode(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, term} when is_map(term) -> {:ok, term}
      {:ok, _term} -> {:error, {:decode, :not_a_map}}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  def decode(_), do: {:error, {:decode, :not_a_map}}

  # ---------------------------------------------------------------- claims

  # the JSON debug profile shape, byte-identical to Kyber.TestWire (the oracle)
  defp pointer_json(%{role: role, target: target}) do
    %{"role" => role, "target" => target_json(target)}
  end

  defp target_json({:string, s}), do: s
  defp target_json({:number, f}), do: f
  defp target_json({:boolean, b}), do: b
  defp target_json({:entity, id, nil}), do: %{"id" => id}
  defp target_json({:entity, id, ctx}), do: %{"id" => id, "context" => ctx}
  defp target_json({:delta, hex, nil}), do: %{"delta" => hex}
  defp target_json({:delta, hex, ctx}), do: %{"delta" => hex, "context" => ctx}

  defp target_json({:bytes, mime, payload}) do
    %{"mime" => mime, "value" => Base64Url.encode(payload)}
  end

  # -------------------------------------------------------------- machinery

  # reject, never repair: the stdlib encoder silently stringifies non-string
  # map keys at any depth, which would break the term-identical round-trip —
  # walk maps AND lists so a nested atom-keyed map inside claims (or a list
  # inside a map) is refused, not coerced
  defp check_string_keys(map) when is_map(map) do
    Enum.reduce_while(map, :ok, fn
      {key, value}, :ok when is_binary(key) ->
        case check_string_keys(value) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end

      {_key, _value}, :ok ->
        {:halt, {:error, {:encode, :non_string_key}}}
    end)
  end

  defp check_string_keys(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn
      value, :ok ->
        case check_string_keys(value) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp check_string_keys(_), do: :ok

  # JSON has no non-raising encode/1 (only encode!/1); a value without a
  # JSON.Encoder implementation raises, so this is the one place that
  # rescues to keep the refusal a tagged tuple, not a crash
  defp encode_strict(wire) do
    {:ok, JSON.encode!(wire)}
  rescue
    e -> {:error, {:encode, Exception.message(e)}}
  end
end
