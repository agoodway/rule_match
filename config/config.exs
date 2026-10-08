import Config

if config_env() in [:dev, :test] do
  config :rule_match, ecto_repos: [RuleMatch.Dev.Repo]

  for repo <- [RuleMatch.Dev.Repo, RuleMatch.Dev.UnboxedRepo] do
    config :rule_match, repo, types: RuleMatch.Dev.PostgresTypes
  end

  config :rule_match, RuleMatch.Dev.UnboxedRepo,
    pool: DBConnection.ConnectionPool,
    pool_size: 10

  if config_env() == :test do
    config :rule_match, RuleMatch.Dev.Repo,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10

    for repo <- [RuleMatch.Dev.Repo, RuleMatch.Dev.UnboxedRepo] do
      config :rule_match, repo, log: false
    end
  end
end
