defmodule RuleMatch.HypertensionTest do
  use ExUnit.Case, async: true

  alias RuleMatch.Ruleset

  setup do
    ruleset = Ruleset.load!(Path.join(__DIR__, "fixtures/hypertension_rules.json"))
    {:ok, ruleset: ruleset}
  end

  for {systolic, diastolic, age, stage, action} <- [
        {118, 76, nil, "normal", "none"},
        {121, 76, nil, "elevated", "lifestyle"},
        {129, 79, nil, "elevated", "lifestyle"},
        {121, 80, nil, "stage_1", "lifestyle_and_recheck"},
        {135, 78, nil, "stage_1", "lifestyle_and_recheck"},
        {139, 89, nil, "stage_1", "lifestyle_and_recheck"},
        {140, 79, nil, "stage_2", "treat"},
        {138, 90, nil, "stage_2", "treat"},
        {181, 95, nil, "crisis", "refer_now"},
        {150, 121, nil, "crisis", "refer_now"},
        {180, 120, nil, "crisis", "refer_now"},
        {119, 79, 90, "normal", "none"}
      ] do
    test "#{systolic}/#{diastolic}, age #{inspect(age)}, selects #{stage}", %{ruleset: ruleset} do
      candidate = %{systolic: unquote(systolic), diastolic: unquote(diastolic)}
      candidate = if unquote(age), do: Map.put(candidate, :age, unquote(age)), else: candidate

      assert_decision(ruleset, candidate, unquote(stage), unquote(action))
    end
  end

  test "crisis retains stage 2 as an alternative and excludes normal", %{ruleset: ruleset} do
    assert {:ok, decision} = RuleMatch.decide(ruleset, %{systolic: 181, diastolic: 95})
    assert decision.rule_id == "crisis"
    assert decision.priority == 50

    alternative_ids = Enum.map(decision.alternatives, & &1.rule_id)
    assert "stage_2" in alternative_ids
    refute "normal" in alternative_ids
  end

  test "121/80 explains the failing elevated diastolic bound and passing stage 1 band", %{
    ruleset: ruleset
  } do
    candidate = %{systolic: 121, diastolic: 80}
    elevated = Enum.find(ruleset.rules, &(&1.id == "elevated"))
    stage_1 = Enum.find(ruleset.rules, &(&1.id == "stage_1"))

    assert [
             %{
               op: :all,
               passed: false,
               children: [
                 %{op: :between, field: "systolic", passed: true},
                 %{op: :lt, field: "diastolic", expected: 80, actual: 80, passed: false}
               ]
             }
           ] = RuleMatch.explain(elevated, candidate, [])

    assert [
             %{
               op: :any,
               passed: true,
               children: [
                 %{op: :between, field: "systolic", passed: false},
                 %{
                   op: :between,
                   field: "diastolic",
                   from: 80,
                   to: 89,
                   actual: 80,
                   passed: true
                 }
               ]
             }
           ] = RuleMatch.explain(stage_1, candidate, [])
  end

  test "missing diastolic fails required bounds but permits a passing systolic OR branch", %{
    ruleset: ruleset
  } do
    # Below the systolic stage 1 band, missing diastolic cannot satisfy any rule.
    for systolic <- [119, 121, 129] do
      candidate = %{systolic: systolic}
      assert RuleMatch.match(ruleset, candidate) == {:ok, []}
      assert RuleMatch.decide(ruleset, candidate) == :nomatch
    end

    assert_decision(ruleset, %{systolic: 135}, "stage_1", "lifestyle_and_recheck")
    assert_decision(ruleset, %{systolic: 185}, "crisis", "refer_now")
  end

  test "an empty candidate returns the existing no-match shape", %{ruleset: ruleset} do
    assert RuleMatch.decide(ruleset, %{}) == :nomatch
  end

  test "age is a wildcard across all five bands", %{ruleset: ruleset} do
    for {systolic, diastolic, stage, action} <- [
          {118, 76, "normal", "none"},
          {121, 76, "elevated", "lifestyle"},
          {135, 78, "stage_1", "lifestyle_and_recheck"},
          {140, 79, "stage_2", "treat"},
          {181, 95, "crisis", "refer_now"}
        ],
        age <- [5, 18, 90] do
      assert_decision(
        ruleset,
        %{systolic: systolic, diastolic: diastolic, age: age},
        stage,
        action
      )
    end
  end

  test "JSON and the same five code-built rules select the same crisis rule", %{ruleset: ruleset} do
    code_ruleset =
      Ruleset.new(
        name: "hypertension",
        version: "2017-aha",
        rules: [
          RuleMatch.rule("crisis",
            priority: 50,
            conditions: [{:any, [{:gte, :systolic, 180}, {:gte, :diastolic, 120}]}],
            outcome: %{stage: "crisis", action: "refer_now"}
          ),
          RuleMatch.rule("stage_2",
            priority: 40,
            conditions: [{:any, [{:gte, :systolic, 140}, {:gte, :diastolic, 90}]}],
            outcome: %{stage: "stage_2", action: "treat"}
          ),
          RuleMatch.rule("stage_1",
            priority: 30,
            conditions: [
              {:any, [{:between, :systolic, 130, 139}, {:between, :diastolic, 80, 89}]}
            ],
            outcome: %{stage: "stage_1", action: "lifestyle_and_recheck"}
          ),
          RuleMatch.rule("elevated",
            priority: 20,
            conditions: [{:all, [{:between, :systolic, 120, 129}, {:lt, :diastolic, 80}]}],
            outcome: %{stage: "elevated", action: "lifestyle"}
          ),
          RuleMatch.rule("normal",
            priority: 10,
            conditions: [{:all, [{:lt, :systolic, 120}, {:lt, :diastolic, 80}]}],
            outcome: %{stage: "normal", action: "none"}
          )
        ]
      )

    candidate = %{systolic: 181, diastolic: 95}
    assert {:ok, json_decision} = RuleMatch.decide(ruleset, candidate)
    assert {:ok, code_decision} = RuleMatch.decide(code_ruleset, candidate)
    assert json_decision.rule_id == "crisis"
    assert json_decision.rule_id == code_decision.rule_id
  end

  test "Cleveland rows follow systolic bands with synthetic diastolic 70", %{ruleset: ruleset} do
    # UCI Heart Disease, Cleveland: Janosi, Steinbrunn, Pfisterer & Detrano (1989).
    # https://doi.org/10.24432/C52P4X — CC BY 4.0
    # https://creativecommons.org/licenses/by/4.0/
    # Source: https://archive.ics.uci.edu/ml/machine-learning-databases/heart-disease/processed.cleveland.data
    # Projection preserves source order and values, retaining only age and trestbps.
    # Diastolic is absent from the source; 70 is supplied solely for this matcher test.
    [header | rows] =
      Path.join(__DIR__, "fixtures/cleveland.csv")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert header == "age,trestbps"
    assert length(rows) == 303

    checked_rows =
      for row <- rows,
          [age, trestbps] = String.split(row, ","),
          {systolic, ""} <- [Float.parse(trestbps)] do
        {age, ""} = Float.parse(age)

        {stage, action} =
          cond do
            systolic >= 180 -> {"crisis", "refer_now"}
            systolic >= 140 -> {"stage_2", "treat"}
            systolic >= 130 -> {"stage_1", "lifestyle_and_recheck"}
            systolic >= 120 -> {"elevated", "lifestyle"}
            true -> {"normal", "none"}
          end

        assert_decision(ruleset, %{systolic: systolic, diastolic: 70, age: age}, stage, action)
        stage
      end

    assert checked_rows != []

    assert Enum.sort(Enum.uniq(checked_rows)) ==
             ["crisis", "elevated", "normal", "stage_1", "stage_2"]
  end

  defp assert_decision(ruleset, candidate, stage, action) do
    assert {:ok, decision} = RuleMatch.decide(ruleset, candidate)
    assert decision.stage == stage, "unexpected stage for #{inspect(candidate)}"
    assert decision.action == action, "unexpected action for #{inspect(candidate)}"
    assert decision.rule_id == stage, "unexpected rule for #{inspect(candidate)}"
  end
end
