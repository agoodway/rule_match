defmodule RuleMatch.Migrations.V01 do
  @moduledoc false

  use EctoEvolver.Version,
    otp_app: :rule_match,
    version: "01",
    sql_path: "rule_match/sql/versions"
end
