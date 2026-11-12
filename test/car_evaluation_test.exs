defmodule RuleMatch.CarEvaluationTest do
  use ExUnit.Case, async: true

  alias RuleMatch.Ruleset

  # UCI Car Evaluation: Bohanec (1988). https://doi.org/10.24432/C5JP48 — CC BY 4.0
  # https://creativecommons.org/licenses/by/4.0/
  # Source: https://archive.ics.uci.edu/dataset/19/car+evaluation
  # car.csv is car.data unchanged, with a header line added.
  # car.c45-names is the archive's schema file, unchanged.

  @rules_path Path.join(__DIR__, "fixtures/car_rules.json")
  @csv_path Path.join(__DIR__, "fixtures/car.csv")
  @names_path Path.join(__DIR__, "fixtures/car.c45-names")

  # SHA-256 of car.data and car.c45-names as downloaded from the source archive.
  @car_data_sha256 "b703a9ac69f11e64ce8c223c0a40de4d2e9d769f7fb20be5f8f2e8a619893d83"
  @car_names_sha256 "cc75bb7e71f94a6436a3d2b72575c5917b08b18f6792395a6045770086a3e8fb"

  # Priority swaps that cannot change any decision, so no row can catch them.
  # The test proves each reason: :same_class means both rules give the same
  # class; :disjoint means no row matches both rules.
  @equivalent_swaps %{
    {"unacc_low_safety", "unacc_two_persons"} => :same_class,
    {"unacc_low_safety", "unacc_price"} => :same_class,
    {"unacc_low_safety", "unacc_cramped"} => :same_class,
    {"unacc_two_persons", "unacc_price"} => :same_class,
    {"unacc_two_persons", "unacc_cramped"} => :same_class,
    {"unacc_price", "unacc_cramped"} => :same_class,
    {"unacc_price", "unacc_middling"} => :same_class,
    {"unacc_price", "vgood"} => :disjoint,
    {"unacc_cramped", "vgood"} => :disjoint,
    {"good", "unacc_middling"} => :disjoint
  }

  setup_all do
    {classes, domains} = parse_names(File.read!(@names_path))
    [header, body] = String.split(File.read!(@csv_path), "\n", parts: 2)
    fields = Enum.map(domains, &elem(&1, 0))

    rows =
      for line <- String.split(body, "\n", trim: true) do
        values = String.split(line, ",")
        assert length(values) == length(fields) + 1, "malformed row: #{inspect(line)}"
        {candidate, [label]} = Enum.split(values, length(fields))
        {Map.new(Enum.zip(fields, candidate)), label}
      end

    {:ok,
     ruleset: Ruleset.load!(@rules_path),
     classes: classes,
     domains: domains,
     fields: fields,
     header: header,
     body: body,
     rows: rows}
  end

  describe "fixture" do
    test "is the source data byte for byte", %{body: body} do
      assert sha256(body) == @car_data_sha256
      assert sha256(File.read!(@names_path)) == @car_names_sha256
    end

    test "header names the source schema's attributes in order", %{header: header, fields: fields} do
      assert fields == ~w(buying maint doors persons lug_boot safety)
      assert header == Enum.join(fields ++ ["class"], ",")
    end

    test "each column holds exactly its declared values", %{rows: rows, domains: domains} do
      for {field, values} <- domains do
        assert rows |> Enum.map(fn {c, _} -> c[field] end) |> Enum.uniq() |> Enum.sort() ==
                 Enum.sort(values),
               "column #{field} does not match its declared values"
      end
    end

    test "holds every attribute combination exactly once", %{rows: rows, domains: domains} do
      every =
        Enum.reduce(domains, [%{}], fn {field, values}, acc ->
          for partial <- acc, value <- values, do: Map.put(partial, field, value)
        end)

      assert length(rows) == length(every)
      assert MapSet.new(rows, &elem(&1, 0)) == MapSet.new(every)
    end

    test "labels use only declared classes, with the published counts", %{
      rows: rows,
      classes: classes
    } do
      counts = rows |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
      assert Map.keys(counts) |> Enum.sort() == Enum.sort(classes)
      assert counts == %{"unacc" => 1210, "acc" => 384, "good" => 69, "vgood" => 65}
    end
  end

  describe "ruleset" do
    test "every row's decision agrees with its class", %{ruleset: ruleset, rows: rows} do
      disagreements = disagreements(ruleset, rows)

      assert disagreements == [],
             "#{length(disagreements)} of #{length(rows)} rows disagree, first: " <>
               inspect(Enum.take(disagreements, 5))
    end

    test "every rule decides at least one row", %{ruleset: ruleset, rows: rows} do
      winners =
        for {candidate, _label} <- rows, into: MapSet.new() do
          {:ok, decision} = RuleMatch.decide(ruleset, candidate)
          decision.rule_id
        end

      assert winners == MapSet.new(ruleset.rules, & &1.id)
    end

    test "conditions name only declared fields and values", %{domains: domains} do
      domains = Map.new(domains)

      for rule <- rules_map()["rules"], leaf <- leaves(rule["conditions"]) do
        values = Map.fetch!(domains, leaf["field"])
        used = leaf["values"] || [leaf["value"]]
        assert used -- values == [], "#{rule["id"]} uses unknown value in #{inspect(leaf)}"
      end
    end
  end

  describe "agreement check" do
    test "rejects the declared classes when the decisions are wrong", %{rows: rows} do
      # A harness that compares nothing would pass these too.
      for class <- ~w(unacc acc good vgood) do
        constant = RuleMatch.rule("constant", outcome: %{class: class})
        refute disagreements([constant], rows) == []
      end

      assert length(disagreements([], rows)) == length(rows)
    end

    @tag timeout: 300_000
    test "catches every single change to the ruleset", %{rows: rows, domains: domains} do
      mutants = mutants(rules_map(), Map.new(domains))
      assert length(mutants) == length(Enum.uniq_by(mutants, &elem(&1, 0)))

      survivors =
        for {name, mutant} <- mutants,
            {:ok, ruleset} = Ruleset.from_map(mutant),
            disagreements(ruleset, rows) == [],
            into: MapSet.new(),
            do: name

      expected = MapSet.new(Map.keys(@equivalent_swaps), &swap_name/1)

      assert survivors == expected,
             "undetected but not listed:\n" <>
               Enum.join(Enum.sort(MapSet.difference(survivors, expected)), "\n") <>
               "\nlisted but now detected:\n" <>
               Enum.join(Enum.sort(MapSet.difference(expected, survivors)), "\n")
    end

    test "each listed swap is harmless for its stated reason", %{ruleset: ruleset, rows: rows} do
      classes = Map.new(ruleset.rules, &{&1.id, to_string(&1.outcome.class)})

      for {{a, b} = pair, reason} <- @equivalent_swaps do
        case reason do
          :same_class ->
            assert classes[a] == classes[b], "#{inspect(pair)} give different classes"

          :disjoint ->
            both =
              for {candidate, _} <- rows,
                  {:ok, matches} = RuleMatch.match(ruleset, candidate),
                  ids = Enum.map(matches, & &1.rule.id),
                  a in ids and b in ids,
                  do: candidate

            assert both == [], "#{inspect(pair)} both match #{length(both)} rows"
        end
      end
    end
  end

  # -- mutants --------------------------------------------------------------

  defp mutants(map, domains) do
    rules = map["rules"]
    indexed = Enum.with_index(rules)
    put = fn rules -> %{map | "rules" => rules} end

    removals =
      for {rule, i} <- indexed, do: {"remove rule #{rule["id"]}", put.(List.delete_at(rules, i))}

    swaps =
      for {a, i} <- indexed, {b, j} <- indexed, i < j do
        swapped =
          rules
          |> List.replace_at(i, %{a | "priority" => b["priority"]})
          |> List.replace_at(j, %{b | "priority" => a["priority"]})

        {swap_name({a["id"], b["id"]}), put.(swapped)}
      end

    outcomes =
      for {rule, i} <- indexed,
          class <- ~w(unacc acc good vgood) -- [rule["outcome"]["class"]] do
        {"#{rule["id"]}: outcome #{class}",
         put.(List.replace_at(rules, i, put_in(rule, ["outcome", "class"], class)))}
      end

    conditions =
      for {rule, i} <- indexed,
          {name, conditions} <- list_mutants(rule["conditions"], "conditions", domains) do
        {"#{rule["id"]}: #{name}",
         put.(List.replace_at(rules, i, %{rule | "conditions" => conditions}))}
      end

    removals ++ swaps ++ outcomes ++ conditions
  end

  defp list_mutants(list, path, domains) do
    indexed = Enum.with_index(list)

    drops = for {_node, i} <- indexed, do: {"drop #{path}[#{i}]", List.delete_at(list, i)}

    changes =
      for {node, i} <- indexed,
          {name, changed} <- node_mutants(node, "#{path}[#{i}]", domains),
          do: {name, List.replace_at(list, i, changed)}

    drops ++ changes
  end

  defp node_mutants(%{"op" => op, "conditions" => children} = node, path, domains)
       when op in ~w(all any none) do
    ops =
      for other <- ~w(all any none) -- [op],
          do: {"#{path} #{op} -> #{other}", %{node | "op" => other}}

    nested =
      for {name, changed} <- list_mutants(children, "#{path}.conditions", domains),
          do: {name, %{node | "conditions" => changed}}

    [negate(node, path) | ops] ++ nested
  end

  defp node_mutants(%{"op" => "eq", "field" => field, "value" => value} = node, path, domains) do
    values =
      for other <- Map.fetch!(domains, field) -- [value],
          do: {"#{path} #{field} #{value} -> #{other}", %{node | "value" => other}}

    [negate(node, path) | values] ++ field_swaps(node, path, domains)
  end

  defp node_mutants(%{"op" => "in", "field" => field, "values" => values} = node, path, domains) do
    removed =
      for v <- values, do: {"#{path} #{field} without #{v}", %{node | "values" => values -- [v]}}

    added =
      for v <- Map.fetch!(domains, field) -- values,
          do: {"#{path} #{field} with #{v}", %{node | "values" => values ++ [v]}}

    [negate(node, path) | removed] ++ added ++ field_swaps(node, path, domains)
  end

  defp swap_name({a, b}), do: "swap priority #{a} <> #{b}"

  defp negate(node, path), do: {"#{path} negated", %{"op" => "not", "condition" => node}}

  # Pointing a condition at another column with the same values catches a
  # ruleset that confuses two columns, such as buying and maint.
  defp field_swaps(%{"field" => field} = node, path, domains) do
    for {other, values} <- domains,
        other != field,
        values == domains[field],
        do: {"#{path} field #{field} -> #{other}", %{node | "field" => other}}
  end

  # -- helpers --------------------------------------------------------------

  defp disagreements(rules, rows) do
    for {candidate, label} <- rows,
        decided = decided_class(rules, candidate),
        decided != label,
        do: {candidate, label, decided}
  end

  defp decided_class(rules, candidate) do
    case RuleMatch.decide(rules, candidate) do
      {:ok, decision} -> to_string(decision.class)
      :nomatch -> :nomatch
    end
  end

  defp leaves(conditions) do
    Enum.flat_map(conditions, fn
      %{"conditions" => children} -> leaves(children)
      %{"condition" => child} -> leaves([child])
      leaf -> [leaf]
    end)
  end

  defp rules_map, do: @rules_path |> File.read!() |> JSON.decode!()

  # Reads the C4.5 names file: "| comment" lines, one class line, then
  # "attribute: value, value." lines.
  defp parse_names(text) do
    [classes | attributes] =
      text
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "|"))

    domains =
      for line <- attributes do
        [field, values] = String.split(line, ":", parts: 2)
        {String.trim(field), split_values(values)}
      end

    {split_values(classes), domains}
  end

  defp split_values(text) do
    text
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
