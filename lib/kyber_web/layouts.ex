defmodule KyberWeb.Layouts do
  @moduledoc """
  The dashboard root layout: the LiveView JS bundle (served from
  priv/static/assets — a vendored copy of the phoenix_live_view package's
  precompiled bundle; no npm) and a top nav between the two views.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>kyber dashboard</title>
        <script src="/assets/phoenix_live_view.js" defer></script>
        <style>
          body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                 margin: 0; background: #0f1117; color: #d7dae0; }
          nav { display: flex; gap: 1rem; padding: 0.75rem 1rem;
                background: #171a23; border-bottom: 1px solid #2a2f3a; }
          nav a { color: #8ab4f8; text-decoration: none; }
          nav a:hover { text-decoration: underline; }
          main { padding: 1rem; }
          table { border-collapse: collapse; width: 100%; }
          th, td { text-align: left; padding: 0.35rem 0.6rem;
                   border-bottom: 1px solid #232836; vertical-align: top; }
          th { color: #8b93a7; font-weight: 600; }
          a.delta { color: #8ab4f8; text-decoration: none; }
          .badge { display: inline-block; padding: 0 0.4rem; border-radius: 0.5rem;
                   font-size: 0.75rem; }
          .b-traced { background: #173b26; color: #7ee2a8; }
          .b-untraced { background: #3a2f12; color: #e5c07b; }
          .b-dup { background: #3b1d1d; color: #e06c75; }
          .b-open { background: #1d2b3b; color: #61afef; }
          .b-closed { background: #173b26; color: #7ee2a8; }
          .b-truncated { background: #3b1d1d; color: #e06c75; }
          .banner { padding: 2rem; text-align: center; color: #8b93a7; }
          .span-row td:first-child { white-space: nowrap; }
          .kind { color: #c678dd; }
          .muted { color: #8b93a7; }
        </style>
      </head>
      <body>
        <nav>
          <a href="/">intake</a>
          <span class="muted">·</span>
          <a href="/trace/intake">trace</a>
        </nav>
        <main>
          <%= @inner_content %>
        </main>
      </body>
    </html>
    """
  end
end
