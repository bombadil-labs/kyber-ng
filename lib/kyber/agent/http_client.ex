defmodule Kyber.Agent.HttpClient do
  @moduledoc """
  The HTTP seam for the LLM handler (T11b AC1). The client is a BEHAVIOUR
  injected at handler construction as `{module, state}` — a stub adapter in
  tests, the `:httpc` adapter for the live run — never a compile-time module
  swap. Header names/values are charlists (the `:httpc` form) so the real
  adapter passes them through untranslated.
  """

  @type headers :: [{charlist(), charlist()}]
  @type response :: %{status: non_neg_integer(), body: binary()}

  @callback post(url :: String.t(), headers(), body :: binary(), state :: term()) ::
              {:ok, response()} | {:error, term()}

  @callback get(url :: String.t(), headers(), state :: term()) ::
              {:ok, response()} | {:error, term()}

  # get/3 is optional: the T11b stubs only implement post/4 (the LLM seam);
  # the T12 http actions call get/3 and must be wired a client that has it
  @optional_callbacks get: 3

  defmodule Httpc do
    @moduledoc """
    The real adapter: stdlib `:httpc` over `:ssl` (zero new deps), peer
    verification against the OS cacert store. Only the live run constructs
    a handler with this adapter — tests always inject a stub.
    """
    @behaviour Kyber.Agent.HttpClient

    # mix.exs (extra_applications) is a frozen rail, so :inets/:ssl start
    # here and their modules are reached via apply/3 — a literal remote call
    # would trip the xref warning under --warnings-as-errors
    @impl true
    def post(url, headers, body, _state) do
      {:ok, _apps} = :application.ensure_all_started([:inets, :ssl])
      # a caller-supplied content-type rides (the T12 http action posts
      # text/plain); the LLM handler passes none and stays application/json
      content_type = content_type(headers)
      request = {String.to_charlist(url), headers, content_type, body}

      http_options = [
        ssl: ssl_options(),
        timeout: 120_000,
        connect_timeout: 10_000
      ]

      case apply(:httpc, :request, [:post, request, http_options, [body_format: :binary]]) do
        {:ok, {{_version, status, _reason}, _headers, response_body}} ->
          {:ok, %{status: status, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def get(url, headers, _state) do
      {:ok, _apps} = :application.ensure_all_started([:inets, :ssl])
      request = {String.to_charlist(url), headers}

      http_options = [
        ssl: ssl_options(),
        timeout: 30_000,
        connect_timeout: 10_000
      ]

      case apply(:httpc, :request, [:get, request, http_options, [body_format: :binary]]) do
        {:ok, {{_version, status, _reason}, _headers, response_body}} ->
          {:ok, %{status: status, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp content_type(headers) do
      case List.keyfind(headers, ~c"content-type", 0) do
        {~c"content-type", value} -> value
        nil -> ~c"application/json"
      end
    end

    defp ssl_options do
      [
        verify: :verify_peer,
        cacerts: apply(:public_key, :cacerts_get, []),
        depth: 3,
        customize_hostname_check: [
          match_fun: apply(:public_key, :pkix_verify_hostname_match_fun, [:https])
        ]
      ]
    end
  end
end
