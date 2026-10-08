defmodule RuleMatch.SchemaTest do
  use RuleMatch.DataCase

  alias Ecto.Changeset
  alias RuleMatch.Schemas.{Rule, Ruleset}
  alias RuleMatch.StoredData

  defp record, do: %Rule{ruleset_id: 1, position: 0}
  defp rule(attrs \\ %{}), do: Map.merge(%{"id" => "Case-Sensitive", "conditions" => []}, attrs)
  defp has_error?(changeset, field), do: Keyword.has_key?(changeset.errors, field)

  test "required keys and rule identifiers preserve spelling and case" do
    assert Ruleset.changeset(%Ruleset{}, %{key: "coverage"}).valid?

    assert Changeset.get_field(Ruleset.changeset(%Ruleset{}, %{key: " MiXeD "}), :key) ==
             " MiXeD "

    assert Rule.changeset(record(), %{rule_id: "catch_all", conditions: []}).valid?

    for value <- [nil, "", " ", "\t\n"] do
      assert has_error?(Ruleset.changeset(%Ruleset{}, %{key: value}), :key)
      assert has_error?(Rule.changeset(record(), %{rule_id: value}), :rule_id)
      assert {:error, {:id, _}} = StoredData.validate_rule(rule(%{"id" => value}))
    end

    assert {:error, {:id, _}} = StoredData.validate_rule(%{"conditions" => []})
    assert has_error?(Ruleset.changeset(%Ruleset{}, %{}), :key)
    assert has_error?(Rule.changeset(record(), %{}), :rule_id)
    assert has_error?(Rule.changeset(%Rule{position: 0}, %{rule_id: "x"}), :ruleset_id)
  end

  test "position requires a nonnegative integer and priorities may be negative" do
    assert has_error?(Rule.changeset(record(), %{rule_id: "x", position: -1}), :position)
    assert has_error?(Rule.changeset(%Rule{ruleset_id: 1}, %{rule_id: "x"}), :position)
    assert Rule.changeset(record(), %{rule_id: "x", position: 12, priority: -5}).valid?
    assert has_error?(Rule.changeset(record(), %{rule_id: "x", priority: nil}), :priority)
  end

  test "parents and associations cannot be assigned through user attributes" do
    assert has_error?(Rule.changeset(record(), %{rule_id: "x", ruleset_id: 99}), :ruleset_id)
    assert has_error?(Rule.changeset(record(), %{rule_id: "x", ruleset: %{id: 99}}), :ruleset)
    refute Ruleset.changeset(%Ruleset{}, %{key: "x", rules: []}).valid?
  end

  test "server-managed identifiers and timestamps cannot be changed" do
    timestamp = ~U[2026-01-01 00:00:00.000000Z]

    for {schema, attrs} <- [
          {%Ruleset{id: 4, inserted_at: timestamp, updated_at: timestamp}, %{key: "x"}},
          {%Rule{
             id: 5,
             ruleset_id: 1,
             position: 0,
             inserted_at: timestamp,
             updated_at: timestamp
           }, %{rule_id: "x"}}
        ] do
      changeset =
        schema.__struct__.changeset(
          schema,
          Map.merge(attrs, %{id: 999, inserted_at: nil, updated_at: nil})
        )

      assert changeset.valid?
      assert Changeset.get_field(changeset, :id) == schema.id
      assert Changeset.get_field(changeset, :inserted_at) == timestamp
      assert Changeset.get_field(changeset, :updated_at) == timestamp
    end
  end

  test "mixed attributes normalize without atomizing unknown field names" do
    dynamic = "unknown_task4_#{System.unique_integer([:positive])}"

    assert {:ok, %{"key" => "x", "name" => "Example", ^dynamic => 1}} =
             StoredData.normalize_attrs(%{:key => "x", "name" => "Example", dynamic => 1})

    assert Ruleset.changeset(%Ruleset{}, %{:key => "x", "name" => "Example", dynamic => 1}).valid?
    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic) end
    assert {:ok, %{"key" => "x"}} = StoredData.normalize_attrs(%{:key => "x", "key" => "x"})
    assert {:error, _} = StoredData.normalize_attrs(%{:key => "x", "key" => "y"})
    refute Ruleset.changeset(%Ruleset{}, %{:key => "x", "key" => "y"}).valid?
    assert {:error, _} = StoredData.normalize_attrs(%{1 => "x"})
    refute Ruleset.changeset(%Ruleset{}, []).valid?
  end

  test "normalization lists require strings" do
    for bad <- [nil, "payer", [1], [:payer], [%{}]] do
      normalize = %{"downcase" => bad, "dates" => []}
      assert {:error, {:normalize, _}} = StoredData.validate_ruleset(%{"normalize" => normalize})

      assert has_error?(
               Ruleset.changeset(%Ruleset{}, %{key: "x", normalize: normalize}),
               :normalize
             )
    end

    assert StoredData.validate_ruleset(%{
             "normalize" => %{"downcase" => ["NewField"], "dates" => ["date"]}
           }) == :ok
  end

  test "explicit null objects and nonobjects are rejected" do
    for field <- [:normalize, :rosters, :meta], bad <- [nil, [], "x", 1] do
      assert {:error, {^field, _}} = StoredData.validate_ruleset(%{Atom.to_string(field) => bad})
      assert has_error?(Ruleset.changeset(%Ruleset{}, %{field => bad, :key => "x"}), field)
    end

    for field <- [:outcome, :meta], bad <- [nil, [], "x", 1] do
      assert {:error, {^field, _}} =
               StoredData.validate_rule(rule(%{Atom.to_string(field) => bad}))

      assert has_error?(Rule.changeset(record(), %{field => bad, :rule_id => "x"}), field)
    end
  end

  test "malformed roster dates and product containers report roster errors" do
    entry = %{"provider" => "Provider", "products" => ["basic"], "effective_on" => nil}

    for bad <- [
          nil,
          [],
          %{"net" => nil},
          %{"net" => [nil]},
          %{"net" => [Map.put(entry, "effective_on", "2026-02-30")]},
          %{"net" => [Map.put(entry, "terminates_on", 12)]},
          %{"net" => [Map.put(entry, "products", "basic")]},
          %{"net" => [Map.put(entry, "provider", false)]},
          %{"net" => [Map.put(entry, "meta", nil)]}
        ] do
      assert {:error, {:rosters, _}} = StoredData.validate_ruleset(%{"rosters" => bad})
    end

    # Product values retain the codec's existing JSON semantics.
    assert StoredData.validate_ruleset(%{
             "rosters" => %{"net" => [Map.put(entry, "products", [false, nil, 2, %{"x" => 1}])]}
           }) == :ok
  end

  test "unknown condition operators and malformed condition containers are rejected" do
    for bad <- [
          nil,
          %{},
          [nil],
          [%{}],
          [%{"op" => "surprise"}],
          [%{"op" => "in", "field" => "x", "values" => nil}]
        ] do
      assert {:error, {:conditions, _}} = StoredData.validate_rule(rule(%{"conditions" => bad}))
      assert has_error?(Rule.changeset(record(), %{rule_id: "x", conditions: bad}), :conditions)
    end
  end

  test "compound children are validated recursively before decoding" do
    for condition <- [
          %{"op" => "all", "conditions" => nil},
          %{"op" => "any", "conditions" => [false]},
          %{"op" => "none", "conditions" => [%{"op" => "not", "condition" => nil}]},
          %{"op" => "not", "condition" => []}
        ] do
      assert {:error, {:conditions, _}} =
               StoredData.validate_rule(rule(%{"conditions" => [condition]}))
    end

    assert StoredData.validate_rule(
             rule(%{"conditions" => [%{"op" => "all", "conditions" => []}]})
           ) == :ok
  end

  test "invalid flagged and unflagged regexes are rejected recursively" do
    base = %{"op" => "matches", "field" => "member", "pattern" => "["}

    for condition <- [
          base,
          Map.put(base, "flags", "i"),
          Map.put(base, "pattern", 12),
          %{base | "pattern" => "ok"} |> Map.put("flags", "z")
        ],
        wrapped <- [condition, %{"op" => "not", "condition" => condition}] do
      assert {:error, {:conditions, _}} =
               StoredData.validate_rule(rule(%{"conditions" => [wrapped]}))
    end

    assert StoredData.validate_rule(rule(%{"conditions" => [%{base | "pattern" => "^W\\d+$"}]})) ==
             :ok
  end

  test "metadata and nested JSON reject non-JSON terms" do
    for bad <- [
          %{"value" => self()},
          %{"value" => fn -> :ok end},
          %{"value" => {:tuple}},
          %{"value" => ~D[2026-01-01]},
          %{atom_key: "value"},
          %{"invalid_utf8" => <<255>>}
        ] do
      assert {:error, {:meta, _}} = StoredData.validate_rule(rule(%{"meta" => bad}))
      assert {:error, {:meta, _}} = StoredData.validate_ruleset(%{"meta" => bad})
    end

    assert {:error, {:outcome, _}} =
             StoredData.validate_rule(rule(%{"outcome" => %{"x" => self()}}))

    assert StoredData.validate_rule(
             rule(%{
               "outcome" => %{"flag" => false, "nested" => [nil, true]},
               "meta" => %{"null" => nil}
             })
           ) == :ok
  end

  test "tags require string items and scalar rule values are checked" do
    for bad <- [nil, "x", [1], [:tag]] do
      assert {:error, {:tags, _}} = StoredData.validate_rule(rule(%{"tags" => bad}))
      assert has_error?(Rule.changeset(record(), %{rule_id: "x", tags: bad}), :tags)
    end

    assert {:error, {:priority, _}} = StoredData.validate_rule(rule(%{"priority" => "1"}))
    assert {:error, {:description, _}} = StoredData.validate_rule(rule(%{"description" => []}))
  end

  test "shared ruleset validation guards contained rules and format" do
    for bad <- [nil, %{}, [nil], [%{"id" => " "}]] do
      assert {:error, {:rules, _}} = StoredData.validate_ruleset(%{"rules" => bad})
    end

    assert {:error, {:format, _}} = StoredData.validate_ruleset(%{"format" => 99})
    assert StoredData.validate_ruleset(%{"rules" => [rule()]}) == :ok
    assert {:error, {:base, _}} = StoredData.validate_ruleset(nil)
    assert {:error, {:base, _}} = StoredData.validate_rule([])
  end

  test "shared validation accepts every supported condition shape" do
    field = "dynamic_#{System.unique_integer([:positive])}"

    conditions =
      Enum.map(
        ~w(eq neq contains gt gte lt lte),
        &%{"op" => &1, "field" => field, "value" => false}
      ) ++
        Enum.map(
          ~w(in not_in),
          &%{"op" => &1, "field" => field, "values" => [nil, false, %{"x" => 1}]}
        ) ++
        Enum.map(~w(present blank), &%{"op" => &1, "field" => field}) ++
        [
          %{"op" => "between", "field" => field, "from" => nil, "to" => "2026-01-01"},
          %{"op" => "matches", "field" => field, "pattern" => "^x$", "flags" => "im"},
          %{"op" => "pred", "name" => "predicate", "args" => %{"flag" => false}},
          %{"op" => "roster", "roster" => "net", "product" => "*"},
          %{"op" => "roster", "roster" => "net", "product" => false},
          %{"op" => "roster", "roster" => "net", "product_field" => field}
        ]

    for condition <- conditions do
      assert StoredData.validate_rule(rule(%{"conditions" => [condition]})) == :ok
      assert Rule.changeset(record(), %{rule_id: "x", conditions: [condition]}).valid?
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
  end

  test "updates validate complete candidates including unchanged malformed fields" do
    assert has_error?(
             Ruleset.changeset(%Ruleset{key: "x", normalize: nil}, %{name: "Updated"}),
             :normalize
           )

    assert has_error?(
             Rule.changeset(%Rule{ruleset_id: 1, position: 0, rule_id: "x", conditions: [nil]}, %{
               description: "Updated"
             }),
             :conditions
           )
  end

  test "typed JSONB arrays, defaults, associations, and UTC timestamps round-trip", %{
    repo: repo,
    prefix: prefix
  } do
    parent = repo.insert!(Ruleset.changeset(%Ruleset{}, %{key: "MiXeD"}), prefix: prefix)
    conditions = [%{"op" => "eq", "field" => "flag", "value" => false}]

    child =
      repo.insert!(
        Rule.changeset(%Rule{ruleset_id: parent.id, position: 3}, %{
          rule_id: "MiXeD",
          conditions: conditions,
          outcome: %{"flag" => false}
        }),
        prefix: prefix
      )

    loaded = repo.get!(Rule, child.id, prefix: prefix)
    assert loaded.conditions == conditions
    assert loaded.outcome == %{"flag" => false}
    assert loaded.meta == %{} and loaded.tags == [] and loaded.priority == 0
    assert parent.normalize == %{"downcase" => [], "dates" => []}
    assert parent.rosters == %{} and parent.meta == %{}
    assert %DateTime{time_zone: "Etc/UTC", microsecond: {_, 6}} = loaded.inserted_at
    assert %DateTime{time_zone: "Etc/UTC", microsecond: {_, 6}} = loaded.updated_at
    assert repo.preload(parent, :rules, prefix: prefix).rules == [loaded]
    assert repo.preload(loaded, :ruleset, prefix: prefix).ruleset.id == parent.id

    assert repo.query!("SELECT pg_typeof(conditions)::text FROM rule_match.rules WHERE id = $1", [
             child.id
           ]).rows == [["jsonb[]"]]
  end

  test "duplicate ruleset keys become changeset errors", %{repo: repo, prefix: prefix} do
    repo.insert!(Ruleset.changeset(%Ruleset{}, %{key: "duplicate"}), prefix: prefix)

    assert {:error, changeset} =
             repo.insert(Ruleset.changeset(%Ruleset{}, %{key: "duplicate"}), prefix: prefix)

    assert has_error?(changeset, :key)
  end

  test "duplicate identifiers within a ruleset become changeset errors", %{
    repo: repo,
    prefix: prefix
  } do
    parent = repo.insert!(Ruleset.changeset(%Ruleset{}, %{key: "parent"}), prefix: prefix)
    attrs = %{rule_id: "duplicate"}
    trusted = %Rule{ruleset_id: parent.id, position: 0}
    repo.insert!(Rule.changeset(trusted, attrs), prefix: prefix)
    assert {:error, changeset} = repo.insert(Rule.changeset(trusted, attrs), prefix: prefix)
    assert has_error?(changeset, :rule_id)
  end

  test "different parents reuse identifiers and equal positions; parent deletion cascades", %{
    repo: repo,
    prefix: prefix
  } do
    parents =
      for key <- ["Case", "case"] do
        parent = repo.insert!(Ruleset.changeset(%Ruleset{}, %{key: key}), prefix: prefix)

        for rule_id <- ["shared", "other"] do
          repo.insert!(
            Rule.changeset(%Rule{ruleset_id: parent.id, position: 7}, %{rule_id: rule_id}),
            prefix: prefix
          )
        end

        assert length(repo.preload(parent, :rules, prefix: prefix).rules) == 2
        parent
      end

    [first, second] = parents
    assert length(repo.all(Rule, prefix: prefix)) == 4
    repo.delete!(first, prefix: prefix)
    assert Enum.all?(repo.all(Rule, prefix: prefix), &(&1.ruleset_id == second.id))
    assert length(repo.all(Rule, prefix: prefix)) == 2
    repo.delete!(second, prefix: prefix)
    assert repo.all(Rule, prefix: prefix) == []
  end

  test "missing parents become foreign-key changeset errors", %{repo: repo, prefix: prefix} do
    assert {:error, changeset} =
             repo.insert(
               Rule.changeset(%Rule{ruleset_id: 9_999_999_999, position: 0}, %{rule_id: "orphan"}),
               prefix: prefix
             )

    assert has_error?(changeset, :ruleset_id)
  end

  test "position database constraint is translated", %{repo: repo, prefix: prefix} do
    parent = repo.insert!(Ruleset.changeset(%Ruleset{}, %{key: "position-check"}), prefix: prefix)

    changeset =
      Rule.changeset(%Rule{ruleset_id: parent.id, position: 0}, %{rule_id: "x"})
      |> Changeset.put_change(:position, -1)

    assert {:error, failed} = repo.insert(changeset, prefix: prefix)
    assert has_error?(failed, :position)
  end
end
