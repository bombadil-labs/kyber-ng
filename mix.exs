defmodule Kyber.MixProject do
  use Mix.Project

  def project do
    [
      app: :kyber,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Kyber.CLI, app: nil]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Kyber.Application, []}
    ]
  end

  defp deps do
    [
      # The substrate: rhizomatic's Elixir witness (Level 0 — canonical CBOR, content
      # addressing, strict Ed25519, packs). Frozen/normative — never edit from here
      # (spec/03-substrate.md).
      {:rhizomatic,
       github: "bombadil-labs/rhizomatic", subdir: "implementations/elixir", branch: "main"},
      # T19 dashboard track (AGENTS.md rail exception 2026-08-14): the in-repo
      # Phoenix LiveView dashboard may amend mix.exs/config/ and add
      # Phoenix/LiveView deps — scoped to the dashboard feature; the substrate
      # rails (deps/, spec/, SPEC.md, the store/agent code) stay frozen for
      # everything else. The dashboard app is NOT in :kyber's
      # extra_applications (the escript must keep booting without Phoenix);
      # KyberWeb.Application.ensure_phoenix!/0 starts these apps on the
      # dashboard path (mix kyber.dashboard / dashboard tests) only.
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      # the error-rendering view (render_errors) is a Phoenix.View —
      # phoenix_view is an optional phoenix dep; the dashboard pulls it
      {:phoenix_view, "~> 2.0"},
      {:phoenix_live_view, "~> 1.0.0"},
      {:plug_cowboy, "~> 2.7"},
      # LiveViewTest's DOM helpers (render_click / render_async element
      # selection) need Floki in the test env only
      {:floki, ">= 0.30.0", only: :test}
    ]
  end
end
