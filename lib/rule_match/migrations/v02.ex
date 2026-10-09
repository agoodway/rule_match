defmodule RuleMatch.Migrations.V02 do
  @moduledoc false

  use EctoEvolver.Version,
    otp_app: :rule_match,
    version: "02",
    sql_path: "rule_match/sql/versions"
end
