defmodule KyberWeb.Router do
  @moduledoc """
  The dashboard router: three LiveView routes — `/` (view 0, the delta flow
  topology), `/intake` (view 1, the delta intake waterfall) and
  `/trace/:id` (view 2, the span/trace waterfall). Clicking any delta — a
  packet in view 0, a row in view 1 — live-patches into view 2.
  """
  use Phoenix.Router, helpers: false

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {KyberWeb.Layouts, :root}
  end

  scope "/", KyberWeb do
    pipe_through :browser

    live "/", FlowLive, as: :flow
    live "/intake", IntakeLive, as: :intake
    live "/trace/:id", TraceLive, as: :trace
  end
end
