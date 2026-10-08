defmodule RuleMatch.MigrationTest do
  use ExUnit.Case, async: false

  alias EctoEvolver.Adapters.Postgres
  alias RuleMatch.Dev.UnboxedRepo

  setup do
    prefix = "RuleMatch-Migration-#{System.unique_integer([:positive, :monotonic])}"
    escaped = Postgres.escape_identifier(prefix)
    UnboxedRepo.query!("CREATE SCHEMA #{escaped}")

    on_exit(fn -> UnboxedRepo.query!("DROP SCHEMA #{escaped} CASCADE") end)

    %{prefix: prefix, escaped: escaped}
  end

  test "version one creates the tables and tracks upgrades", %{prefix: prefix, escaped: escaped} do
    assert RuleMatch.Migration.current_version() == 1
    assert migrate(:up, 1, prefix) == :ok
    assert version(prefix) == 1
    assert tables(prefix) == ["rules", "rulesets", "schema_migrations"]
    assert migrate(:up, 1, prefix) == :already_up
    assert migrate(:up, 2, prefix) == :ok
    assert version(prefix) == 1

    [[id, normalize, rosters, meta, inserted_at, updated_at]] =
      UnboxedRepo.query!("""
      INSERT INTO #{escaped}.rulesets (key, inserted_at, updated_at)
      VALUES ('Sample', '2026-10-08 12:34:56.123456', '2026-10-08 12:34:56.654321')
      RETURNING id, normalize, rosters, meta, inserted_at, updated_at
      """).rows

    assert is_integer(id)
    assert normalize == %{"downcase" => [], "dates" => []}
    assert rosters == %{}
    assert meta == %{}
    assert inserted_at == ~N[2026-10-08 12:34:56.123456]
    assert updated_at == ~N[2026-10-08 12:34:56.654321]

    assert UnboxedRepo.query!(
             """
             INSERT INTO #{escaped}.rules (ruleset_id, rule_id, position, inserted_at, updated_at)
             VALUES ($1, 'rule', 0, now(), now())
             RETURNING priority, conditions, outcome, tags, meta
             """,
             [id]
           ).rows == [[0, [], %{}, [], %{}]]

    assert UnboxedRepo.query!(
             "SELECT data_type FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'rules' AND column_name = 'id'",
             [prefix]
           ).rows == [["bigint"]]

    assert UnboxedRepo.query!(
             "SELECT indexname FROM pg_indexes WHERE schemaname = $1 ORDER BY indexname",
             [prefix]
           ).rows == [
             ["rules_pkey"],
             ["rules_ruleset_id_position_id_index"],
             ["rules_ruleset_id_rule_id_index"],
             ["rulesets_key_index"],
             ["rulesets_pkey"],
             ["schema_migrations_pkey"]
           ]

    UnboxedRepo.query!("DELETE FROM #{escaped}.rulesets WHERE id = $1", [id])
    assert UnboxedRepo.query!("SELECT count(*) FROM #{escaped}.rules").rows == [[0]]
  end

  test "repeat setup is safe" do
    assert RuleMatch.Dev.Setup.run() == :ok
    assert RuleMatch.Dev.Setup.run() == :ok
    assert version("rule_match") == 1
    assert "rules" in tables("rule_match")
    assert "rulesets" in tables("rule_match")
    assert UnboxedRepo.config()[:pool] == DBConnection.ConnectionPool
  end

  test "quoted-prefix rollback preserves unrelated tables", %{prefix: prefix, escaped: escaped} do
    UnboxedRepo.query!("CREATE TABLE #{escaped}.sentinel (id INTEGER)")
    assert migrate(:up, 1, prefix) == :ok
    assert migrate(:down, 1, prefix) == :ok
    assert version(prefix) == 0
    assert tables(prefix) == ["schema_migrations", "sentinel"]

    assert UnboxedRepo.query!("SELECT nspname FROM pg_namespace WHERE nspname = $1", [prefix]).rows ==
             [[prefix]]
  end

  defp migrate(direction, timestamp, prefix) do
    apply(Ecto.Migrator, direction, [
      UnboxedRepo,
      timestamp,
      RuleMatch.Dev.Migration,
      [prefix: prefix, log: false]
    ])
  end

  defp version(prefix), do: Postgres.get_version(UnboxedRepo, prefix, {:table, "rulesets"})

  defp tables(prefix) do
    UnboxedRepo.query!(
      "SELECT tablename FROM pg_tables WHERE schemaname = $1 ORDER BY tablename",
      [prefix]
    ).rows
    |> List.flatten()
  end
end
