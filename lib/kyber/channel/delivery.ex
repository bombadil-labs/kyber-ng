defmodule Kyber.Channel.Delivery do
  @moduledoc """
  The delivery seam (T14i H4): a SECOND `{module, state}` injection,
  REST-shaped (the http_client.ex:1-9 precedent — `post(url, headers,
  body, state)`). Discord message-create is REST-only
  (`POST /channels/{id}/messages` with `Authorization: Bot <token>`); the
  token rides ONLY this seam's header — never the frame stream (the
  gateway's op-2 identify payload is the protocol-required exception, and
  it is never persisted). The fake records url/headers/body; the
  "sends-equal-ResponseDelta" witness SCOPES to this seam — the frame-stream
  fake is NOT held to that equality (heartbeats/pongs break it, M3).
  """

  @typedoc "Headers as string pairs (the impl converts to the :httpc charlist form)."
  @type headers :: [{String.t(), String.t()}]

  @callback post(url :: String.t(), headers(), body :: binary(), state :: term()) ::
              {:ok, %{status: non_neg_integer(), body: binary()}} | {:error, term()}

  defmodule Httpc do
    @moduledoc """
    The real delivery impl: stdlib `:httpc` over `:ssl` (ZERO new deps),
    peer verification against the OS cacert store — the http_client.ex
    Httpc adapter's shape, shared repair included (M13). Only the live run
    constructs a delivery with this adapter — tests always inject the fake.
    """
    @behaviour Kyber.Channel.Delivery

    @impl true
    def post(url, headers, body, _state) do
      {:ok, _apps} = Kyber.Agent.HttpClient.Httpc.ensure_http_apps()

      request = {String.to_charlist(url), to_charlist_headers(headers), ~c"application/json", body}

      http_options = [
        ssl: ssl_options(),
        timeout: 30_000,
        connect_timeout: 10_000,
        autoredirect: false
      ]

      case apply(:httpc, :request, [:post, request, http_options, [body_format: :binary]]) do
        {:ok, {{_version, status, _reason}, _headers, response_body}} ->
          {:ok, %{status: status, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp to_charlist_headers(headers) do
      Enum.map(headers, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
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
