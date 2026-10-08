import Config

if config_env() in [:dev, :test] do
  connection =
    case System.get_env("RULE_MATCH_DATABASE_URL") do
      nil ->
        [
          hostname: "127.0.0.1",
          port: String.to_integer(System.get_env("RULE_MATCH_POSTGRES_PORT", "5432")),
          username: "rule_match",
          password: "rule_match",
          database: "rule_match_#{config_env()}"
        ]

      url ->
        [url: url]
    end

  for repo <- [RuleMatch.Dev.Repo, RuleMatch.Dev.UnboxedRepo] do
    config :rule_match, repo, connection
  end
end
