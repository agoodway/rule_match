defmodule RuleMatch.ConditionTest do
  use ExUnit.Case, async: true
  alias RuleMatch.{Condition, Roster}

  for {op, expected, positive, negative} <- [
        {:eq, "acme", " ACME ", "other"},
        {:neq, "acme", "other", "ACME"},
        {:in, ["acme", "other"], " ACME ", "absent"},
        {:not_in, ["acme"], "other", "ACME"},
        {:contains, "cme", "ACME", "other"},
        {:matches, "^acme$", "ACME", "other"},
        {:gt, 10, 11, 10},
        {:gte, 10, 10, 9},
        {:lt, 10, 9, 10},
        {:lte, 10, 10, 11}
      ] do
    test "#{op} accepts a match and rejects a non-match or blank value" do
      condition = {unquote(op), :value, unquote(Macro.escape(expected))}
      assert Condition.match?(condition, %{value: unquote(positive)})
      refute Condition.match?(condition, %{value: unquote(negative)})

      for candidate <- [%{}, %{value: nil}, %{value: ""}] do
        refute Condition.match?(condition, candidate)
        assert %{passed: false, actual: :missing} = Condition.explain(condition, candidate)
      end
    end
  end

  test "case-sensitive equality and membership preserve case and whitespace" do
    for condition <- [{:eq, :value, "Acme"}, {:in, :value, ["Acme"]}] do
      assert Condition.match?(condition, %{value: "Acme"}, %{case_sensitive: true})
      refute Condition.match?(condition, %{value: "acme"}, %{case_sensitive: true})
      refute Condition.match?(condition, %{value: " Acme "}, %{case_sensitive: true})
    end

    refute Condition.match?({:contains, :value, "Acme"}, %{value: "ACME"}, %{case_sensitive: true})
  end

  test "empty membership lists have opposite results for present values" do
    refute Condition.match?({:in, :value, []}, %{value: false})
    assert Condition.match?({:not_in, :value, []}, %{value: false})
  end

  test "blank and present distinguish nil and empty strings from false and whitespace" do
    for value <- [nil, ""] do
      assert Condition.match?({:blank, :value}, %{value: value})
      refute Condition.match?({:present, :value}, %{value: value})
    end

    for value <- [false, 0, " ", [], %{}] do
      refute Condition.match?({:blank, :value}, %{value: value})
      assert Condition.match?({:present, :value}, %{value: value})
    end
  end

  test "field lookup honors the requested key including false and nil" do
    candidate = %{:value => false, "value" => true}
    assert Condition.match?({:eq, :value, false}, candidate)
    assert Condition.match?({:eq, "value", true}, candidate)
    assert Condition.match?({:eq, "value", false}, %{value: false})
    assert Condition.match?({:blank, :value}, %{:value => nil, "value" => true})
    unknown = "unknown_field_#{System.unique_integer([:positive])}"
    refute Condition.match?({:eq, unknown, 1}, %{})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "regex source follows context while compiled regex keeps its flags" do
    refute Condition.match?({:matches, :value, "^acme$"}, %{value: "ACME"}, %{
             case_sensitive: true
           })

    refute Condition.match?({:matches, :value, ~r/^acme$/}, %{value: "ACME"})

    assert Condition.match?({:matches, :value, ~r/^acme$/i}, %{value: "ACME"}, %{
             case_sensitive: true
           })

    assert %{passed: false, error: {:bad_regex, _}} =
             Condition.explain({:matches, :value, "["}, %{value: "a"})

    for condition <- [{:matches, :value, ~r/a/}, {:contains, :value, "a"}] do
      refute Condition.match?(condition, %{value: 123})
    end
  end

  test "between includes both endpoints and permits open bounds" do
    for value <- [10, 15, 20],
        do: assert(Condition.match?({:between, :value, 10, 20}, %{value: value}))

    for value <- [9, 21, false, %{}, nil],
        do: refute(Condition.match?({:between, :value, 10, 20}, %{value: value}))

    assert Condition.match?({:between, :value, nil, 20}, %{value: -100})
    assert Condition.match?({:between, :value, 10, nil}, %{value: 100})
    assert Condition.match?({:between, :value, nil, nil}, %{value: 1})
    refute Condition.match?({:between, :value, 10, 20}, %{})
  end

  test "date comparisons handle equality and boundaries chronologically" do
    for {op, before, equal, after_date} <- [
          {:gt, false, false, true},
          {:gte, false, true, true},
          {:lt, true, false, false},
          {:lte, true, true, false}
        ] do
      for {date, expected} <- [
            {~D[2025-12-31], before},
            {~D[2026-01-01], equal},
            {~D[2026-01-02], after_date}
          ] do
        assert Condition.match?({op, :value, "2026-01-01"}, %{value: date}) == expected
      end
    end

    for date <- [~U[2026-01-01 23:59:59Z], ~N[2026-01-01 12:00:00], " 2026-01-01 "] do
      assert Condition.match?({:between, :value, ~D[2026-01-01], ~D[2026-01-01]}, %{value: date})
    end

    assert Condition.match?({:eq, :value, ~D[2026-01-01]}, %{value: "2026-01-01"})
    assert Condition.match?({:eq, :value, "2026-01-01"}, %{value: ~D[2026-01-01]})
    refute Condition.match?({:gte, :value, 0}, %{value: false})
  end

  test "compound conditions expose nested passing and failing explanations" do
    yes = {:eq, :value, 1}
    no = {:eq, :value, 2}

    for {condition, expected} <- [
          {{:all, [yes, no]}, false},
          {{:any, [yes, no]}, true},
          {{:none, [no]}, true},
          {{:none, [yes, no]}, false},
          {{:not, yes}, false},
          {{:not, no}, true},
          {{:all, []}, true},
          {{:any, []}, false},
          {{:none, []}, true}
        ] do
      assert Condition.match?(condition, %{value: 1}) == expected
    end

    assert %{passed: false, children: [%{passed: true}, %{passed: false, child: %{passed: true}}]} =
             Condition.explain({:all, [yes, {:not, yes}]}, %{value: 1})
  end

  test "specificity sums conjunctions and uses the strongest disjunction branch" do
    leaf = {:eq, :value, 1}
    assert Condition.specificity({:all, [leaf, {:none, [leaf, leaf]}]}) == 3
    assert Condition.specificity({:any, [leaf, {:all, [leaf, leaf]}]}) == 2
    assert Condition.specificity({:not, {:all, [leaf, leaf]}}) == 2
    assert Condition.specificity({:all, []}) == 0
    assert Condition.specificity({:any, []}) == 1
  end

  test "predicates receive candidate and arguments and require boolean true" do
    for result <- [true, false, nil, :truthy, 1] do
      context = %{
        predicates: %{
          "custom" => fn candidate, args ->
            assert candidate == %{value: 7}
            assert args == [3]
            result
          end
        }
      }

      assert Condition.match?({:pred, :custom, [3]}, %{value: 7}, context) == (result == true)
    end

    assert %{error: {:unknown_predicate, :missing}, passed: false} =
             Condition.explain({:pred, :missing, []}, %{})

    refute Condition.match?({:pred, :wrong_arity, []}, %{}, %{
             predicates: %{"wrong_arity" => fn -> true end}
           })
  end

  test "unsupported conditions fail with diagnostic errors" do
    for condition <- [
          :invalid,
          {:invalid, :value},
          {:invalid, :value, 1},
          {:invalid, :value, 1, 2},
          {}
        ] do
      refute Condition.match?(condition, %{})

      assert %{passed: false, error: {:bad_condition, ^condition}} =
               Condition.explain(condition, %{})
    end
  end

  test "roster conditions support field mappings literal products and wildcards" do
    book = Roster.put(Roster.new(), :network, "provider", :any, effective_on: ~D[2026-01-01])
    context = %{rosters: book}
    candidate = %{npi: "PROVIDER", visit: "2026-01-01", plan: "basic"}

    for product <- [:any, {:literal, "basic"}, :plan] do
      condition = {:roster, :network, [provider: :npi, as_of: :visit, product: product]}

      assert %{passed: true, cell: %{effective_on: ~D[2026-01-01]}} =
               Condition.explain(condition, candidate, context)

      refute Condition.match?(condition, %{candidate | visit: "2025-12-31"}, context)
      refute Condition.match?(condition, Map.delete(candidate, :npi), context)
      refute Condition.match?(condition, Map.delete(candidate, :visit), context)
    end

    exact = %{rosters: Roster.put(Roster.new(), :network, "provider", "basic")}

    refute Condition.match?(
             {:roster, :network, []},
             %{provider_id: "provider", date_of_service: ~D[2026-01-01]},
             exact
           )
  end
end
