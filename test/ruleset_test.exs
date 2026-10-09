defmodule RuleMatch.RulesetTest do
  use ExUnit.Case, async: true

  alias RuleMatch.{Codec, Reading, Roster, Rule, Ruleset}

  @every_op [
    {:eq, :organization, "acme"},
    {:neq, "team", "access_d"},
    {:in, :tier, ["starter", "standard"]},
    {:not_in, :segment, ["restricted"]},
    {:contains, :note, "example text"},
    {:matches, :reference, ~r/^w\d+$/},
    {:present, :member_id},
    {:blank, :package_id},
    {:gt, :age, 17},
    {:gte, :as_of, ~D[2000-02-01]},
    {:lt, :age, 65},
    {:lte, :as_of, "2000-02-29"},
    {:between, :as_of, ~D[2000-01-01], nil},
    {:all, [{:eq, :a, 1}, {:any, [{:eq, :b, true}, {:none, [{:eq, :c, nil}]}]}]},
    {:not, {:eq, :has_privileges, false}},
    {:pred, :custom, [1, "two"]},
    {:roster, :access_a, [category: :category]},
    {:roster, "access_b", [category: :any]},
    {:roster, "access_c", [member: :asset_id, category: {:literal, "read"}, as_of: :checked_on]}
  ]

  test "every condition op survives a json round trip" do
    for condition <- @every_op do
      map = Codec.condition_to_map(condition)
      decoded = map |> JSON.encode!() |> JSON.decode!() |> Codec.condition_from_map()
      assert Codec.condition_to_map(decoded) == map, "round trip changed #{inspect(condition)}"
    end
  end

  test "decoded conditions evaluate like the originals" do
    candidate = %{
      organization: "Acme",
      team: "access_b",
      tier: "STARTER",
      segment: "general",
      note: "contains EXAMPLE TEXT here",
      reference: "W123",
      member_id: "member_a",
      age: 40,
      as_of: ~D[2000-02-10],
      a: 1,
      b: true,
      c: "x",
      has_privileges: true
    }

    for condition <- Enum.reject(@every_op, &(elem(&1, 0) in [:pred, :roster])) do
      decoded = condition |> Codec.condition_to_map() |> Codec.condition_from_map()

      assert RuleMatch.Condition.match?(decoded, candidate) ==
               RuleMatch.Condition.match?(condition, candidate),
             "#{inspect(condition)} evaluates differently after decoding"
    end
  end

  test "a ruleset round-trips through a file" do
    book =
      Roster.new()
      |> Roster.put(:access_a, "member_a", "read", effective_on: ~D[1998-01-01])
      |> Roster.put(:access_a, "member_a", "write",
        effective_on: ~D[1998-01-01],
        terminates_on: ~D[1999-01-01]
      )
      |> Roster.put(:access_b, "member_b", :any,
        effective_on: ~D[1996-01-01],
        meta: %{"source" => "example_fixture"}
      )

    ruleset =
      Ruleset.new(
        name: "test",
        version: "1",
        normalize: %{downcase: [:organization], dates: [:as_of]},
        rules: [
          RuleMatch.rule("access_a",
            priority: 50,
            tags: [:roster],
            conditions: [{:roster, :access_a, []}],
            outcome: %{access_status: :allowed}
          ),
          RuleMatch.rule("acme",
            conditions: [{:eq, :organization, "acme"}],
            outcome: %{packages: ["1"], notify: false}
          )
        ],
        rosters: book
      )

    path = Path.join(System.tmp_dir!(), "rule_match_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    :ok = Ruleset.save(ruleset, path)
    loaded = Ruleset.load!(path)

    assert Ruleset.to_json(loaded) == Ruleset.to_json(ruleset)
    assert loaded.rosters == book
    assert [%{id: "access_a", priority: 50, tags: ["roster"]}, %{id: "acme"}] = loaded.rules
    assert hd(loaded.rules).meta.specificity == 1

    candidate = %{
      "organization" => "ACCESS_A",
      member_id: "member_a",
      category: "read",
      as_of: "2000-01-01"
    }

    assert {:ok, %{rule_id: "access_a", access_status: "allowed"}} =
             RuleMatch.decide(loaded, candidate)

    assert RuleMatch.decide(loaded, %{candidate | category: "write"}) == :nomatch
  end

  test "named predicates resolve by string name" do
    {:ok, ruleset} =
      Ruleset.from_json(
        ~s({"rules": [{"id": "adult", "conditions": [{"op": "pred", "name": "older_than", "args": 17}]}]})
      )

    older_than = fn candidate, n -> candidate.age > n end

    assert {:ok, _} = RuleMatch.best(ruleset, %{age: 30}, predicates: %{older_than: older_than})

    assert {:ok, _} =
             RuleMatch.best(ruleset, %{age: 30}, predicates: %{"older_than" => older_than})

    assert RuleMatch.best(ruleset, %{age: 30}) == :nomatch
  end

  test "malformed rulesets are rejected with a reason" do
    assert {:error, {:invalid_json, _}} = Ruleset.from_json("{nope")
    assert {:error, {:unsupported_format, 2}} = Ruleset.from_json(~s({"format": 2}))

    assert {:error, {:invalid_ruleset, message}} =
             Ruleset.from_json(~s({"rules": [{"id": "x", "conditions": [{"op": "bogus"}]}]}))

    assert message =~ "unknown condition op"

    assert {:error, {:invalid_ruleset, message}} =
             Ruleset.from_json(
               ~s({"rules": [{"id": "x", "conditions": [{"op": "eq", "value": 1}]}]})
             )

    assert message =~ "field"

    assert {:error, {:invalid_ruleset, _}} =
             Ruleset.from_json(~s({"rules": [{"conditions": []}]}))

    assert {:error, {:invalid_ruleset, message}} =
             Ruleset.from_json(
               ~s({"rosters": {"m": [{"member": "p", "category": "x", "effective_on": "soon"}]}})
             )

    assert message =~ "ISO 8601"

    assert {:error, :enoent} = Ruleset.load("/nonexistent/ruleset.json")
  end

  test "saving a file does not seal, and a forged fingerprint stays stale" do
    ruleset =
      Ruleset.new(
        normalize: %{downcase: ["payer"], dates: []},
        rules: [
          Rule.new(
            id: "acme",
            priority: 10,
            reading: "Payer is acme.",
            conditions: [{:eq, "payer", "acme"}],
            outcome: %{network_status: "in_network"}
          )
        ]
      )

    assert Reading.status(ruleset, hd(ruleset.rules)) == :unsealed

    path =
      Path.join(System.tmp_dir!(), "rule-match-reading-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    assert Ruleset.save(ruleset, path) == :ok
    assert {:ok, saved} = File.read!(path) |> Ruleset.from_json()
    assert hd(saved.rules).reading == "Payer is acme."
    assert hd(saved.rules).reading_fingerprint == nil
    assert Reading.status(saved, hd(saved.rules)) == :unsealed

    sealed = Ruleset.seal_readings(saved)
    assert Ruleset.save(sealed, path) == :ok
    assert {:ok, fresh} = File.read!(path) |> Ruleset.from_json()
    assert Reading.status(fresh, hd(fresh.rules)) == :fresh

    {:ok, map} = JSON.decode(File.read!(path))

    forged =
      put_in(map, ["rules", Access.at(0), "reading_fingerprint"], "sha256:forged")

    File.write!(path, JSON.encode!(forged))
    assert {:ok, stale} = File.read!(path) |> Ruleset.from_json()
    assert hd(stale.rules).reading_fingerprint == "sha256:forged"
    assert Reading.status(stale, hd(stale.rules)) == :stale

    edited = put_in(map, ["rules", Access.at(0), "conditions", Access.at(0), "value"], "globex")
    File.write!(path, JSON.encode!(edited))
    assert {:ok, edited_ruleset} = File.read!(path) |> Ruleset.from_json()
    assert Reading.status(edited_ruleset, hd(edited_ruleset.rules)) == :stale
  end

  test "an empty roster survives save and load and stays distinct from a missing roster" do
    rule =
      Rule.new(
        id: "member",
        reading: "The panel roster applies.",
        conditions: [{:roster, "panel", []}]
      )

    empty =
      Ruleset.new(rosters: %{"panel" => %{}}, rules: [rule])
      |> Ruleset.seal_readings()

    missing = %{empty | rosters: %{}}

    assert Reading.fingerprint(empty, hd(empty.rules)) !=
             Reading.fingerprint(missing, hd(empty.rules))

    assert Codec.rosters_from_map(%{"panel" => []}) == %{"panel" => %{}}

    path =
      Path.join(
        System.tmp_dir!(),
        "rule-match-empty-roster-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert Ruleset.save(empty, path) == :ok
    assert {:ok, reloaded} = File.read!(path) |> Ruleset.from_json()
    assert Map.has_key?(reloaded.rosters, "panel")
    assert Reading.status(reloaded, hd(reloaded.rules)) == :fresh
  end
end
