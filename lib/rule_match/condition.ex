defmodule RuleMatch.Condition do
  @moduledoc """
  Conditions over a candidate map.

  Operators:

    * `{:eq, field, value}` / `{:neq, field, value}`
    * `{:in, field, list}` / `{:not_in, field, list}`
    * `{:contains, field, substring}` — case-insensitive substring
    * `{:matches, field, regex}` — `Regex.t` or a source string
    * `{:present, field}` / `{:blank, field}`
    * `{:gt, field, value}` / `{:gte, field, value}` / `{:lt, field, value}` / `{:lte, field, value}`
    * `{:between, field, from, to}` — `nil` bound is open. Dates and ISO date strings compare as dates.
    * `{:all, [condition]}` / `{:any, [condition]}` / `{:none, [condition]}` / `{:not, condition}`
    * `{:pred, name, args}` — `name` (atom or string) is looked up in the context predicate registry.
      The function is called as `fun.(candidate, args)` and must return a boolean.
    * `{:roster, roster_name, opts}` — category-and-date membership. See `RuleMatch.Roster`.
      `opts` takes `:member` and `:as_of` field names, and `:category`, which is a
      field name, `:any`, or `{:literal, category}`.
      Defaults read `:member_id`, `:as_of`, and `:category` from the candidate.

  Field names may be atoms or strings. Rules decoded from JSON use strings.
  See `RuleMatch.Codec` for the JSON form of every operator.

  A missing field fails every operator that needs a value. Only `:blank`
  succeeds when the field is absent. `false` stored under a present key is a
  real value: lookup uses `Map.has_key?/2`, never `||`.

  String equality, membership, and `contains` are case-insensitive unless the
  context sets `:case_sensitive` to `true`.
  """

  alias RuleMatch.Roster

  @type t :: tuple()

  @doc "Does this condition hold for the candidate?"
  @spec match?(t(), map(), map()) :: boolean()
  def match?(condition, candidate, context \\ %{}) do
    case evaluate(condition, candidate, context) do
      {:ok, true, _} -> true
      _ -> false
    end
  end

  @doc "Explain a condition. Always returns a map with `:passed`."
  @spec explain(t(), map(), map()) :: map()
  def explain(condition, candidate, context \\ %{}) do
    case evaluate(condition, candidate, context) do
      {:ok, passed, detail} ->
        Map.merge(%{op: op_name(condition), passed: passed}, detail)

      {:error, reason} ->
        %{op: op_name(condition), passed: false, error: reason}
    end
  end

  @doc """
  How many leaf constraints a condition contributes.

  Used as the tie-break after priority. `:any` counts as its most specific
  child so a compound market-or-prefix clause is not treated as one weak test.
  """
  @spec specificity(t()) :: non_neg_integer()
  def specificity({:all, conds}), do: sum_specificity(conds)
  def specificity({:none, conds}), do: sum_specificity(conds)
  def specificity({:any, conds}), do: Enum.max([1 | Enum.map(conds, &specificity/1)])
  def specificity({:not, cond}), do: specificity(cond)
  def specificity(_), do: 1

  defp sum_specificity(conds), do: Enum.sum(Enum.map(conds, &specificity/1))

  defp evaluate({:all, conds}, candidate, context) do
    details = Enum.map(conds, &explain(&1, candidate, context))
    {:ok, Enum.all?(details, & &1.passed), %{children: details}}
  end

  defp evaluate({:any, conds}, candidate, context) do
    details = Enum.map(conds, &explain(&1, candidate, context))
    {:ok, Enum.any?(details, & &1.passed), %{children: details}}
  end

  defp evaluate({:none, conds}, candidate, context) do
    details = Enum.map(conds, &explain(&1, candidate, context))
    {:ok, Enum.all?(details, &(not &1.passed)), %{children: details}}
  end

  defp evaluate({:not, cond}, candidate, context) do
    detail = explain(cond, candidate, context)
    {:ok, not detail.passed, %{child: detail}}
  end

  defp evaluate({:blank, field}, candidate, _context) do
    case fetch(candidate, field) do
      :missing -> {:ok, true, %{field: field, actual: :missing}}
      {:ok, value} -> {:ok, blank?(value), %{field: field, actual: value}}
    end
  end

  defp evaluate({:present, field}, candidate, _context) do
    case fetch(candidate, field) do
      :missing -> {:ok, false, %{field: field, actual: :missing}}
      {:ok, value} -> {:ok, not blank?(value), %{field: field, actual: value}}
    end
  end

  defp evaluate({:eq, field, expected}, candidate, context) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: expected, actual: :missing}}

      {:ok, actual} ->
        {:ok, equals?(actual, expected, context),
         %{field: field, expected: expected, actual: actual}}
    end
  end

  defp evaluate({:neq, field, expected}, candidate, context) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: expected, actual: :missing}}

      {:ok, actual} ->
        {:ok, not equals?(actual, expected, context),
         %{field: field, expected: expected, actual: actual}}
    end
  end

  defp evaluate({:in, field, expected}, candidate, context) when is_list(expected) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: expected, actual: :missing}}

      {:ok, actual} ->
        passed = Enum.any?(expected, &equals?(actual, &1, context))
        {:ok, passed, %{field: field, expected: expected, actual: actual}}
    end
  end

  defp evaluate({:not_in, field, expected}, candidate, context) when is_list(expected) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: expected, actual: :missing}}

      {:ok, actual} ->
        passed = not Enum.any?(expected, &equals?(actual, &1, context))
        {:ok, passed, %{field: field, expected: expected, actual: actual}}
    end
  end

  defp evaluate({:contains, field, substring}, candidate, context) when is_binary(substring) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: substring, actual: :missing}}

      {:ok, actual} when is_binary(actual) ->
        {haystack, needle} = fold_pair(actual, substring, context)

        {:ok, String.contains?(haystack, needle),
         %{field: field, expected: substring, actual: actual}}

      {:ok, actual} ->
        {:ok, false, %{field: field, expected: substring, actual: actual}}
    end
  end

  defp evaluate({:matches, field, %Regex{} = regex}, candidate, _context) do
    match_regex(field, regex, candidate)
  end

  defp evaluate({:matches, field, source}, candidate, context) when is_binary(source) do
    opts = if Map.get(context, :case_sensitive, false), do: "", else: "i"

    case Regex.compile(source, opts) do
      {:ok, regex} -> match_regex(field, regex, candidate)
      {:error, reason} -> {:error, {:bad_regex, reason}}
    end
  end

  defp evaluate({:between, field, from, to}, candidate, _context) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, from: from, to: to, actual: :missing}}

      {:ok, actual} ->
        left = coerce_comparable(actual)
        passed = comparable?(left) and bound_ok?(:gte, left, from) and bound_ok?(:lte, left, to)
        {:ok, passed, %{field: field, from: from, to: to, actual: actual}}
    end
  end

  defp evaluate({op, field, expected}, candidate, _context) when op in [:gt, :gte, :lt, :lte] do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, expected: expected, actual: :missing}}

      {:ok, actual} ->
        left = coerce_comparable(actual)
        passed = comparable?(left) and compare(op, left, coerce_comparable(expected))
        {:ok, passed, %{field: field, expected: expected, actual: actual}}
    end
  end

  defp evaluate({:pred, name, args}, candidate, context) do
    preds = Map.get(context, :predicates, %{})

    case Map.get(preds, to_string(name)) do
      fun when is_function(fun, 2) ->
        passed = fun.(candidate, args) == true
        {:ok, passed, %{predicate: name, args: args}}

      _ ->
        {:error, {:unknown_predicate, name}}
    end
  end

  defp evaluate({:roster, name, opts}, candidate, context) do
    rosters = Map.get(context, :rosters, %{})
    member_field = Keyword.get(opts, :member, :member_id)
    category_spec = Keyword.get(opts, :category, :category)
    as_of_field = Keyword.get(opts, :as_of, :as_of)

    with {:ok, member} <- fetch_required(candidate, member_field),
         {:ok, as_of} <- fetch_required(candidate, as_of_field) do
      category = resolve_category(category_spec, candidate)

      case Roster.member(rosters, name, member, category, coerce_comparable(as_of)) do
        {:ok, cell} ->
          {:ok, true, %{roster: name, member: member, category: category, cell: cell}}

        :not_member ->
          {:ok, false, %{roster: name, member: member, category: category, cell: nil}}
      end
    else
      :missing ->
        {:ok, false, %{roster: name, actual: :missing}}
    end
  end

  defp evaluate(other, _candidate, _context), do: {:error, {:bad_condition, other}}

  defp match_regex(field, regex, candidate) do
    case fetch_required(candidate, field) do
      :missing ->
        {:ok, false, %{field: field, actual: :missing}}

      {:ok, actual} when is_binary(actual) ->
        {:ok, Regex.match?(regex, actual), %{field: field, actual: actual}}

      {:ok, actual} ->
        {:ok, false, %{field: field, actual: actual}}
    end
  end

  # `:any` and `{:literal, value}` are categories, not candidate fields.
  defp resolve_category(:any, _candidate), do: :any
  defp resolve_category({:literal, value}, _candidate), do: value

  defp resolve_category(field, candidate) when is_atom(field) or is_binary(field) do
    case fetch(candidate, field) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  # Present key wins, including false and nil. String key is the fallback.
  defp fetch(candidate, field) when is_atom(field) do
    cond do
      Map.has_key?(candidate, field) ->
        {:ok, Map.get(candidate, field)}

      Map.has_key?(candidate, Atom.to_string(field)) ->
        {:ok, Map.get(candidate, Atom.to_string(field))}

      true ->
        :missing
    end
  end

  defp fetch(candidate, field) when is_binary(field) do
    cond do
      Map.has_key?(candidate, field) -> {:ok, Map.get(candidate, field)}
      true -> fetch_atom_key(candidate, field)
    end
  end

  defp fetch_atom_key(candidate, field) do
    atom = String.to_existing_atom(field)
    if Map.has_key?(candidate, atom), do: {:ok, Map.get(candidate, atom)}, else: :missing
  rescue
    ArgumentError -> :missing
  end

  defp fetch_required(candidate, field) do
    case fetch(candidate, field) do
      {:ok, value} -> if blank?(value), do: :missing, else: {:ok, value}
      :missing -> :missing
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp equals?(left, right, context) when is_binary(left) and is_binary(right) do
    if Map.get(context, :case_sensitive, false) do
      left == right
    else
      String.downcase(String.trim(left)) == String.downcase(String.trim(right))
    end
  end

  defp equals?(%Date{} = left, right, _context), do: left == coerce_comparable(right)
  defp equals?(left, %Date{} = right, _context), do: coerce_comparable(left) == right
  defp equals?(left, right, _context), do: left == right

  defp fold_pair(left, right, context) do
    if Map.get(context, :case_sensitive, false) do
      {left, right}
    else
      {String.downcase(left), String.downcase(right)}
    end
  end

  defp bound_ok?(_op, _value, nil), do: true
  defp bound_ok?(op, value, bound), do: compare(op, value, coerce_comparable(bound))

  # Date structs compare by term order under >=, which is not chronological.
  defp compare(op, %Date{} = left, %Date{} = right) do
    case Date.compare(left, right) do
      :gt -> op in [:gt, :gte]
      :eq -> op in [:gte, :lte]
      :lt -> op in [:lt, :lte]
    end
  end

  defp compare(:gt, a, b), do: a > b
  defp compare(:gte, a, b), do: a >= b
  defp compare(:lt, a, b), do: a < b
  defp compare(:lte, a, b), do: a <= b

  defp comparable?(%Date{}), do: true
  defp comparable?(value) when is_number(value), do: true
  defp comparable?(value) when is_binary(value), do: true
  defp comparable?(_), do: false

  defp coerce_comparable(%Date{} = date), do: date
  defp coerce_comparable(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp coerce_comparable(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp coerce_comparable(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp coerce_comparable(value), do: value

  defp op_name({op, _, _}), do: op
  defp op_name({op, _, _, _}), do: op
  defp op_name({op, _}), do: op
  defp op_name(op) when is_atom(op), do: op
  defp op_name(_), do: :unknown
end
