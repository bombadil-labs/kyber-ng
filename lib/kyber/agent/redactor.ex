defmodule Kyber.Agent.Redactor do
  @moduledoc """
  Inference-boundary redaction (T17 D10/AC22): pure. Any occurrence of a
  KNOWN secret value (the resolved/decrypted api_key, the operator seed,
  the derived config key) is replaced with `[REDACTED]` — exact-value
  matching, no false positives (the substrate's 64-hex content ids and
  `ed25519:` authors ride the prompt legitimately). A conservative
  shape-scan (`sk-`, `api_`, `AKIA`/`ghp_`/`xoxb` prefixes, `KEY=` pairs,
  `Bearer `) catches UNKNOWN secrets as a second belt — deliberately
  conservative to avoid nuking legitimate hex. Redaction is visible to the
  model (the marker, never a silent hole).
  """

  @marker "[REDACTED]"

  @shapes [
    ~r/\bsk-[A-Za-z0-9_-]{16,}/,
    ~r/\bapi_[A-Za-z0-9]{16,}/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bghp_[A-Za-z0-9]{20,}/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}/,
    ~r/Bearer\s+[A-Za-z0-9._~+\/=-]{16,}/,
    ~r/[A-Za-z0-9_]*KEY[A-Za-z0-9_]*=\S{16,}/
  ]

  @doc """
  Replace every occurrence of a known secret value (exact match), then
  every conservative secret shape, with `#{@marker}`. Nil/empty known
  values are ignored.
  """
  @spec redact(String.t(), [String.t() | nil]) :: String.t()
  def redact(text, known_values) when is_binary(text) do
    exact =
      Enum.reduce(known_values, text, fn
        nil, acc -> acc
        "", acc -> acc
        value, acc when is_binary(value) -> String.replace(acc, value, @marker)
      end)

    Enum.reduce(@shapes, exact, fn shape, acc -> Regex.replace(shape, acc, @marker) end)
  end

  @doc "The marker constant, for assertions and callers."
  @spec marker() :: String.t()
  def marker, do: @marker
end
