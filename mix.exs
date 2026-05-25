defmodule TdsCdc.MixProject do
  use Mix.Project

  def project do
    [
      app: :tds_cdc,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Change Data Capture library for SQL Server in Elixir via TDS protocol",
      package: package(),
      docs: [
        main: "TdsCdc",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TdsCdc.Application, []}
    ]
  end

  defp package do
    [
      name: "tds_cdc",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zerobatu/tds_cdc"
      }
    ]
  end

  defp deps do
    [
      {:tds, "~> 2.3"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
