defmodule RuleMatch.EngineTest do
  use ExUnit.Case, async: true
  alias RuleMatch.{Rule, Ruleset, Roster}

  test "empty rules and failed rules return consistent no-match results" do
    for rules <- [[], [RuleMatch.rule("no", conditions: [{:eq, :x, 1}])]] do
      assert RuleMatch.match(rules, %{}) == {:ok, []}
      assert RuleMatch.best(rules, %{}) == :nomatch
      assert RuleMatch.decide(rules, %{}) == :nomatch
      assert RuleMatch.select(rules, [%{}]) == []
    end
  end

  test "ties retain input order and decisions include every ranked alternative" do
    rules =
      for id <- ["first", "second", "third"],
          do: RuleMatch.rule(id, outcome: %{result: id, rule_id: "incorrect", priority: 999})

    assert {:ok, matches} = RuleMatch.match(rules, %{})
    assert Enum.map(matches, & &1.rule.id) == ["first", "second", "third"]

    assert {:ok,
            %{
              rule_id: "first",
              priority: 0,
              specificity: 0,
              explanation: [],
              alternatives: [%{rule_id: "second"}, %{rule_id: "third"}]
            }} = RuleMatch.decide(rules, %{})

    assert {:ok, %{rule: %{id: "third"}}} = RuleMatch.best(Enum.reverse(rules), %{})
  end

  test "compile accepts maps keywords and structs and preserves metadata" do
    rules =
      RuleMatch.compile([
        %{id: :one, when: [{:eq, :x, 1}], result: %{ok: true}},
        [id: "two", conditions: []],
        Rule.new(
          id: "three",
          conditions: [{:all, [{:eq, :x, 1}, {:eq, :y, 2}]}],
          meta: %{source: "manual", specificity: 99}
        )
      ])

    assert Enum.map(rules, & &1.id) == ["one", "two", "three"]
    assert Enum.map(rules, & &1.meta.specificity) == [1, 0, 2]
    assert hd(rules).outcome == %{ok: true}
    assert List.last(rules).meta.source == "manual"
    assert RuleMatch.compile(rules) == rules

    [compiled] =
      RuleMatch.compile([
        %{id: "kept", reading: "Hello.", reading_fingerprint: "sha256:abc", conditions: []}
      ])

    assert compiled.reading == "Hello."
    assert compiled.reading_fingerprint == "sha256:abc"
  end

  test "a reading and fingerprint do not change the decision" do
    bare =
      RuleMatch.rule("acme",
        conditions: [{:eq, :payer, "acme"}],
        outcome: %{network_status: "in_network"}
      )

    annotated = %{bare | reading: "Payer is acme.", reading_fingerprint: "sha256:forged"}
    candidate = %{payer: "Acme"}

    assert RuleMatch.decide([bare], candidate) == RuleMatch.decide([annotated], candidate)
    assert RuleMatch.explain(bare, candidate) == RuleMatch.explain(annotated, candidate)

    {:ok, [bare_match]} = RuleMatch.match([bare], candidate)
    {:ok, [annotated_match]} = RuleMatch.match([annotated], candidate)

    assert Map.take(bare_match, [:outcome, :priority, :specificity, :score, :explanation]) ==
             Map.take(annotated_match, [:outcome, :priority, :specificity, :score, :explanation])
  end

  test "invalid rule identifiers are rejected" do
    for id <- [nil, "", 1, [], %{}], do: assert_raise(ArgumentError, fn -> Rule.new(id: id) end)
  end

  test "select all returns ranked matches and preserves original candidates" do
    ruleset =
      Ruleset.new(
        normalize: %{downcase: [:organization]},
        rules: [
          RuleMatch.rule("specific", priority: 2, conditions: [{:eq, :organization, "acme"}]),
          RuleMatch.rule("fallback")
        ]
      )

    candidate = %{"organization" => " ACME "}

    assert [
             %{
               candidate: ^candidate,
               matches: [%{rule: %{id: "specific"}}, %{rule: %{id: "fallback"}}],
               match: %{rule: %{id: "specific"}}
             }
           ] = RuleMatch.select(ruleset, [candidate], strategy: :all)

    assert RuleMatch.select(ruleset, []) == []
  end

  test "caller rosters override a matching name and preserve other ruleset rosters" do
    book = Roster.new() |> Roster.put(:a, "p", "read") |> Roster.put(:b, "p", "read")

    ruleset =
      Ruleset.new(
        rosters: book,
        rules:
          for(
            name <- [:a, :b],
            do: RuleMatch.rule(to_string(name), conditions: [{:roster, name, []}])
          )
      )

    candidate = %{member_id: "p", category: "read", as_of: ~D[2026-01-01]}
    assert {:ok, matches} = RuleMatch.match(ruleset, candidate, rosters: %{"a" => %{}})
    assert Enum.map(matches, & &1.rule.id) == ["b"]
  end

  test "higher-priority category shutdown overrides active roster" do
    ruleset =
      Ruleset.new(
        rosters: Roster.put(Roster.new(), :access, "p", "read"),
        rules: [
          RuleMatch.rule("membership",
            conditions: [{:roster, :access, []}],
            outcome: %{status: "allowed"}
          ),
          RuleMatch.rule("termination",
            priority: 10,
            conditions: [{:gte, :as_of, ~D[2026-07-01]}],
            outcome: %{status: "denied"}
          )
        ]
      )

    candidate = %{member_id: "p", category: "read", as_of: ~D[2026-07-01]}

    assert {:ok,
            %{rule_id: "termination", status: "denied", alternatives: [%{rule_id: "membership"}]}} =
             RuleMatch.decide(ruleset, candidate)

    assert {:ok, %{rule_id: "membership"}} =
             RuleMatch.decide(ruleset, %{candidate | as_of: ~D[2026-06-30]})
  end
end
