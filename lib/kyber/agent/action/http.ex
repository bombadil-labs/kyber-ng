defmodule Kyber.Agent.Action.Http do
  @moduledoc """
  The HTTP actions (T12): `http.get` / `http.post` through the injectable
  `Kyber.Agent.HttpClient` seam — the same `{module, state}` the LLM
  handler speaks (a stub in tests, the stdlib `:httpc` adapter in the live
  run).

  Bounded by construction: http/https schemes only; URLs carrying userinfo
  credentials are REFUSED (no secrets in payloads — the handler's
  key-refusal doctrine extends to actions: the action context carries no
  api key and these actions attach no auth headers); a POST body over the
  cap is refused (a payload is never silently truncated); response bodies
  are capped like shell output (kept prefix + truncation marker).

  `http.get` is idempotent modulo the remote (a safe method); `http.post`
  is NOT idempotent by HTTP semantics — the gate should hold
  side-effecting posts at `prompt` / `deny`.
  """

  alias Kyber.Agent.Action

  @doc "GET a URL. Args: `url`. Context: `:http`, `:output_cap`."
  @spec get(map(), map()) :: {String.t(), String.t()}
  def get(%{"url" => url}, context), do: request(:get, url, nil, context)

  def get(_args, _context), do: {"http.get: a \"url\" string argument is required", "error"}

  @doc "POST a body to a URL. Args: `url`, `body`. Context: `:http`, `:output_cap`."
  @spec post(map(), map()) :: {String.t(), String.t()}
  def post(%{"url" => url, "body" => body}, context) when is_binary(body),
    do: request(:post, url, body, context)

  def post(_args, _context),
    do: {"http.post: \"url\" and \"body\" string arguments are required", "error"}

  # -------------------------------------------------------------- machinery

  defp request(method, url, body, context) do
    cap = Map.get(context, :output_cap, 65_536)

    with :ok <- check_url(url),
         :ok <- check_body(body, cap) do
      {module, state} = Map.get(context, :http, {Kyber.Agent.HttpClient.Httpc, nil})

      case call(module, method, url, body, state) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {cap_body(response_body, cap), "ok"}

        {:ok, %{status: status, body: response_body}} ->
          {cap_body(response_body, cap), "http:" <> Integer.to_string(status)}

        {:error, reason} ->
          {"http." <> Atom.to_string(method) <> " " <> url <> ": " <> inspect(reason), "error"}
      end
    else
      {:refused, message} -> {"refused: " <> message, "refused"}
    end
  end

  defp call(module, :get, url, _body, state), do: module.get(url, [], state)

  defp call(module, :post, url, body, state),
    do: module.post(url, [{~c"content-type", ~c"text/plain"}], body, state)

  # the scheme allow-list + the no-secrets bound: credentials never ride a URL
  defp check_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:refused, "scheme must be http or https"}

      uri.userinfo != nil ->
        {:refused, "credentials in the URL (no secrets in payloads)"}

      true ->
        :ok
    end
  end

  defp check_url(_url), do: {:refused, "url must be a string"}

  defp check_body(nil, _cap), do: :ok

  defp check_body(body, cap) do
    if byte_size(body) <= cap,
      do: :ok,
      else:
        {:refused,
         "request body exceeds the " <>
           Integer.to_string(cap) <>
           "-byte cap (a payload is never silently truncated)"}
  end

  defp cap_body(body, cap) do
    if byte_size(body) > cap,
      do: binary_part(body, 0, cap) <> "\n" <> Action.truncation_marker(cap),
      else: body
  end
end
