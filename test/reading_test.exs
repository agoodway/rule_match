defmodule RuleMatch.ReadingTest do
  use ExUnit.Case, async: true

  alias RuleMatch.{Reading, Roster, Rule, Ruleset}

  @golden "sha256:e8a5768db85c035f7fdcc3082de725cffa784e34bb333ad3da9ba3ff7e7c8afe"
  @bytes ~s({"conditions":[{"field":"payer","op":"eq","value":"acme"}],"normalize":{"dates":[],"downcase":["payer"]},"outcome":{"network_status":"in_network"},"priority":10,"rosters":{}})

  setup do
    ruleset =
      Ruleset.new(
        normalize: %{downcase: ["payer"], dates: []},
        rules: []
      )

    rule =
      Rule.new(
        id: "acme",
        priority: 10,
        conditions: [{:eq, "payer", "acme"}],
        outcome: %{network_status: "in_network"}
      )

    %{ruleset: ruleset, rule: rule}
  end

  test "golden vector hashes the canonical bytes", %{ruleset: ruleset, rule: rule} do
    assert :crypto.hash(:sha256, @bytes) |> Base.encode16(case: :lower) |> then(&("sha256:" <> &1)) ==
             @golden

    assert Reading.fingerprint(ruleset, rule) == @golden
  end

  test "key order, field atoms, and normalize order do not change the fingerprint", %{
    ruleset: ruleset
  } do
    from_json =
      RuleMatch.Codec.rule_from_map(%{
        "id" => "acme",
        "priority" => 10,
        "conditions" => [%{"value" => "acme", "field" => "payer", "op" => "eq"}],
        "outcome" => %{"network_status" => "in_network"}
      })

    atom_rule =
      Rule.new(
        id: "acme",
        priority: 10,
        conditions: [{:eq, :payer, "acme"}],
        outcome: %{network_status: "in_network"}
      )

    reordered =
      Ruleset.new(normalize: %{downcase: ["payer", "payer"], dates: []}, rules: [])

    assert Reading.fingerprint(ruleset, from_json) == @golden
    assert Reading.fingerprint(ruleset, atom_rule) == @golden
    assert Reading.fingerprint(reordered, atom_rule) == @golden
  end

  test "body changes, normalize membership, and predicate args change the fingerprint", %{
    ruleset: ruleset,
    rule: rule
  } do
    variants = [
      %{rule | priority: 11},
      %{rule | conditions: [{:eq, "payer", "globex"}]},
      %{rule | outcome: %{network_status: "out_of_network"}},
      %{rule | conditions: [{:pred, "near", [1]}]},
      %{rule | conditions: [{:pred, "near", [2]}]}
    ]

    fingerprints = Enum.map(variants, &Reading.fingerprint(ruleset, &1))
    assert @golden not in fingerprints
    assert Enum.uniq(fingerprints) == fingerprints

    other_normalize = Ruleset.new(normalize: %{downcase: ["payer", "tier"], dates: []}, rules: [])
    assert Reading.fingerprint(other_normalize, rule) != @golden
  end

  test "tags, description, meta, position, an unreferenced roster, and the reading stay outside the hash",
       %{ruleset: ruleset, rule: rule} do
    decorated = %{
      rule
      | tags: ["coverage"],
        description: "author",
        meta: %{source: "manual"},
        reading: "A different sentence.",
        reading_fingerprint: "sha256:old"
    }

    with_roster =
      Ruleset.new(
        normalize: %{downcase: ["payer"], dates: []},
        rosters: Roster.put(Roster.new(), "panel", "ann", "read"),
        rules: []
      )

    assert Reading.fingerprint(ruleset, decorated) == @golden
    assert Reading.fingerprint(with_roster, rule) == @golden
  end

  test "a roster inside not/any is hashed, and missing is distinct from empty", %{rule: rule} do
    nested =
      Rule.new(
        id: "member",
        conditions: [{:not, {:any, [{:roster, "panel", []}]}}]
      )

    missing = Ruleset.new(rules: [])
    empty = %{missing | rosters: %{"panel" => %{}}}

    filled =
      Ruleset.new(
        rosters: Roster.put(Roster.new(), "panel", "ann", "read", effective_on: ~D[2024-01-01]),
        rules: []
      )

    added =
      Roster.put(filled.rosters, "panel", "bea", "read", effective_on: ~D[2024-01-01])

    assert Reading.fingerprint(missing, nested) != Reading.fingerprint(empty, nested)
    assert Reading.fingerprint(empty, nested) != Reading.fingerprint(filled, nested)

    assert Reading.fingerprint(filled, nested) !=
             Reading.fingerprint(%{filled | rosters: added}, nested)

    assert Reading.fingerprint(filled, rule) == Reading.fingerprint(missing, rule)
  end

  test "status reports absent, unsealed, fresh, and stale", %{ruleset: ruleset, rule: rule} do
    fp = Reading.fingerprint(ruleset, rule)

    assert Reading.status(ruleset, %{rule | reading_fingerprint: "sha256:x"}) == :absent
    assert Reading.status(ruleset, %{rule | reading: "  ", reading_fingerprint: fp}) == :absent
    assert Reading.status(ruleset, %{rule | reading: "Hi."}) == :unsealed
    assert Reading.status(ruleset, %{rule | reading: "Hi.", reading_fingerprint: ""}) == :unsealed
    assert Reading.status(ruleset, %{rule | reading: "Hi.", reading_fingerprint: fp}) == :fresh

    assert Reading.status(ruleset, %{rule | reading: "Hi.", reading_fingerprint: "sha256:nope"}) ==
             :stale
  end

  test "seal fills, refreshes, preserves prose, and clears an orphan fingerprint", %{
    ruleset: ruleset,
    rule: rule
  } do
    open = %{ruleset | rules: [%{rule | reading: " Payer is acme. "}]}
    sealed = Ruleset.seal_readings(open)
    [accepted] = sealed.rules
    assert accepted.reading == " Payer is acme. "
    assert accepted.reading_fingerprint == @golden
    assert Reading.status(sealed, accepted) == :fresh

    stale = %{sealed | rules: [%{accepted | priority: 11}]}
    assert Reading.status(stale, hd(stale.rules)) == :stale
    refreshed = Ruleset.seal_readings(stale)
    assert hd(refreshed.rules).reading == " Payer is acme. "
    assert Reading.status(refreshed, hd(refreshed.rules)) == :fresh
    assert hd(refreshed.rules).reading_fingerprint != @golden

    orphan =
      %{
        ruleset
        | rules: [%{rule | reading: nil, reading_fingerprint: "sha256:leftover"}]
      }

    [cleared] = Ruleset.seal_readings(orphan).rules
    assert cleared.reading == nil
    assert cleared.reading_fingerprint == nil
  end
end
