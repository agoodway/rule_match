defmodule RuleMatch.Codec do
  @moduledoc """
  Conversion between rules, conditions, and rosters and their JSON-ready
  map form (string keys, JSON scalars only).

  Conditions are tagged objects keyed by `"op"`:

      {"op": "eq", "field": "payer", "value": "acme"}
      {"op": "in", "field": "plan_type", "values": ["hmo", "pos"]}
      {"op": "not_in", "field": "product_line", "values": ["exchange"]}
      {"op": "neq", "field": "pcp_network", "value": "network_b"}
      {"op": "contains", "field": "card_note", "value": "example text"}
      {"op": "matches", "field": "member_id", "pattern": "^w\\d+$"}
      {"op": "matches", "field": "member_id", "pattern": "^W\\d+$", "flags": ""}
      {"op": "present", "field": "provider_id"}
      {"op": "blank", "field": "provider_id"}
      {"op": "gte", "field": "date_of_service", "value": "2000-02-01"}
      {"op": "between", "field": "date_of_service", "from": "2000-01-01", "to": null}
      {"op": "all", "conditions": [...]}
      {"op": "any", "conditions": [...]}
      {"op": "none", "conditions": [...]}
      {"op": "not", "condition": {...}}
      {"op": "pred", "name": "my_predicate", "args": [...]}
      {"op": "roster", "roster": "network_a", "product_field": "product"}
      {"op": "roster", "roster": "network_b", "product": "*"}

  `gt`, `lt` and `lte` take the same shape as `gte`. A `matches` pattern
  without `"flags"` follows the engine's case setting (case-insensitive by
  default); with `"flags"` (letters from `imsux`, `""` for none) it is
  compiled exactly as given. A roster condition reads
  the provider from `"provider_field"` (default `"provider_id"`) and the date
  from `"as_of_field"` (default `"date_of_service"`). Its product is either a
  candidate field (`"product_field"`, default `"product"`), a literal
  (`"product": "basic"`), or any product (`"product": "*"`).

  Dates are ISO 8601 strings. Decoding never creates atoms from field names,
  ops, or values. Outcome keys are the exception: they become atoms so that
  `result.network_status` works. Load only ruleset files you trust.
  """

  alias RuleMatch.{Roster, Rule}

  @any_product "*"

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
      case Keyword.get(opts, :product, :product) do
        :any -> Map.put(base, "product", @any_product)
        {:literal, value} -> Map.put(base, "product", to_json_value(value))
        field -> put_unless(base, "product_field", to_string(field), "product")
      end

    base
    |> put_unless(
      "provider_field",
      to_string(Keyword.get(opts, :provider, :provider_id)),
      "provider_id"
    )
    |> put_unless(
      "as_of_field",
      to_string(Keyword.get(opts, :as_of, :date_of_service)),
      "date_of_service"
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
    product =
      case Map.fetch(map, "product") do
        {:ok, @any_product} -> :any
        {:ok, value} -> {:literal, value}
        :error -> string!(Map.get(map, "product_field", "product"), "product_field")
      end

    opts = [
      provider: string!(Map.get(map, "provider_field", "provider_id"), "provider_field"),
      product: product,
      as_of: string!(Map.get(map, "as_of_field", "date_of_service"), "as_of_field")
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

  Cells for one provider that share dates and meta are grouped into one
  entry with a `"products"` list.
  """
  @spec rosters_to_map(Roster.t()) :: map()
  def rosters_to_map(book) do
    Map.new(book, fn {name, table} ->
      entries =
        table
        |> Enum.group_by(
          fn {{provider, _product}, cell} ->
            {provider, cell.effective_on, cell.terminates_on, cell.meta}
          end,
          fn {{_provider, product}, _cell} -> product end
        )
        |> Enum.map(fn {{provider, from, to, meta}, products} ->
          %{
            "provider" => provider,
            "products" => products |> Enum.map(&product_to_json/1) |> Enum.sort(),
            "effective_on" => to_json_value(from)
          }
          |> put_unless("terminates_on", to_json_value(to), nil)
          |> put_unless("meta", to_json_value(meta), %{})
        end)
        |> Enum.sort_by(&{&1["provider"], &1["products"]})

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
    provider = string!(required!(entry, "provider"), "roster provider")

    products =
      case entry do
        %{"products" => products} ->
          list!(products, "products")

        %{"product" => product} ->
          [product]

        _ ->
          raise ArgumentError,
                "roster entry for #{inspect(provider)} needs \"product\" or \"products\""
      end

    opts = [
      effective_on: date!(Map.get(entry, "effective_on")),
      terminates_on: date!(Map.get(entry, "terminates_on")),
      meta: Map.get(entry, "meta", %{})
    ]

    Enum.reduce(products, book, fn product, acc ->
      Roster.put(acc, name, provider, product_from_json(product), opts)
    end)
  end

  defp put_roster_entry(_book, name, other) do
    raise ArgumentError, "roster #{inspect(name)} entry must be an object, got: #{inspect(other)}"
  end

  defp product_to_json(:any), do: @any_product
  defp product_to_json(product), do: to_json_value(product)

  defp product_from_json(@any_product), do: :any
  defp product_from_json(product), do: product

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
    flags product product_field provider_field as_of_field condition conditions outcome
    provider products effective_on terminates_on meta rules rosters
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
