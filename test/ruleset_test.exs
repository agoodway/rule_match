defmodule RuleMatch.RulesetTest do
  use ExUnit.Case, async: true

  alias RuleMatch.{Codec, Roster, Ruleset}

  @every_op [
    {:eq, :payer, "acme"},
    {:neq, "pcp_network", "network_d"},
    {:in, :plan_type, ["hmo", "pos"]},
    {:not_in, :product_line, ["exchange"]},
    {:contains, :card_note, "example text"},
    {:matches, :member_id, ~r/^w\d+$/},
    {:present, :provider_id},
    {:blank, :package_id},
    {:gt, :age, 17},
    {:gte, :date_of_service, ~D[2000-02-01]},
    {:lt, :age, 65},
    {:lte, :date_of_service, "2000-02-29"},
    {:between, :date_of_service, ~D[2000-01-01], nil},
    {:all, [{:eq, :a, 1}, {:any, [{:eq, :b, true}, {:none, [{:eq, :c, nil}]}]}]},
    {:not, {:eq, :has_privileges, false}},
    {:pred, :custom, [1, "two"]},
    {:roster, :network_a, [product: :product]},
    {:roster, "network_b", [product: :any]},
    {:roster, "network_c", [provider: :npi, product: {:literal, "basic"}, as_of: :visit_date]}
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
      payer: "Acme",
      pcp_network: "network_b",
      plan_type: "HMO",
      product_line: "commercial",
      card_note: "contains EXAMPLE TEXT here",
      member_id: "W123",
      provider_id: "provider_a",
      age: 40,
      date_of_service: ~D[2000-02-10],
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
      |> Roster.put(:network_a, "provider_a", "basic", effective_on: ~D[1998-01-01])
      |> Roster.put(:network_a, "provider_a", "plus",
        effective_on: ~D[1998-01-01],
        terminates_on: ~D[1999-01-01]
      )
      |> Roster.put(:network_b, "provider_b", :any,
        effective_on: ~D[1996-01-01],
        meta: %{"source" => "example_fixture"}
      )

    ruleset =
      Ruleset.new(
        name: "test",
        version: "1",
        normalize: %{downcase: [:payer], dates: [:date_of_service]},
        rules: [
          RuleMatch.rule("network_a",
            priority: 50,
            tags: [:roster],
            conditions: [{:roster, :network_a, []}],
            outcome: %{network_status: :in_network}
          ),
          RuleMatch.rule("acme",
            conditions: [{:eq, :payer, "acme"}],
            outcome: %{packages: ["1"], file_claim: false}
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
    assert [%{id: "network_a", priority: 50, tags: ["roster"]}, %{id: "acme"}] = loaded.rules
    assert hd(loaded.rules).meta.specificity == 1

    candidate = %{
      "payer" => "NETWORK_A",
      provider_id: "provider_a",
      product: "basic",
      date_of_service: "2000-01-01"
    }

    assert {:ok, %{rule_id: "network_a", network_status: "in_network"}} =
             RuleMatch.decide(loaded, candidate)

    assert RuleMatch.decide(loaded, %{candidate | product: "plus"}) == :nomatch
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
               ~s({"rosters": {"m": [{"provider": "p", "product": "x", "effective_on": "soon"}]}})
             )

    assert message =~ "ISO 8601"

    assert {:error, :enoent} = Ruleset.load("/nonexistent/ruleset.json")
  end
end
