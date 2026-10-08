defmodule Mix.Tasks.RuleMatch.Setup do
  @moduledoc "Creates the local development or test database and installs ruleset tables."
  @shortdoc "Sets up the local RuleMatch database"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    unless Mix.env() in [:dev, :test] do
      Mix.raise("mix rule_match.setup is available only in dev and test")
    end

    Mix.Task.run("app.start")
    apply(RuleMatch.Dev.Setup, :run, [])
  end
end
