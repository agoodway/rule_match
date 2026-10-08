defmodule RuleMatch do
  @moduledoc """
  A rules engine that looks for a match in a set of candidates.

  This is a matcher, not a Rete network or a forward-chaining interpreter.
  A candidate is a map. A rule is a named list of conditions plus an outcome.
  Fields a rule does not mention are wildcards.

  Two directions:

    * `match/3` — given a subject, which rules match, ranked.
    * `select/3` — given a set of candidates, which of them match the rules.

  Ranking is `{priority, specificity}` descending. Specificity is the number
  of leaf constraints, so a provider-and-product-and-date rule beats a
  payer-only rule at the same priority.

  Rules are data. A `RuleMatch.Ruleset` is loaded through an adapter and
  carries the rules, the rosters they reference, and the candidate
  normalization. Every function that takes rules also takes a ruleset; a
  ruleset's rosters join the context and its normalization is applied to
  each candidate first.

      ruleset = RuleMatch.Ruleset.load!("rules.json")
      RuleMatch.decide(ruleset, %{payer: "acme", date_of_service: "2026-07-03"})

  The engine has no domain knowledge and ships no rules.

  The default loader is `RuleMatch.Adapters.File`; configure
  `adapter: RuleMatch.Adapters.Ecto`, an application `repo:`, and a `prefix:`
  to load database keys instead. Both adapters read on every call. A loaded
  ruleset is a snapshot; reload to observe changes. Database writes belong
  to `RuleMatch.Store`, while `RuleMatch.Ruleset.save/2` exports a JSON file.
  """

  alias RuleMatch.{Condition, Match, Rule, Ruleset}

  @type rules :: Ruleset.t() | [Rule.t()]

  @type context :: map()

  @doc """
  Load a ruleset through the configured adapter, raising on expected errors.

  Without an identifier, uses `config :rule_match, :ruleset, identifier`.
  The default adapter reads a JSON file on every call. Pass `adapter: Module`
  or configure `:rule_match, :adapter` to use another loader. Per-call options
  override application configuration.

  `RuleMatch.Adapters.Ecto` interprets identifiers as exact, case-sensitive
  database keys and requires an application Repo. Its default prefix is
  `"rule_match"`; `repo:` and `prefix:` can also be overridden per call.

  Raises `ArgumentError` if configuration or loading fails. Unexpected
  adapter exceptions propagate. Use `RuleMatch.Ruleset.load/2` for error tuples.
  """
  @spec ruleset() :: Ruleset.t()
  def ruleset do
    case Application.get_env(:rule_match, :ruleset) do
      nil ->
        raise ArgumentError,
              "no ruleset configured; set `config :rule_match, :ruleset, identifier` " <>
                "or pass an identifier to RuleMatch.ruleset/1"

      identifier ->
        ruleset(identifier)
    end
  end

  @spec ruleset(String.t(), keyword()) :: Ruleset.t()
  def ruleset(identifier, opts \\ []), do: Ruleset.load!(identifier, opts)

  @doc """
  Validate rules and return them with specificity precomputed in `:meta`.

  Accepts `%RuleMatch.Rule{}` or keyword / map attrs.
  """
  @spec compile([Rule.t() | keyword() | map()]) :: [Rule.t()]
  def compile(rules) when is_list(rules) do
    Enum.map(rules, fn
      %Rule{} = rule ->
        put_specificity(rule)

      attrs ->
        attrs |> Rule.new() |> put_specificity()
    end)
  end

  @doc """
  Rules that match `candidate`, highest priority then highest specificity first.

  Returns `{:ok, matches}`. An empty list is a valid result, not an error.
  Unknown predicates surface as failed conditions with `:error` on the
  explanation; they do not match.
  """
  @spec match(rules(), map(), keyword()) :: {:ok, [Match.t()]}
  def match(rules, candidate, opts \\ [])

  def match(%Ruleset{} = ruleset, candidate, opts) when is_map(candidate) do
    match(ruleset.rules, Ruleset.normalize(ruleset, candidate), ruleset_opts(ruleset, opts))
  end

  def match(rules, candidate, opts) when is_list(rules) and is_map(candidate) do
    context = context(opts)

    matches =
      rules
      |> Enum.filter(&rule_matches?(&1, candidate, context))
      |> Enum.map(&to_match(&1, candidate, context))
      |> Enum.sort_by(& &1.score, :desc)

    {:ok, matches}
  end

  @doc """
  The winning rule, or `:nomatch`.

  On a score tie the first rule in input order wins. `compile/1` does not
  reorder rules.
  """
  @spec best(rules(), map(), keyword()) :: {:ok, Match.t()} | :nomatch
  def best(rules, candidate, opts \\ []) do
    case match(rules, candidate, opts) do
      {:ok, [winner | _]} -> {:ok, winner}
      {:ok, []} -> :nomatch
    end
  end

  @doc """
  The winning outcome for one candidate, or `:nomatch`.

  The outcome map gains `:rule_id`, `:explanation`, `:priority`,
  `:specificity`, and `:alternatives` (every other rule that also matched,
  so a reviewer can see a near-miss).
  """
  @spec decide(rules(), map(), keyword()) :: {:ok, map()} | :nomatch
  def decide(rules, candidate, opts \\ []) do
    case match(rules, candidate, opts) do
      {:ok, [winner | rest]} ->
        alternatives =
          Enum.map(rest, fn match ->
            %{rule_id: match.rule.id, priority: match.priority, outcome: match.outcome}
          end)

        {:ok,
         winner.outcome
         |> Map.put(:explanation, winner.explanation)
         |> Map.put(:priority, winner.priority)
         |> Map.put(:specificity, winner.specificity)
         |> Map.put(:alternatives, alternatives)}

      {:ok, []} ->
        :nomatch
    end
  end

  @doc "Per-condition explanation for one rule, whether or not it matched."
  @spec explain(Rule.t(), map(), keyword()) :: [map()]
  def explain(%Rule{conditions: conditions}, candidate, opts \\ []) do
    context = context(opts)
    Enum.map(conditions, &Condition.explain(&1, candidate, context))
  end

  @doc """
  Candidates that match at least one rule.

  Each returned entry is `%{candidate: map, match: Match.t}`. Pass
  `strategy: :all` to attach every matching rule instead of only the best.
  """
  @spec select(rules(), [map()], keyword()) :: [map()]
  def select(rules, candidates, opts \\ []) when is_list(candidates) do
    strategy = Keyword.get(opts, :strategy, :best)

    # With a ruleset, `match/3` normalizes each candidate; the original is returned.
    candidates
    |> Enum.map(fn candidate ->
      {:ok, matches} = match(rules, candidate, opts)
      {candidate, matches}
    end)
    |> Enum.flat_map(fn
      {_candidate, []} ->
        []

      {candidate, matches} ->
        payload =
          case strategy do
            :all -> %{candidate: candidate, matches: matches, match: hd(matches)}
            _ -> %{candidate: candidate, match: hd(matches)}
          end

        [payload]
    end)
  end

  @doc "Shorthand for `Rule.new/1`."
  @spec rule(String.t(), keyword()) :: Rule.t()
  def rule(id, attrs \\ []) do
    attrs
    |> Keyword.put(:id, id)
    |> Rule.new()
  end

  defp rule_matches?(%Rule{conditions: conditions}, candidate, context) do
    Enum.all?(conditions, &Condition.match?(&1, candidate, context))
  end

  defp to_match(%Rule{} = rule, candidate, context) do
    specificity = specificity(rule)

    %Match{
      rule: rule,
      priority: rule.priority,
      specificity: specificity,
      score: {rule.priority, specificity},
      outcome: Map.put(rule.outcome, :rule_id, rule.id),
      explanation: Enum.map(rule.conditions, &Condition.explain(&1, candidate, context))
    }
  end

  defp specificity(%Rule{meta: %{specificity: n}}) when is_integer(n), do: n

  defp specificity(%Rule{conditions: conditions}),
    do: Enum.sum(Enum.map(conditions, &Condition.specificity/1))

  defp put_specificity(%Rule{conditions: conditions} = rule) do
    n = Enum.sum(Enum.map(conditions, &Condition.specificity/1))
    %{rule | meta: Map.put(rule.meta, :specificity, n)}
  end

  # Ruleset rosters first, so a caller's `:rosters` can override one by name.
  defp ruleset_opts(%Ruleset{rosters: rosters}, opts) do
    Keyword.update(opts, :rosters, rosters, &Map.merge(rosters, &1))
  end

  defp context(opts) do
    predicates =
      Map.new(Keyword.get(opts, :predicates, %{}), fn {name, fun} -> {to_string(name), fun} end)

    %{
      predicates: predicates,
      rosters: Keyword.get(opts, :rosters, %{}),
      case_sensitive: Keyword.get(opts, :case_sensitive, false)
    }
  end
end
