defmodule KyberWeb.ErrorHTML do
  @moduledoc """
  The dashboard error renderer (render_errors config): plain-text lines per
  template — the dashboard has no dedicated error templates.
  """
  use Phoenix.View, root: "lib/kyber_web/templates"
  import Phoenix.Template, only: [embed_templates: 1]

  embed_templates "error_html/*"
end
