defmodule Listener.MixProject do
  use Mix.Project

  def project do
    [
      app: :listener,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Listener.Application, []}
    ]
  end

  defp deps do
    [
      {:tds_cdc, path: "../../"}
    ]
  end
end