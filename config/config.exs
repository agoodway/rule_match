import Config

if config_env() in [:dev, :test] do
  config :rule_match, ecto_repos: [RuleMatch.Dev.Repo]

  config :rule_match, RuleMatch.Dev.Repo, types: RuleMatch.Dev.PostgresTypes

  if config_env() == :test do
    config :rule_match, RuleMatch.Dev.Repo,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10
  end
end
