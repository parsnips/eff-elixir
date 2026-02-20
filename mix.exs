defmodule Eff.MixProject do
  use Mix.Project

  def project do
    [
      app: :eff,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:uuid, "~> 1.1"}
    ]
  end
end
