defmodule RuleMatch.RulesetEdgeTest do
  use ExUnit.Case, async: true
  alias RuleMatch.Ruleset

  test "normalization converts dates and downcases only configured fields" do
    ruleset =
      Ruleset.new(
        normalize: %{
          downcase: [:payer, :flag, :missing],
          dates: [:date, :utc, :naive, :invalid, :number, :missing]
        }
      )

    candidate = %{
      "payer" => " ACME ",
      flag: false,
      date: " 2026-01-01 ",
      utc: ~U[2026-01-02 23:00:00Z],
      naive: ~N[2026-01-03 00:00:00],
      invalid: "not-a-date",
      number: 42,
      untouched: " UPPER "
    }

    normalized = Ruleset.normalize(ruleset, candidate)
    assert normalized.payer == "acme"
    assert normalized.flag == false
    assert normalized.date == ~D[2026-01-01]
    assert normalized.utc == ~D[2026-01-02]
    assert normalized.naive == ~D[2026-01-03]
    assert normalized.invalid == "not-a-date"
    assert normalized.number == 42
    assert normalized.untouched == " UPPER "
    refute Map.has_key?(normalized, :missing)
    assert Ruleset.normalize(ruleset, normalized) == normalized
    assert candidate["payer"] == " ACME "
  end

  test "unknown candidate fields remain strings and can be normalized without atom creation" do
    key = "custom_field_#{System.unique_integer([:positive])}"
    ruleset = Ruleset.new(normalize: %{downcase: [key]})
    assert Ruleset.normalize(ruleset, %{key => " VALUE "}) == %{key => "value"}
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "optional ruleset metadata survives JSON round-trips" do
    original =
      Ruleset.new(
        name: "example",
        version: "2",
        description: "description",
        meta: %{source: :manual}
      )

    assert {:ok, decoded} = original |> Ruleset.to_json() |> Ruleset.from_json()
    assert decoded.name == "example"
    assert decoded.version == "2"
    assert decoded.description == "description"
    assert decoded.meta == %{"source" => "manual"}
    assert Ruleset.to_json(decoded) == Ruleset.to_json(original)

    assert Ruleset.to_map(Ruleset.new()) == %{
             "format" => 1,
             "normalize" => %{"downcase" => [], "dates" => []},
             "rules" => [],
             "rosters" => %{}
           }
  end

  test "empty JSON objects default to a usable empty ruleset" do
    assert {:ok, ruleset} = Ruleset.from_json("{}")
    assert ruleset == Ruleset.new()
    assert RuleMatch.decide(ruleset, %{}) == :nomatch
  end

  test "non-object JSON documents are rejected" do
    for json <- ["[]", "null", "true", "1", "\"text\""] do
      assert {:error, {:invalid_ruleset, message}} = Ruleset.from_json(json)
      assert message =~ "expected an object"
    end
  end

  test "load returns decode errors and load! raises useful errors" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rule_match_invalid_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, "{")
    assert {:error, {:invalid_json, _}} = Ruleset.load(path)
    assert_raise ArgumentError, ~r/invalid JSON/, fn -> Ruleset.load!(path) end
    File.write!(path, ~s({"format": 999}))
    assert_raise ArgumentError, ~r/unsupported ruleset format 999/, fn -> Ruleset.load!(path) end
    File.write!(path, ~s({"rules": [{"id": ""}]}))
    assert_raise ArgumentError, ~r/rule id must be a string/, fn -> Ruleset.load!(path) end
    File.rm!(path)
    assert {:error, :enoent} = Ruleset.load(path)
    assert_raise ArgumentError, ~r/cannot load ruleset/, fn -> Ruleset.load!(path) end
  end

  test "saving to a nonexistent parent returns a filesystem error" do
    parent =
      Path.join(System.tmp_dir!(), "rule_match_missing_#{System.unique_integer([:positive])}")

    assert {:error, :enoent} = Ruleset.save(Ruleset.new(), Path.join(parent, "rules.json"))
  end

  test "error formatting includes validation JSON version and filesystem reasons" do
    assert Ruleset.format_error({:invalid_ruleset, "bad input"}) == "bad input"
    assert Ruleset.format_error({:unsupported_format, 2}) == "unsupported ruleset format 2"

    assert Ruleset.format_error({:invalid_json, :unexpected_end}) ==
             "invalid JSON: :unexpected_end"

    assert Ruleset.format_error(:enoent) == "no such file or directory"
    assert Ruleset.format_error({:other, 1}) == "{:other, 1}"
  end
end
