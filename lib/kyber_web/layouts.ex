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
          svg.flow { width: 100%; max-width: 900px; display: block; margin: 0 auto 1rem; }
          .funnel { fill: #1d2b3b; stroke: #61afef; stroke-width: 1.5; }
          .edge { stroke: #2a2f3a; stroke-width: 1.5; }
          .node { fill: #171a23; stroke: #8b93a7; stroke-width: 1.5; }
          .node-label { fill: #8b93a7; font-size: 13px;
                        font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          @keyframes packet-flow {
            from { offset-distance: 0%; opacity: 1; }
            to   { offset-distance: 100%; opacity: 0.15; }
          }
          /* offset-path animates a transform about transform-origin; the SVG
             default (view-box centre) would launch packets from mid-scene, so
             the origin is pinned to the viewBox origin and the packet cx/cy
             are 0 — the path alone supplies the position. */
          .packet { cursor: pointer; animation: packet-flow 1.2s ease-out forwards;
                    transform-box: view-box; transform-origin: 0 0; }
          .p-received { fill: #61afef; }
          .p-sent { fill: #7ee2a8; }
          .p-checkpoint { fill: #8b93a7; }
          .p-seed { fill: #c678dd; }
          .p-agent { fill: #56b6c2; }
          .p-default { fill: #8b93a7; }
        </style>
      </head>
      <body>
        <nav>
          <a href="/">flow</a>
          <span class="muted">·</span>
          <a href="/intake">intake</a>
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
