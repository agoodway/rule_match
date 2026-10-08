defmodule RuleMatch.CodecTest do
  use ExUnit.Case, async: true
  alias RuleMatch.{Codec, Rule, Roster}

  test "rule metadata and nested outcomes round-trip without compiled specificity" do
    rule =
      Rule.new(
        id: :example,
        description: "description",
        priority: -1,
        tags: [:tag],
        conditions: [],
        outcome: %{nested: %{items: [true, nil, :value]}},
        meta: %{specificity: 99, source: "manual"}
      )

    encoded = Codec.rule_to_map(rule)
    assert encoded["meta"] == %{"source" => "manual"}
    decoded = Codec.rule_from_map(encoded)
    assert decoded.id == "example"
    assert decoded.priority == -1
    assert decoded.tags == ["tag"]
    assert decoded.description == "description"
    assert decoded.outcome == %{nested: %{"items" => [true, nil, "value"]}}
    assert Codec.rule_to_map(decoded) == encoded
  end

  test "minimal rule defaults and omitted optional properties" do
    rule = Codec.rule_from_map(%{"id" => "minimal"})
    assert rule.conditions == []
    assert rule.outcome == %{}

    assert Codec.rule_to_map(rule) == %{
             "id" => "minimal",
             "priority" => 0,
             "conditions" => [],
             "outcome" => %{}
           }
  end

  for {label, value} <- [
        {"non-object", []},
        {"empty id", %{"id" => ""}},
        {"priority", %{"id" => "x", "priority" => 1.5}},
        {"conditions", %{"id" => "x", "conditions" => %{}}},
        {"outcome", %{"id" => "x", "outcome" => []}}
      ] do
    test "rejects malformed rule #{label}" do
      assert_raise ArgumentError, fn -> Codec.rule_from_map(unquote(Macro.escape(value))) end
    end
  end

  for {label, value} <- [
        {"non-object", []},
        {"missing op", %{}},
        {"missing value", %{"op" => "eq", "field" => "x"}},
        {"empty field", %{"op" => "present", "field" => ""}},
        {"non-string field", %{"op" => "blank", "field" => 1}},
        {"non-list membership", %{"op" => "in", "field" => "x", "values" => 1}},
        {"non-list children", %{"op" => "all", "conditions" => %{}}},
        {"non-string regex", %{"op" => "matches", "field" => "x", "pattern" => 1}},
        {"invalid regex", %{"op" => "matches", "field" => "x", "pattern" => "[", "flags" => ""}},
        {"unknown regex flag",
         %{"op" => "matches", "field" => "x", "pattern" => "x", "flags" => "z"}},
        {"non-string flags",
         %{"op" => "matches", "field" => "x", "pattern" => "x", "flags" => []}},
        {"missing negation", %{"op" => "not"}},
        {"empty predicate name", %{"op" => "pred", "name" => "", "args" => []}}
      ] do
    test "rejects malformed condition #{label}" do
      assert_raise ArgumentError, fn -> Codec.condition_from_map(unquote(Macro.escape(value))) end
    end
  end

  test "explicit regex flags survive encoding and control evaluation" do
    for {flags, value, expected} <- [
          {"", "ACME", false},
          {"i", "ACME", true},
          {"im", "other\nACME", true}
        ] do
      encoded = %{"op" => "matches", "field" => "value", "pattern" => "^acme$", "flags" => flags}
      condition = Codec.condition_from_map(encoded)
      assert RuleMatch.Condition.match?(condition, %{value: value}) == expected
      assert Codec.condition_to_map(condition) == encoded
    end
  end

  test "unsupported conditions and structs cannot be encoded" do
    assert_raise ArgumentError, fn -> Codec.condition_to_map({:unsupported, :x}) end
    assert_raise ArgumentError, fn -> Codec.to_json_value(%Rule{id: "x", conditions: []}) end
  end

  test "JSON values preserve booleans nulls and nested containers" do
    input = %{
      date: ~D[2026-01-01],
      utc: ~U[2026-01-01 00:00:00Z],
      naive: ~N[2026-01-01 00:00:00],
      regex: ~r/x/,
      values: [true, false, nil, :atom, 3, 1.5]
    }

    assert Codec.to_json_value(input) == %{
             "date" => "2026-01-01",
             "utc" => "2026-01-01T00:00:00Z",
             "naive" => "2026-01-01T00:00:00",
             "regex" => "x",
             "values" => [true, false, nil, "atom", 3, 1.5]
           }
  end

  test "unknown fields ops and values are not converted to new atoms" do
    suffix = System.unique_integer([:positive])
    field = "unknown_field_#{suffix}"
    value = "unknown_value_#{suffix}"
    op = "unknown_op_#{suffix}"

    assert {:eq, ^field, ^value} =
             Codec.condition_from_map(%{"op" => "eq", "field" => field, "value" => value})

    assert_raise ArgumentError, fn -> Codec.condition_from_map(%{"op" => op}) end

    for string <- [field, value, op],
        do: assert_raise(ArgumentError, fn -> String.to_existing_atom(string) end)
  end

  test "rosters support singular product and grouped cells with metadata" do
    map = %{
      "network" => [
        %{
          "provider" => "p",
          "product" => "basic",
          "effective_on" => "2026-01-01",
          "terminates_on" => "2027-01-01",
          "meta" => %{"source" => "contract"}
        }
      ]
    }

    book = Codec.rosters_from_map(map)

    assert {:ok, %{meta: %{"source" => "contract"}}} =
             Roster.member(book, :network, "p", "basic", ~D[2026-01-01])

    assert [%{"products" => ["basic"], "terminates_on" => "2027-01-01"}] =
             Codec.rosters_to_map(book)["network"]
  end

  for {label, value} <- [
        {"non-object", []},
        {"non-list entries", %{"a" => %{}}},
        {"non-object entry", %{"a" => [1]}},
        {"missing product", %{"a" => [%{"provider" => "p"}]}},
        {"invalid products", %{"a" => [%{"provider" => "p", "products" => "basic"}]}},
        {"invalid date type",
         %{"a" => [%{"provider" => "p", "product" => "basic", "effective_on" => 1}]}}
      ] do
    test "rejects malformed roster #{label}" do
      assert_raise ArgumentError, fn -> Codec.rosters_from_map(unquote(Macro.escape(value))) end
    end
  end

  test "pretty JSON escapes strings and preserves long and nested values" do
    data = %{
      "z" => Enum.to_list(1..13),
      "rules" => [%{"id" => String.duplicate("x", 120), "outcome" => %{"quote" => "\"\n\\"}}],
      "a" => [],
      "meta" => %{}
    }

    json = Codec.pretty(data)
    assert JSON.decode!(json) == data
    assert String.ends_with?(json, "\n")
    assert json == Codec.pretty(Map.new(Enum.reverse(Enum.to_list(data))))
    assert Codec.pretty(true) == "true\n"
  end
end
