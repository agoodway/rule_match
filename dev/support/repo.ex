defmodule RuleMatch.Dev.Repo do
  use Ecto.Repo,
    otp_app: :rule_match,
    adapter: Ecto.Adapters.Postgres
end
