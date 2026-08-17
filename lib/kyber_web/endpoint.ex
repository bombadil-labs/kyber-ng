defmodule KyberWeb.Endpoint do
  @moduledoc """
  The T19 dashboard Phoenix endpoint (otp_app :kyber — the dashboard modules
  live in the :kyber app; KyberWeb.Application starts it on the dashboard
  path only). Minimal: request id/logger/parsers + the LiveView socket +
  the router. `server: true` in dev (`mix kyber.dashboard`), false in test
  (LiveViewTest drives it through the test conn).
  """
  use Phoenix.Endpoint, otp_app: :kyber

  socket "/live", Phoenix.LiveView.Socket

  # the vendored LiveView JS bundle (priv/static/assets — no npm build).
  # Plug.Static STRIPS `at: "/assets"` from the request before joining with
  # `from`, so the bundle at priv/static/assets/... needs
  # from: {:kyber, "priv/static/assets"} — a bare `from: :kyber` (=
  # priv/static) or {:kyber, "priv/static"} lands one level too shallow,
  # 404s the bundle, and the LiveView socket never connects (the page then
  # only updates on manual refresh)
  plug Plug.Static,
    at: "/assets",
    from: {:kyber, "priv/static/assets"},
    gzip: false,
    only: ~w(phoenix_live_view.js)

  plug Plug.RequestId
  plug Plug.Logger

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON

  plug Plug.MethodOverride
  plug Plug.Head
  plug KyberWeb.Router
end
