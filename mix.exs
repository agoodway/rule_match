defmodule RuleMatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :rule_match,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "General candidate/rule matcher driven by JSON rulesets.",
      package: [
        files: ["lib", "priv/rule_match", "mix.exs", ".formatter.exs", "README.md", "LICENSE"],
        licenses: ["MIT"],
        links: %{}
      ],
      docs: [main: "RuleMatch"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "dev/support", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_evolver, "~> 0.1.0"},
      {:postgrex, "~> 0.22.0", only: [:dev, :test]}
    ]
  end
end
