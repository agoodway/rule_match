defmodule RuleMatch.Codec do
  @moduledoc """
  Conversion between rules, conditions, and rosters and their JSON-ready
  map form (string keys, JSON scalars only).

  Conditions are tagged objects keyed by `"op"`:

      {"op": "eq", "field": "organization", "value": "acme"}
      {"op": "in", "field": "tier", "values": ["starter", "standard"]}
      {"op": "not_in", "field": "segment", "values": ["restricted"]}
      {"op": "neq", "field": "team", "value": "access_b"}
      {"op": "contains", "field": "note", "value": "example text"}
      {"op": "matches", "field": "member_id", "pattern": "^w\\d+$"}
      {"op": "matches", "field": "member_id", "pattern": "^W\\d+$", "flags": ""}
      {"op": "present", "field": "member_id"}
      {"op": "blank", "field": "member_id"}
      {"op": "gte", "field": "as_of", "value": "2000-02-01"}
      {"op": "between", "field": "as_of", "from": "2000-01-01", "to": null}
      {"op": "all", "conditions": [...]}
      {"op": "any", "conditions": [...]}
      {"op": "none", "conditions": [...]}
      {"op": "not", "condition": {...}}
      {"op": "pred", "name": "my_predicate", "args": [...]}
      {"op": "roster", "roster": "access_a", "category_field": "category"}
      {"op": "roster", "roster": "access_b", "category": "*"}

  `gt`, `lt` and `lte` take the same shape as `gte`. A `matches` pattern
  without `"flags"` follows the engine's case setting (case-insensitive by
  default); with `"flags"` (letters from `imsux`, `""` for none) it is
  compiled exactly as given. A roster condition reads
  the member from `"member_field"` (default `"member_id"`) and the date
  from `"as_of_field"` (default `"as_of"`). Its category is either a
  candidate field (`"category_field"`, default `"category"`), a literal
  (`"category": "read"`), or any category (`"category": "*"`).

  Dates are ISO 8601 strings. Decoding never creates atoms from field names,
  ops, or values. Outcome keys are the exception: they become atoms so that
  `result.access_status` works. Load only ruleset files you trust.
  """

  alias RuleMatch.{Roster, Rule}

  @any_category "*"

  # `:ucp` comes along with `u`, so it has no letter of its own.
  @regex_flag_letters %{caseless: "i", unicode: "u", multiline: "m", dotall: "s", extended: "x"}
  @regex_letter_flags Map.new(@regex_flag_letters, fn {flag, letter} -> {letter, flag} end)

  @value_ops ~w(eq neq contains gt gte lt lte)
  @list_ops ~w(in not_in)
  @field_ops ~w(present blank)
  @compound_ops ~w(all any none)

  ## Rules

  @doc "A rule as a JSON-ready map."
  @spec rule_to_map(Rule.t()) :: map()
  def rule_to_map(%Rule{} = rule) do
    meta = Map.delete(rule.meta, :specificity)

    %{
      "id" => rule.id,
      "priority" => rule.priority,
      "conditions" => Enum.map(rule.conditions, &condition_to_map/1),
      "outcome" => to_json_value(rule.outcome)
    }
    |> put_unless("description", rule.description, nil)
    |> put_unless("tags", Enum.map(rule.tags, &to_string/1), [])
    |> put_unless("meta", to_json_value(meta), %{})
  end

  @doc "A rule from its map form. Raises `ArgumentError` on a malformed rule."
  @spec rule_from_map(map()) :: Rule.t()
  def rule_from_map(%{} = map) do
    id = Map.get(map, "id")

    Rule.new(
      id: id,
      description: Map.get(map, "description"),
      priority: integer!(Map.get(map, "priority", 0), "priority of rule #{inspect(id)}"),
      tags: Map.get(map, "tags", []),
      conditions:
        Enum.map(list!(Map.get(map, "conditions", []), "conditions"), &condition_from_map/1),
      outcome: atomize_keys(map!(Map.get(map, "outcome", %{}), "outcome of rule #{inspect(id)}")),
      meta: Map.get(map, "meta", %{})
    )
  end

  def rule_from_map(other),
    do: raise(ArgumentError, "rule must be an object, got: #{inspect(other)}")

  ## Conditions

  @doc "A condition tuple as a JSON-ready map."
  @spec condition_to_map(RuleMatch.Condition.t()) :: map()
  def condition_to_map({op, field, value})
      when op in [:eq, :neq, :contains, :gt, :gte, :lt, :lte] do
    %{"op" => Atom.to_string(op), "field" => to_string(field), "value" => to_json_value(value)}
  end

  def condition_to_map({op, field, values}) when op in [:in, :not_in] do
    %{"op" => Atom.to_string(op), "field" => to_string(field), "values" => to_json_value(values)}
  end

  def condition_to_map({:matches, field, %Regex{} = regex}) do
    flags =
      regex |> Regex.opts() |> Enum.map(&Map.get(@regex_flag_letters, &1, "")) |> Enum.join()

    %{
      "op" => "matches",
      "field" => to_string(field),
      "pattern" => Regex.source(regex),
      "flags" => flags
    }
  end

  def condition_to_map({:matches, field, source}) when is_binary(source) do
    %{"op" => "matches", "field" => to_string(field), "pattern" => source}
  end

  def condition_to_map({op, field}) when op in [:present, :blank] do
    %{"op" => Atom.to_string(op), "field" => to_string(field)}
  end

  def condition_to_map({:between, field, from, to}) do
    %{
      "op" => "between",
      "field" => to_string(field),
      "from" => to_json_value(from),
      "to" => to_json_value(to)
    }
  end

  def condition_to_map({op, conds}) when op in [:all, :any, :none] and is_list(conds) do
    %{"op" => Atom.to_string(op), "conditions" => Enum.map(conds, &condition_to_map/1)}
  end

  def condition_to_map({:not, cond}) do
    %{"op" => "not", "condition" => condition_to_map(cond)}
  end

  def condition_to_map({:pred, name, args}) do
    %{"op" => "pred", "name" => to_string(name), "args" => to_json_value(args)}
  end

  def condition_to_map({:roster, name, opts}) do
    base = %{"op" => "roster", "roster" => to_string(name)}

    base =
      case Keyword.get(opts, :category, :category) do
        :any -> Map.put(base, "category", @any_category)
        {:literal, value} -> Map.put(base, "category", to_json_value(value))
        field -> put_unless(base, "category_field", to_string(field), "category")
      end

    base
    |> put_unless(
      "member_field",
      to_string(Keyword.get(opts, :member, :member_id)),
      "member_id"
    )
    |> put_unless(
      "as_of_field",
      to_string(Keyword.get(opts, :as_of, :as_of)),
      "as_of"
    )
  end

  def condition_to_map(other),
    do: raise(ArgumentError, "cannot encode condition: #{inspect(other)}")

  @doc "A condition tuple from its map form. Raises `ArgumentError` on a malformed condition."
  @spec condition_from_map(map()) :: RuleMatch.Condition.t()
  def condition_from_map(%{"op" => op} = map) when op in @value_ops do
    {op_atom(op), field!(map), required!(map, "value")}
  end

  def condition_from_map(%{"op" => op} = map) when op in @list_ops do
    {op_atom(op), field!(map), list!(required!(map, "values"), "values")}
  end

  def condition_from_map(%{"op" => "matches"} = map) do
    pattern = required!(map, "pattern")
    unless is_binary(pattern), do: raise(ArgumentError, "matches pattern must be a string")

    case Map.fetch(map, "flags") do
      :error -> {:matches, field!(map), pattern}
      {:ok, flags} -> {:matches, field!(map), compile_regex!(pattern, flags)}
    end
  end

  def condition_from_map(%{"op" => op} = map) when op in @field_ops do
    {op_atom(op), field!(map)}
  end

  def condition_from_map(%{"op" => "between"} = map) do
    {:between, field!(map), Map.get(map, "from"), Map.get(map, "to")}
  end

  def condition_from_map(%{"op" => op} = map) when op in @compound_ops do
    conds = list!(required!(map, "conditions"), "conditions")
    {op_atom(op), Enum.map(conds, &condition_from_map/1)}
  end

  def condition_from_map(%{"op" => "not"} = map) do
    {:not, condition_from_map(required!(map, "condition"))}
  end

  def condition_from_map(%{"op" => "pred"} = map) do
    {:pred, string!(required!(map, "name"), "pred name"), Map.get(map, "args")}
  end

  def condition_from_map(%{"op" => "roster"} = map) do
    category =
      case Map.fetch(map, "category") do
        {:ok, @any_category} -> :any
        {:ok, value} -> {:literal, value}
        :error -> string!(Map.get(map, "category_field", "category"), "category_field")
      end

    opts = [
      member: string!(Map.get(map, "member_field", "member_id"), "member_field"),
      category: category,
      as_of: string!(Map.get(map, "as_of_field", "as_of"), "as_of_field")
    ]

    {:roster, string!(required!(map, "roster"), "roster"), opts}
  end

  def condition_from_map(%{"op" => op}),
    do: raise(ArgumentError, "unknown condition op: #{inspect(op)}")

  def condition_from_map(other),
    do: raise(ArgumentError, "condition must be an object with \"op\", got: #{inspect(other)}")

  ## Rosters

  @doc """
  A roster book as a JSON-ready map: roster name to a list of entries.

  Cells for one member that share dates and meta are grouped into one
  entry with a `"categories"` list.
  """
  @spec rosters_to_map(Roster.t()) :: map()
  def rosters_to_map(book) do
    Map.new(book, fn {name, table} ->
      entries =
        table
        |> Enum.group_by(
          fn {{member, _category}, cell} ->
            {member, cell.effective_on, cell.terminates_on, cell.meta}
          end,
          fn {{_member, category}, _cell} -> category end
        )
        |> Enum.map(fn {{member, from, to, meta}, categories} ->
          %{
            "member" => member,
            "categories" => categories |> Enum.map(&category_to_json/1) |> Enum.sort(),
            "effective_on" => to_json_value(from)
          }
          |> put_unless("terminates_on", to_json_value(to), nil)
          |> put_unless("meta", to_json_value(meta), %{})
        end)
        |> Enum.sort_by(&{&1["member"], &1["categories"]})

      {to_string(name), entries}
    end)
  end

  @doc "A roster book from its map form."
  @spec rosters_from_map(map()) :: Roster.t()
  def rosters_from_map(%{} = map) do
    Enum.reduce(map, Roster.new(), fn {name, entries}, book ->
      entries
      |> list!("roster #{inspect(name)}")
      |> Enum.reduce(book, &put_roster_entry(&2, name, &1))
    end)
  end

  def rosters_from_map(other),
    do: raise(ArgumentError, "rosters must be an object, got: #{inspect(other)}")

  defp put_roster_entry(book, name, %{} = entry) do
    member = string!(required!(entry, "member"), "roster member")

    categories =
      case entry do
        %{"categories" => categories} ->
          list!(categories, "categories")

        %{"category" => category} ->
          [category]

        _ ->
          raise ArgumentError,
                "roster entry for #{inspect(member)} needs \"category\" or \"categories\""
      end

    opts = [
      effective_on: date!(Map.get(entry, "effective_on")),
      terminates_on: date!(Map.get(entry, "terminates_on")),
      meta: Map.get(entry, "meta", %{})
    ]

    Enum.reduce(categories, book, fn category, acc ->
      Roster.put(acc, name, member, category_from_json(category), opts)
    end)
  end

  defp put_roster_entry(_book, name, other) do
    raise ArgumentError, "roster #{inspect(name)} entry must be an object, got: #{inspect(other)}"
  end

  defp category_to_json(:any), do: @any_category
  defp category_to_json(category), do: to_json_value(category)

  defp category_from_json(@any_category), do: :any
  defp category_from_json(category), do: category

  ## Values

  @doc "Convert a term to JSON-ready data: dates to ISO strings, atoms to strings, string keys."
  @spec to_json_value(term()) :: term()
  def to_json_value(%Date{} = date), do: Date.to_iso8601(date)
  def to_json_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def to_json_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def to_json_value(%Regex{} = regex), do: Regex.source(regex)
  def to_json_value(%_{} = struct), do: raise(ArgumentError, "cannot encode #{inspect(struct)}")

  def to_json_value(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), to_json_value(v)} end)

  def to_json_value(list) when is_list(list), do: Enum.map(list, &to_json_value/1)
  def to_json_value(value) when is_boolean(value) or is_nil(value), do: value
  def to_json_value(value) when is_atom(value), do: Atom.to_string(value)
  def to_json_value(value), do: value

  @doc """
  Pretty-printed JSON with stable key order.

  Known ruleset keys come first in a fixed order; the rest are alphabetical.
  """
  @spec pretty(term()) :: String.t()
  def pretty(term), do: IO.iodata_to_binary([pretty(term, 0), ?\n])

  @key_order ~w(
    format id name version description normalize downcase dates
    priority tags op field value values pattern from to args roster
    flags category category_field member_field as_of_field condition conditions outcome
    member categories effective_on terminates_on meta rules rosters
  )
  @key_rank @key_order |> Enum.uniq() |> Enum.with_index() |> Map.new()

  @inline_width 100

  defp pretty(%{} = map, _indent) when map_size(map) == 0, do: "{}"

  defp pretty(%{} = map, indent) do
    pairs = Enum.sort_by(map, fn {k, _} -> {Map.get(@key_rank, k, map_size(@key_rank)), k} end)

    # A flat object (a leaf condition, a roster entry) fits on one line.
    inline =
      if Enum.all?(pairs, fn {_k, v} ->
           scalar?(v) or (is_list(v) and Enum.all?(v, &scalar?/1))
         end) do
        line =
          IO.iodata_to_binary([
            "{",
            pairs
            |> Enum.map(fn {k, v} -> [JSON.encode!(k), ": ", JSON.encode!(v)] end)
            |> Enum.intersperse(", "),
            "}"
          ])

        if String.length(line) + indent * 2 <= @inline_width, do: line
      end

    inline || pretty_block(pairs, indent)
  end

  defp pretty([], _indent), do: "[]"

  defp pretty(list, indent) when is_list(list) do
    if Enum.all?(list, &scalar?/1) and length(list) <= 12 do
      ["[", list |> Enum.map(&JSON.encode!/1) |> Enum.intersperse(", "), "]"]
    else
      pad = String.duplicate("  ", indent + 1)
      items = list |> Enum.map(&[pad, pretty(&1, indent + 1)]) |> Enum.intersperse(",\n")
      ["[\n", items, "\n", String.duplicate("  ", indent), "]"]
    end
  end

  defp pretty(value, _indent), do: JSON.encode!(value)

  defp pretty_block(pairs, indent) do
    pad = String.duplicate("  ", indent + 1)

    entries =
      pairs
      |> Enum.map(fn {k, v} -> [pad, JSON.encode!(k), ": ", pretty(v, indent + 1)] end)
      |> Enum.intersperse(",\n")

    ["{\n", entries, "\n", String.duplicate("  ", indent), "}"]
  end

  defp scalar?(value), do: not is_map(value) and not is_list(value)

  ## Helpers

  defp op_atom(op), do: String.to_existing_atom(op)

  defp field!(map), do: string!(required!(map, "field"), "field")

  defp required!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(map["op"])} condition is missing #{inspect(key)}"
    end
  end

  defp string!(value, _what) when is_binary(value) and value != "", do: value

  defp string!(value, what),
    do: raise(ArgumentError, "#{what} must be a non-empty string, got: #{inspect(value)}")

  defp list!(value, _what) when is_list(value), do: value

  defp list!(value, what),
    do: raise(ArgumentError, "#{what} must be a list, got: #{inspect(value)}")

  defp map!(value, _what) when is_map(value), do: value

  defp map!(value, what),
    do: raise(ArgumentError, "#{what} must be an object, got: #{inspect(value)}")

  defp integer!(value, _what) when is_integer(value), do: value

  defp integer!(value, what),
    do: raise(ArgumentError, "#{what} must be an integer, got: #{inspect(value)}")

  defp compile_regex!(pattern, flags) when is_binary(flags) do
    opts =
      flags
      |> String.graphemes()
      |> Enum.map(fn letter ->
        Map.get(@regex_letter_flags, letter) ||
          raise ArgumentError, "unknown regex flag #{inspect(letter)}"
      end)

    case Regex.compile(pattern, opts) do
      {:ok, regex} -> regex
      {:error, reason} -> raise ArgumentError, "bad regex #{inspect(pattern)}: #{inspect(reason)}"
    end
  end

  defp compile_regex!(_pattern, flags),
    do: raise(ArgumentError, "regex flags must be a string, got: #{inspect(flags)}")

  defp date!(nil), do: nil

  defp date!(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> raise ArgumentError, "expected an ISO 8601 date, got: #{inspect(value)}"
    end
  end

  defp date!(value), do: raise(ArgumentError, "expected an ISO 8601 date, got: #{inspect(value)}")

  defp atomize_keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

  defp put_unless(map, _key, value, default) when value == default, do: map
  defp put_unless(map, key, value, _default), do: Map.put(map, key, value)
end
