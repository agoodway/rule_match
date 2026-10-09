defmodule RuleMatch.StoreTest do
  use RuleMatch.DataCase

  alias Ecto.Changeset
  alias RuleMatch.{Reading, Ruleset}
  alias RuleMatch.Store

  setup %{repo: repo, prefix: prefix}, do: %{opts: [repo: repo, prefix: prefix]}

  test "CRUD preserves scoped identities and ordered rules", %{opts: opts} do
    assert {:ok, []} = Store.list_rulesets(opts)
    assert {:ok, parent} = Store.create_ruleset(%{key: "coverage"}, opts)
    assert {:ok, %{rules: []}} = Store.fetch_ruleset("coverage", opts)
    assert {:ok, first} = Store.create_rule("coverage", %{rule_id: "first"}, opts)
    assert first.position == 0
    assert {:ok, second} = Store.create_rule("coverage", %{rule_id: "second"}, opts)
    assert second.position == 1
    assert {:ok, [^first, ^second]} = Store.list_rules("coverage", opts)
    assert {:ok, ^second} = Store.fetch_rule("coverage", "second", opts)

    assert {:ok, renamed_rule} =
             Store.update_rule(
               "coverage",
               "first",
               %{"rule_id" => "renamed", "priority" => -4},
               opts
             )

    assert renamed_rule.id == first.id and renamed_rule.priority == -4
    assert {:error, :not_found} = Store.fetch_rule("coverage", "first", opts)
    assert {:ok, ^renamed_rule} = Store.fetch_rule("coverage", "renamed", opts)
    assert {:ok, updated} = Store.update_ruleset("coverage", %{meta: %{"source" => "test"}}, opts)
    assert updated.id == parent.id
    assert {:ok, %{rules: [^renamed_rule, ^second]}} = Store.fetch_ruleset("coverage", opts)
    assert {:ok, renamed_parent} = Store.update_ruleset("coverage", %{"key" => "new-key"}, opts)
    assert renamed_parent.id == parent.id
    assert {:error, :not_found} = Store.fetch_ruleset("coverage", opts)
    assert {:ok, ^second} = Store.fetch_rule("new-key", "second", opts)
    assert {:ok, deleted_rule} = Store.delete_rule("new-key", "second", opts)
    assert deleted_rule.id == second.id and deleted_rule.__meta__.state == :deleted
    assert {:error, :not_found} = Store.fetch_rule("new-key", "second", opts)
    assert {:ok, deleted} = Store.delete_ruleset("new-key", opts)
    assert deleted.id == parent.id
    assert {:error, :not_found} = Store.fetch_ruleset("new-key", opts)
    assert {:error, :not_found} = Store.fetch_rule("new-key", "renamed", opts)
    assert {:ok, []} = Store.list_rulesets(opts)
  end

  test "empty collections and missing records have distinct results", %{opts: opts} do
    assert {:ok, _} = Store.create_ruleset(%{key: "empty"}, opts)
    assert {:ok, []} = Store.list_rules("empty", opts)
    assert {:ok, %{rules: []}} = Store.fetch_ruleset("empty", opts)

    for result <- [
          Store.fetch_ruleset("missing", opts),
          Store.update_ruleset("missing", %{}, opts),
          Store.delete_ruleset("missing", opts),
          Store.list_rules("missing", opts),
          Store.fetch_rule("missing", "rule", opts),
          Store.create_rule("missing", %{rule_id: "rule"}, opts),
          Store.update_rule("missing", "rule", %{}, opts),
          Store.delete_rule("missing", "rule", opts),
          Store.fetch_rule("empty", "missing", opts),
          Store.update_rule("empty", "missing", %{}, opts),
          Store.delete_rule("empty", "missing", opts)
        ] do
      assert result == {:error, :not_found}
    end
  end

  test "positions allow ties and retain gaps; omitted positions append after the maximum", %{
    opts: opts
  } do
    assert {:ok, _} = Store.create_ruleset(%{key: "ordered"}, opts)
    assert {:ok, first} = Store.create_rule("ordered", %{rule_id: "z", position: 4}, opts)
    assert {:ok, second} = Store.create_rule("ordered", %{rule_id: "a", position: 4}, opts)
    assert {:ok, third} = Store.create_rule("ordered", %{rule_id: "tail"}, opts)
    assert third.position == 5
    assert {:ok, [^first, ^second, ^third]} = Store.list_rules("ordered", opts)
    assert {:ok, %{rules: [^first, ^second, ^third]}} = Store.fetch_ruleset("ordered", opts)
    assert {:ok, deleted} = Store.delete_rule("ordered", "a", opts)
    assert deleted.id == second.id
    assert {:ok, fourth} = Store.create_rule("ordered", %{rule_id: "last"}, opts)
    assert fourth.position == 6
    assert {:ok, moved} = Store.update_rule("ordered", "last", %{position: 0}, opts)
    assert {:ok, [^moved, ^first, ^third]} = Store.list_rules("ordered", opts)
    assert {:ok, %{rules: [^moved, ^first, ^third]}} = Store.fetch_ruleset("ordered", opts)
  end

  test "blank tags survive writes and match file runtime definitions", %{opts: opts} do
    tags = ["", "tag", "  ", "\t\n"]
    assert {:ok, _} = Store.create_ruleset(%{key: "tags"}, opts)
    assert {:ok, rule} = Store.create_rule("tags", %{rule_id: "tagged", tags: tags}, opts)
    assert rule.tags == tags
    assert {:ok, stored} = Store.fetch_rule("tags", "tagged", opts)
    assert stored.tags == tags

    assert {:ok, runtime} =
             RuleMatch.Ruleset.load("tags", Keyword.put(opts, :adapter, RuleMatch.Adapters.Ecto))

    assert {:ok, file_runtime} =
             RuleMatch.Ruleset.from_map(%{"rules" => [%{"id" => "tagged", "tags" => tags}]})

    assert runtime.rules == file_runtime.rules
    updated_tags = Enum.reverse(tags)
    assert {:ok, updated} = Store.update_rule("tags", "tagged", %{tags: updated_tags}, opts)
    assert updated.tags == updated_tags
    assert {:ok, loaded} = Store.fetch_rule("tags", "tagged", opts)
    assert loaded.tags == updated_tags
  end

  test "out-of-range rule integers return changeset errors without writes", %{opts: opts} do
    assert {:ok, _} = Store.create_ruleset(%{key: "bounds"}, opts)
    assert {:ok, original} = Store.create_rule("bounds", %{rule_id: "original"}, opts)

    for {field, value} <- [
          priority: -2_147_483_649,
          priority: 2_147_483_648,
          position: 2_147_483_648
        ] do
      assert {:error, changeset} =
               Store.create_rule("bounds", %{field => value, :rule_id => "invalid"}, opts)

      assert Keyword.has_key?(changeset.errors, field)

      assert {:error, changeset} =
               Store.update_rule("bounds", "original", %{field => value}, opts)

      assert Keyword.has_key?(changeset.errors, field)
    end

    assert {:ok, [^original]} = Store.list_rules("bounds", opts)

    for {id, priority} <- [{"minimum", -2_147_483_648}, {"maximum", 2_147_483_647}] do
      assert {:ok, rule} =
               Store.create_rule(
                 "bounds",
                 %{rule_id: id, priority: priority, position: 2_147_483_647},
                 opts
               )

      assert rule.priority == priority and rule.position == 2_147_483_647
    end
  end

  test "automatic append overflow returns a position error and explicit positions remain usable",
       %{opts: opts} do
    assert {:ok, _} = Store.create_ruleset(%{key: "append-limit"}, opts)

    assert {:ok, maximum} =
             Store.create_rule(
               "append-limit",
               %{rule_id: "maximum", position: 2_147_483_647},
               opts
             )

    assert {:error, changeset} = Store.create_rule("append-limit", %{rule_id: "overflow"}, opts)
    assert Keyword.has_key?(changeset.errors, :position)
    assert {:ok, [^maximum]} = Store.list_rules("append-limit", opts)

    assert {:ok, explicit} =
             Store.create_rule("append-limit", %{rule_id: "explicit", position: 0}, opts)

    assert explicit.position == 0
  end

  test "keys sort exactly and rule identifiers are scoped to their parent", %{opts: opts} do
    for key <- ["z", "b", "a"] do
      assert {:ok, _} = Store.create_ruleset(%{key: key}, opts)
    end

    assert {:ok, parents} = Store.list_rulesets(opts)
    assert Enum.map(parents, & &1.key) == ["a", "b", "z"]

    for key <- ["case", "Case", " MiXeD "] do
      assert {:ok, _} = Store.create_ruleset(%{"key" => key}, opts)
      assert {:ok, _} = Store.create_rule(key, %{"rule_id" => "shared"}, opts)
    end

    assert {:error, :not_found} = Store.fetch_ruleset("MiXeD", opts)
    assert {:ok, one} = Store.fetch_rule("Case", "shared", opts)
    assert {:ok, two} = Store.fetch_rule("case", "shared", opts)
    assert one.ruleset_id != two.ruleset_id
    assert {:ok, _} = Store.update_rule("Case", "shared", %{rule_id: "changed"}, opts)
    assert {:ok, ^two} = Store.fetch_rule("case", "shared", opts)
    assert {:ok, _} = Store.delete_rule("Case", "changed", opts)
    assert {:ok, ^two} = Store.fetch_rule("case", "shared", opts)
  end

  test "invalid and duplicate writes leave data intact and later writes usable", %{opts: opts} do
    assert {:error, %Changeset{}} = Store.create_ruleset(%{key: " "}, opts)
    assert {:error, %Changeset{}} = Store.create_ruleset(%{key: "nested", rules: []}, opts)
    assert {:ok, parent} = Store.create_ruleset(%{key: "safe"}, opts)
    assert {:ok, other} = Store.create_ruleset(%{key: "other"}, opts)
    assert {:ok, child} = Store.create_rule("safe", %{rule_id: "safe"}, opts)
    assert {:error, %Changeset{}} = Store.create_ruleset(%{key: "safe"}, opts)
    assert {:error, %Changeset{}} = Store.update_ruleset("safe", %{key: "other"}, opts)
    assert {:error, %Changeset{}} = Store.update_ruleset("safe", %{rules: [%{}]}, opts)
    assert {:error, %Changeset{}} = Store.update_ruleset("safe", %{meta: nil}, opts)
    assert {:error, %Changeset{}} = Store.create_rule("safe", %{rule_id: "safe"}, opts)

    for attrs <- [
          %{rule_id: "invalid", position: -1},
          %{rule_id: "invalid", position: nil},
          %{rule_id: "invalid", conditions: [%{"op" => "unknown"}]},
          %{rule_id: "invalid", ruleset_id: other.id},
          %{"rule_id" => "invalid", "ruleset" => %{"id" => other.id}}
        ] do
      assert {:error, %Changeset{}} = Store.create_rule("safe", attrs, opts)
    end

    for attrs <- [%{ruleset_id: other.id}, %{position: -1}, %{outcome: nil}, %{rule_id: ""}] do
      assert {:error, %Changeset{}} = Store.update_rule("safe", "safe", attrs, opts)
    end

    assert {:ok, ^child} = Store.fetch_rule("safe", "safe", opts)
    assert {:ok, fetched} = Store.fetch_ruleset("safe", opts)
    assert fetched.id == parent.id and fetched.meta == %{} and fetched.rules == [child]
    assert {:ok, next} = Store.create_rule("safe", %{rule_id: "next"}, opts)
    assert next.position == 1
    assert {:error, %Changeset{}} = Store.update_rule("safe", "next", %{rule_id: "safe"}, opts)
    assert {:ok, ^next} = Store.fetch_rule("safe", "next", opts)
    assert {:ok, _} = Store.update_rule("safe", "next", %{priority: -10}, opts)
  end

  test "server-managed fields are not writable and default configuration works", %{opts: opts} do
    assert {:ok, parent} =
             Store.create_ruleset(%{key: "managed", id: 999, inserted_at: nil}, opts)

    assert parent.id != 999 and parent.inserted_at != nil

    assert {:ok, child} =
             Store.create_rule("managed", %{rule_id: "x", id: 999, inserted_at: nil}, opts)

    assert child.id != 999 and child.inserted_at != nil

    assert {:ok, unchanged} =
             Store.update_rule("managed", "x", %{id: 999, inserted_at: nil}, opts)

    assert unchanged.id == child.id and unchanged.inserted_at == child.inserted_at
    previous = Application.get_env(:rule_match, :repo)
    Application.put_env(:rule_match, :repo, opts[:repo])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:rule_match, :repo, previous),
        else: Application.delete_env(:rule_match, :repo)
    end)

    assert {:ok, _} = Store.fetch_ruleset("managed")
    assert {:ok, _} = Store.list_rulesets()
  end

  test "every entry point rejects invalid configuration", %{opts: opts} do
    calls = [
      &Store.list_rulesets/1,
      &Store.fetch_ruleset("x", &1),
      &Store.create_ruleset(%{key: "x"}, &1),
      &Store.update_ruleset("x", %{}, &1),
      &Store.delete_ruleset("x", &1),
      &Store.list_rules("x", &1),
      &Store.fetch_rule("x", "r", &1),
      &Store.create_rule("x", %{rule_id: "r"}, &1),
      &Store.update_rule("x", "r", %{}, &1),
      &Store.delete_rule("x", "r", &1)
    ]

    for call <- calls, invalid <- [[repo: nil], [prefix: " "], [prefix: nil]] do
      assert {:error, {:invalid_config, message}} = call.(Keyword.merge(opts, invalid))
      assert is_binary(message)
    end

    for key <- [nil, 42, "", " "] do
      assert {:error, {:invalid_config, _}} = Store.fetch_ruleset(key, opts)
      assert {:error, {:invalid_config, _}} = Store.update_ruleset(key, %{}, opts)
      assert {:error, {:invalid_config, _}} = Store.delete_ruleset(key, opts)
      assert {:error, {:invalid_config, _}} = Store.list_rules(key, opts)
      assert {:error, {:invalid_config, _}} = Store.fetch_rule(key, "r", opts)
      assert {:error, {:invalid_config, _}} = Store.create_rule(key, %{rule_id: "r"}, opts)
      assert {:error, {:invalid_config, _}} = Store.update_rule(key, "r", %{}, opts)
      assert {:error, {:invalid_config, _}} = Store.delete_rule(key, "r", opts)
    end

    for id <- [nil, 42, "", " "] do
      assert {:error, {:invalid_config, _}} = Store.fetch_rule("x", id, opts)
      assert {:error, {:invalid_config, _}} = Store.update_rule("x", id, %{}, opts)
      assert {:error, {:invalid_config, _}} = Store.delete_rule("x", id, opts)
    end
  end

  test "a reading seals the post-update body and a body-only edit stays stale", %{opts: opts} do
    assert {:ok, _} =
             Store.create_ruleset(
               %{
                 key: "readings",
                 normalize: %{"downcase" => ["payer"], "dates" => []},
                 rosters: %{
                   "panel" => [
                     %{
                       "member" => "ann",
                       "categories" => ["read"],
                       "effective_on" => "2024-01-01"
                     }
                   ]
                 }
               },
               opts
             )

    reading = "Payer acme is in network."

    assert {:ok, created} =
             Store.create_rule(
               "readings",
               %{
                 rule_id: "acme",
                 priority: 10,
                 reading: reading,
                 conditions: [%{"op" => "eq", "field" => "payer", "value" => "acme"}],
                 outcome: %{"network_status" => "in_network"}
               },
               opts
             )

    assert created.reading == reading
    {fresh_ruleset, fresh_rule} = status_of(created, opts)
    assert Reading.status(fresh_ruleset, fresh_rule) == :fresh
    assert fresh_rule.reading_fingerprint == created.reading_fingerprint

    assert {:ok, edited} =
             Store.update_rule(
               "readings",
               "acme",
               %{
                 priority: 12,
                 conditions: [%{"op" => "eq", "field" => "payer", "value" => "globex"}],
                 outcome: %{"network_status" => "out"}
               },
               opts
             )

    assert edited.reading == reading
    assert edited.reading_fingerprint == created.reading_fingerprint
    {stale_ruleset, stale_rule} = status_of(edited, opts)
    assert Reading.status(stale_ruleset, stale_rule) == :stale
    assert stale_rule.priority == 12
    assert stale_rule.conditions == [{:eq, "payer", "globex"}]

    assert {:ok, resealed} = Store.update_rule("readings", "acme", %{reading: reading}, opts)
    assert resealed.reading == reading
    assert resealed.reading_fingerprint != created.reading_fingerprint
    {again_ruleset, again_rule} = status_of(resealed, opts)
    assert Reading.status(again_ruleset, again_rule) == :fresh
    assert Reading.fingerprint(again_ruleset, again_rule) == resealed.reading_fingerprint
    assert again_rule.priority == 12

    assert {:error, forged} =
             Store.update_rule(
               "readings",
               "acme",
               %{priority: 1, reading_fingerprint: "sha256:forged"},
               opts
             )

    assert {:reading_fingerprint, {"is set by the library", _}} =
             List.keyfind!(forged.errors, :reading_fingerprint, 0)

    assert {:ok, unchanged} = Store.fetch_rule("readings", "acme", opts)
    assert unchanged.priority == 12
    assert unchanged.reading_fingerprint == resealed.reading_fingerprint

    assert {:error, bad_type} =
             Store.create_rule("readings", %{rule_id: "bad", reading: 1}, opts)

    assert {:reading, {"must be a string", _}} = List.keyfind!(bad_type.errors, :reading, 0)
    assert {:error, :not_found} = Store.fetch_rule("readings", "bad", opts)

    assert {:ok, cleared} = Store.update_rule("readings", "acme", %{reading: " "}, opts)
    assert cleared.reading == nil
    assert cleared.reading_fingerprint == nil
    {absent_ruleset, absent_rule} = status_of(cleared, opts)
    assert Reading.status(absent_ruleset, absent_rule) == :absent
  end

  test "sealing after a roster edit refreshes only the rule that names it", %{opts: opts} do
    assert {:ok, _} =
             Store.create_ruleset(
               %{
                 key: "seal-roster",
                 rosters: %{
                   "panel" => [
                     %{
                       "member" => "ann",
                       "categories" => ["read"],
                       "effective_on" => "2024-01-01"
                     }
                   ]
                 }
               },
               opts
             )

    assert {:ok, member} =
             Store.create_rule(
               "seal-roster",
               %{
                 rule_id: "member",
                 reading: "Ann is on the panel.",
                 conditions: [%{"op" => "roster", "roster" => "panel"}]
               },
               opts
             )

    assert {:ok, other} =
             Store.create_rule(
               "seal-roster",
               %{
                 rule_id: "other",
                 reading: "Priority is zero.",
                 conditions: [%{"op" => "eq", "field" => "payer", "value" => "acme"}]
               },
               opts
             )

    assert {:ok, _} =
             Store.update_ruleset(
               "seal-roster",
               %{
                 rosters: %{
                   "panel" => [
                     %{
                       "member" => "ann",
                       "categories" => ["read"],
                       "effective_on" => "2024-01-01"
                     },
                     %{
                       "member" => "bea",
                       "categories" => ["read"],
                       "effective_on" => "2024-01-01"
                     }
                   ]
                 }
               },
               opts
             )

    assert {:ok, stale_member} = Store.fetch_rule("seal-roster", "member", opts)
    assert {:ok, still_other} = Store.fetch_rule("seal-roster", "other", opts)
    assert stale_member.reading_fingerprint == member.reading_fingerprint
    assert still_other.reading_fingerprint == other.reading_fingerprint

    assert {:ok, [sealed_member, sealed_other]} = Store.seal_readings("seal-roster", opts)
    assert sealed_member.rule_id == "member"
    assert sealed_other.rule_id == "other"
    assert sealed_member.reading == "Ann is on the panel."
    assert sealed_member.reading_fingerprint != member.reading_fingerprint
    assert sealed_other.reading_fingerprint == other.reading_fingerprint

    assert Store.seal_readings("missing-readings", opts) == {:error, :not_found}
    assert {:error, {:invalid_config, _}} = Store.seal_readings(" ", opts)
  end

  test "parent mutations propagate unexpected database exceptions", %{opts: opts} do
    missing_prefix = "missing_store_#{System.unique_integer([:positive, :monotonic])}"
    invalid_opts = Keyword.put(opts, :prefix, missing_prefix)

    # Separate rolled-back transactions keep both probes usable under Sandbox.
    assert_raise Postgrex.Error, fn -> Store.update_ruleset("x", %{}, invalid_opts) end
    assert_raise Postgrex.Error, fn -> Store.delete_ruleset("x", invalid_opts) end
  end

  test "parent fetch obtains all children through one joined snapshot", %{opts: opts, repo: repo} do
    assert {:ok, _} = Store.create_ruleset(%{key: "snapshot"}, opts)

    for id <- ["one", "two", "three"],
        do: assert({:ok, _} = Store.create_rule("snapshot", %{rule_id: id}, opts))

    event = repo.config()[:telemetry_prefix] ++ [:query]
    handler_id = "store-query-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler_id, event, &__MODULE__.capture_query/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert {:ok, %{rules: rules}} = Store.fetch_ruleset("snapshot", opts)
    assert Enum.map(rules, & &1.rule_id) == ["one", "two", "three"]
    assert_receive {:store_query, query}
    assert query =~ "LEFT OUTER JOIN"
    refute_receive {:store_query, _}
  end

  def capture_query(_event, _measurements, metadata, pid),
    do: send(pid, {:store_query, metadata.query})

  defp status_of(record, opts) do
    {:ok, parent} = Store.fetch_ruleset("readings", opts)

    ruleset = %Ruleset{
      normalize: %{
        downcase: parent.normalize["downcase"],
        dates: parent.normalize["dates"]
      },
      rosters: RuleMatch.Codec.rosters_from_map(parent.rosters)
    }

    rule =
      RuleMatch.Codec.rule_from_map(%{
        "id" => record.rule_id,
        "priority" => record.priority,
        "conditions" => record.conditions,
        "outcome" => record.outcome,
        "reading" => record.reading,
        "reading_fingerprint" => record.reading_fingerprint
      })

    {ruleset, rule}
  end
end
