defmodule Exmodem.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/smartrent/exmodem"

  def project do
    [
      app: :exmodem,
      version: @version,
      description: "Implements the XMODEM file transfer protocol",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      dialyzer: dialyzer()
    ]
  end

  def application() do
    [
      extra_applications: [:logger]
    ]
  end

  def cli() do
    [preferred_envs: %{docs: :docs, "hex.publish": :docs, "hex.build": :docs}]
  end

  defp deps() do
    [
      {:cerlc, "~> 0.2"},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.39", only: :docs, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer() do
    ci_opts =
      if System.get_env("CI") do
        [plt_core_path: "_build/plts", plt_local_path: "_build/plts"]
      else
        []
      end

    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
    ] ++ ci_opts
  end

  defp docs() do
    [
      main: "Exmodem",
      extras: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp package() do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
end
