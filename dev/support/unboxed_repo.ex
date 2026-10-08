defmodule RuleMatch.Dev.UnboxedRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :rule_match,
    adapter: Ecto.Adapters.Postgres
end
