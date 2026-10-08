defmodule RuleMatchTest do
  use ExUnit.Case, async: true

  alias RuleMatch.{Condition, Roster}

  test "unspecified fields are wildcards" do
    rules = [
      RuleMatch.rule("organization_only",
        priority: 1,
        conditions: [{:eq, :organization, "acme"}],
        outcome: %{access_status: :allowed}
      )
    ]

    {:ok, [match]} = RuleMatch.match(rules, %{organization: "acme", market: "north", extra: true})
    assert match.outcome.access_status == :allowed
  end

  test "missing field fails a value-requiring op and does not equal nil" do
    assert Condition.match?({:eq, :organization, nil}, %{}) == false
    assert Condition.match?({:eq, :organization, "acme"}, %{}) == false
    assert Condition.match?({:in, :market, ["north"]}, %{}) == false
    assert Condition.match?({:blank, :organization}, %{}) == true
    assert Condition.match?({:present, :organization}, %{organization: "acme"}) == true
  end

  test "false stored on a present key is not treated as missing" do
    assert Condition.match?({:eq, :has_privileges, false}, %{has_privileges: false}) == true
    assert Condition.match?({:eq, :has_privileges, true}, %{has_privileges: false}) == false
    assert Condition.match?({:present, :has_privileges}, %{has_privileges: false}) == true
  end

  test "string keys and case-insensitive equality" do
    assert Condition.match?({:eq, :organization, "Acme"}, %{"organization" => "acme"}) == true

    assert Condition.match?({:contains, :note, "EXAMPLE TEXT"}, %{
             note: "some example text here"
           }) == true
  end

  test "date bounds accept ISO strings and open ends" do
    candidate = %{"as_of" => "2000-02-01"}
    assert Condition.match?({:gte, :as_of, ~D[2000-02-01]}, candidate)
    assert Condition.match?({:between, :as_of, ~D[2000-01-01], nil}, candidate)
    refute Condition.match?({:lt, :as_of, ~D[2000-02-01]}, candidate)
  end

  test "dates compare chronologically, not as structs" do
    assert Condition.match?({:gte, :as_of, ~D[1998-01-01]}, %{
             as_of: ~D[2000-01-01]
           })

    refute Condition.match?({:gte, :as_of, ~D[2000-03-01]}, %{
             as_of: ~D[2000-02-29]
           })
  end

  test "best match ranks priority, then specificity" do
    rules = [
      RuleMatch.rule("broad",
        priority: 10,
        conditions: [{:eq, :organization, "acme"}],
        outcome: %{which: :broad}
      ),
      RuleMatch.rule("specific",
        priority: 10,
        conditions: [{:eq, :organization, "acme"}, {:eq, :market, "north"}],
        outcome: %{which: :specific}
      ),
      RuleMatch.rule("override",
        priority: 50,
        conditions: [{:eq, :organization, "acme"}],
        outcome: %{which: :override}
      )
    ]

    {:ok, winner} = RuleMatch.best(rules, %{organization: "acme", market: "north"})
    assert winner.outcome.which == :override

    {:ok, winner} = RuleMatch.best(Enum.take(rules, 2), %{organization: "acme", market: "north"})
    assert winner.outcome.which == :specific
  end

  test "select returns candidates that hit, and skips the rest" do
    rules = [
      RuleMatch.rule("organization_match",
        conditions: [{:eq, :organization, "acme"}],
        outcome: %{ok: true}
      )
    ]

    selected =
      RuleMatch.select(rules, [
        %{id: 1, organization: "acme"},
        %{id: 2, organization: "globex"},
        %{id: 3, organization: "Acme"}
      ])

    assert Enum.map(selected, & &1.candidate.id) == [1, 3]
    assert hd(selected).match.outcome.ok
  end

  test "roster membership is category and date specific" do
    book =
      Roster.new()
      |> Roster.put(:access_a, "member_a", "read", effective_on: ~D[1998-01-01])
      |> Roster.put(:access_a, "member_a", "write",
        effective_on: ~D[1998-01-01],
        terminates_on: ~D[1999-01-01]
      )

    assert Roster.member?(book, :access_a, "Member_A", "read", ~D[2000-01-01])
    refute Roster.member?(book, :access_a, "member_a", "write", ~D[2000-01-01])
    refute Roster.member?(book, :access_a, "member_a", "admin", ~D[2000-01-01])
    refute Roster.member?(book, :access_a, "someone_else", "read", ~D[2000-01-01])
  end

  test "explanation names the condition that failed" do
    rule =
      RuleMatch.rule("starter",
        conditions: [{:eq, :organization, "acme"}, {:eq, :tier, "starter"}]
      )

    [organization, tier] = RuleMatch.explain(rule, %{organization: "acme"})
    assert organization.passed
    refute tier.passed
    assert tier.actual == :missing
  end
end
