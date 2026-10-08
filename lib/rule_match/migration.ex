defmodule RuleMatch.Migration do
  @moduledoc """
  Versioned PostgreSQL migrations for stored rulesets, using EctoEvolver.

  Call from an application's own Ecto migration:

      def up, do: RuleMatch.Migration.up(prefix: "rule_match")
      def down, do: RuleMatch.Migration.down(prefix: "rule_match")

  The default prefix is `"rule_match"`; queries must use the same prefix.
  Versioned SQL creates the schema, `rulesets` and `rules`, constraints,
  and indexes. The `rulesets` table tracks migration versions independently
  of a definition's application version string. Rollback drops both library
  tables and preserves the schema and unrelated objects.

  Migrations never run automatically on library startup or ruleset loading.
  Applications supply their own Repo and PostgreSQL driver.
  """

  use EctoEvolver,
    otp_app: :rule_match,
    default_prefix: "rule_match",
    tracking_object: {:table, "rulesets"},
    versions: [RuleMatch.Migrations.V01]
end
