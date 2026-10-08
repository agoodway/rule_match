defmodule RuleMatch.Migration do
  @moduledoc "Versioned PostgreSQL migrations for stored rulesets."

  use EctoEvolver,
    otp_app: :rule_match,
    default_prefix: "rule_match",
    tracking_object: {:table, "rulesets"},
    versions: [RuleMatch.Migrations.V01]
end
