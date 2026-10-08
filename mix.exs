defmodule RuleMatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :rule_match,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [],
      description: "General candidate/rule matcher driven by JSON rulesets.",
      package: [
        licenses: ["MIT"],
        links: %{}
      ],
      docs: [main: "RuleMatch"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
