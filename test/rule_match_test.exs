defmodule RuleMatchTest do
  use ExUnit.Case, async: true

  alias RuleMatch.{Condition, Roster}

  test "unspecified fields are wildcards" do
    rules = [
      RuleMatch.rule("payer_only",
        priority: 1,
        conditions: [{:eq, :payer, "acme"}],
        outcome: %{network_status: :in_network}
      )
    ]

    {:ok, [match]} = RuleMatch.match(rules, %{payer: "acme", market: "north", extra: true})
    assert match.outcome.network_status == :in_network
  end

  test "missing field fails a value-requiring op and does not equal nil" do
    assert Condition.match?({:eq, :payer, nil}, %{}) == false
    assert Condition.match?({:eq, :payer, "acme"}, %{}) == false
    assert Condition.match?({:in, :market, ["north"]}, %{}) == false
    assert Condition.match?({:blank, :payer}, %{}) == true
    assert Condition.match?({:present, :payer}, %{payer: "acme"}) == true
  end

  test "false stored on a present key is not treated as missing" do
    assert Condition.match?({:eq, :has_privileges, false}, %{has_privileges: false}) == true
    assert Condition.match?({:eq, :has_privileges, true}, %{has_privileges: false}) == false
    assert Condition.match?({:present, :has_privileges}, %{has_privileges: false}) == true
  end

  test "string keys and case-insensitive equality" do
    assert Condition.match?({:eq, :payer, "Acme"}, %{"payer" => "acme"}) == true

    assert Condition.match?({:contains, :card_note, "EXAMPLE TEXT"}, %{
             card_note: "some example text here"
           }) == true
  end

  test "date bounds accept ISO strings and open ends" do
    candidate = %{"date_of_service" => "2000-02-01"}
    assert Condition.match?({:gte, :date_of_service, ~D[2000-02-01]}, candidate)
    assert Condition.match?({:between, :date_of_service, ~D[2000-01-01], nil}, candidate)
    refute Condition.match?({:lt, :date_of_service, ~D[2000-02-01]}, candidate)
  end

  test "dates compare chronologically, not as structs" do
    assert Condition.match?({:gte, :date_of_service, ~D[1998-01-01]}, %{
             date_of_service: ~D[2000-01-01]
           })

    refute Condition.match?({:gte, :date_of_service, ~D[2000-03-01]}, %{
             date_of_service: ~D[2000-02-29]
           })
  end

  test "best match ranks priority, then specificity" do
    rules = [
      RuleMatch.rule("broad",
        priority: 10,
        conditions: [{:eq, :payer, "acme"}],
        outcome: %{which: :broad}
      ),
      RuleMatch.rule("specific",
        priority: 10,
        conditions: [{:eq, :payer, "acme"}, {:eq, :market, "north"}],
        outcome: %{which: :specific}
      ),
      RuleMatch.rule("override",
        priority: 50,
        conditions: [{:eq, :payer, "acme"}],
        outcome: %{which: :override}
      )
    ]

    {:ok, winner} = RuleMatch.best(rules, %{payer: "acme", market: "north"})
    assert winner.outcome.which == :override

    {:ok, winner} = RuleMatch.best(Enum.take(rules, 2), %{payer: "acme", market: "north"})
    assert winner.outcome.which == :specific
  end

  test "select returns candidates that hit, and skips the rest" do
    rules = [RuleMatch.rule("inn", conditions: [{:eq, :payer, "acme"}], outcome: %{ok: true})]

    selected =
      RuleMatch.select(rules, [
        %{id: 1, payer: "acme"},
        %{id: 2, payer: "globex"},
        %{id: 3, payer: "Acme"}
      ])

    assert Enum.map(selected, & &1.candidate.id) == [1, 3]
    assert hd(selected).match.outcome.ok
  end

  test "roster membership is product and date specific" do
    book =
      Roster.new()
      |> Roster.put(:network_a, "provider_a", "basic", effective_on: ~D[1998-01-01])
      |> Roster.put(:network_a, "provider_a", "plus",
        effective_on: ~D[1998-01-01],
        terminates_on: ~D[1999-01-01]
      )

    assert Roster.member?(book, :network_a, "Provider_A", "basic", ~D[2000-01-01])
    refute Roster.member?(book, :network_a, "provider_a", "plus", ~D[2000-01-01])
    refute Roster.member?(book, :network_a, "provider_a", "premium", ~D[2000-01-01])
    refute Roster.member?(book, :network_a, "someone_else", "basic", ~D[2000-01-01])
  end

  test "explanation names the condition that failed" do
    rule = RuleMatch.rule("hmo", conditions: [{:eq, :payer, "acme"}, {:eq, :plan_type, "hmo"}])
    [payer, plan] = RuleMatch.explain(rule, %{payer: "acme"})
    assert payer.passed
    refute plan.passed
    assert plan.actual == :missing
  end
end
