defmodule Kyber.MixProject do
  use Mix.Project

  def project do
    [
      app: :kyber,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
       github: "bombadil-labs/rhizomatic", subdir: "implementations/elixir", branch: "main"}
    ]
  end
end
