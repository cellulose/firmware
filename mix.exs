defmodule Firmware.Mixfile do
  use Mix.Project

  def project, do: [
    app: :firmware,
    version: "0.1.0",
    elixir: "~> 1.0",
    deps: deps
  ]

  def application, do: [
    applications: [ :elixir, :jsx, :hub ]
  ]

  defp deps, do: [
    {:earmark, "~> 0.1", only: :dev},
    {:ex_doc, "~> 0.7", only: :dev},
    {:hub, github: "cellulose/hub"},
    {:jsx, github: "talentdeficit/jsx", ref: "v1.4.3", override: true },
  ]


end
