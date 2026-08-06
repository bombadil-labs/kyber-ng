defmodule Kyber.TestWire do
  @moduledoc """
  Test-only assembly of the pinned wire envelope (T1 rev 2): the JSON debug
  profile shape the door accepts. The witness has no serializer; this helper
  renders in-memory claims to string-keyed JSON maps and wraps a signed delta
  in the `%{"id" => ..., "claims" => ..., "sig" => ...}` envelope.
  """

  alias Rhizomatic.{Base64Url, Delta}

  @doc "Wrap a signed delta `{claims, sig_hex}` in the wire envelope."
  def envelope({claims, sig_hex}) do
    %{
      "id" => Delta.id_hex(claims),
      "claims" => claims_json(claims),
      "sig" => sig_hex
    }
  end

  @doc "Render in-memory claims to the JSON debug profile shape (string-keyed)."
  def claims_json(%{timestamp: ts, author: author, pointers: pointers}) do
    %{
      "timestamp" => ts,
      "author" => author,
      "pointers" => Enum.map(pointers, &pointer_json/1)
    }
  end

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
end
