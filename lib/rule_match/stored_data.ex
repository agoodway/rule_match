defmodule RuleMatch.StoredData do
  @moduledoc """
  Attribute normalization and validation of stored JSON definitions.

  Attribute names are converted to strings only at the top level. Nested
  definitions must already use JSON values and string object keys. Outcome
  keys retain the existing codec's trusted-definition atom conversion.
  """

  alias RuleMatch.{Codec, Ruleset}

  @spec normalize_attrs(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_attrs(attrs) when is_map(attrs) and not is_struct(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(acc, key) and Map.fetch!(acc, key) !== value do
          {:halt, {:error, "conflicting values for attribute #{inspect(key)}"}}
        else
          {:cont, {:ok, Map.put(acc, key, value)}}
        end

      _, _ ->
        {:halt, {:error, "attribute names must be strings or atoms"}}
    end)
  end

  def normalize_attrs(_), do: {:error, "attributes must be an object"}

  @spec validate_ruleset(map()) :: :ok | {:error, {atom(), String.t()}}
  def validate_ruleset(map) when is_map(map) and not is_struct(map) do
    with :ok <- optional_strings(map, [:name, :version, :description]),
         :ok <- validate_normalize(Map.get(map, "normalize", %{})),
         :ok <- validate_rosters(Map.get(map, "rosters", %{})),
         :ok <- object(Map.get(map, "meta", %{}), :meta),
         :ok <- validate_rules(Map.get(map, "rules", [])) do
      case Ruleset.from_map(map) do
        {:ok, _} -> :ok
        {:error, {:unsupported_format, _}} -> error(:format, "unsupported ruleset format")
        {:error, {:invalid_ruleset, message}} -> error(:base, message)
      end
    end
  end

  def validate_ruleset(_), do: error(:base, "ruleset must be an object")

  @spec validate_rule(map()) :: :ok | {:error, {atom(), String.t()}}
  def validate_rule(map) when is_map(map) and not is_struct(map) do
    with :ok <- identifier(Map.get(map, "id"), :id),
         :ok <- optional_strings(map, [:description]),
         :ok <- integer(Map.get(map, "priority", 0), :priority),
         :ok <- strings(Map.get(map, "tags", []), :tags),
         :ok <- object(Map.get(map, "outcome", %{}), :outcome),
         :ok <- object(Map.get(map, "meta", %{}), :meta),
         :ok <- validate_conditions(Map.get(map, "conditions", [])),
         :ok <- decode(:conditions, fn -> Codec.rule_from_map(map) end) do
      :ok
    end
  end

  def validate_rule(_), do: error(:base, "rule must be an object")

  defp optional_strings(map, fields) do
    each(fields, fn field ->
      value = Map.get(map, Atom.to_string(field))
      if is_nil(value) or is_binary(value), do: :ok, else: error(field, "must be a string")
    end)
  end

  defp identifier(value, field) when is_binary(value) do
    if String.trim(value) == "", do: error(field, "must be nonblank"), else: :ok
  end

  defp identifier(_, field), do: error(field, "must be a nonblank string")
  defp integer(value, _) when is_integer(value), do: :ok
  defp integer(_, field), do: error(field, "must be an integer")

  defp strings(value, field) do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: json(value, field),
      else: error(field, "must be a list of strings")
  end

  defp object(value, field) when is_map(value) and not is_struct(value),
    do: json(value, field)

  defp object(_, field), do: error(field, "must be an object")

  defp json(value, field) do
    if json_value?(value) do
      JSON.encode!(value)
      :ok
    else
      error(field, "must contain JSON-compatible values with string object keys")
    end
  rescue
    _exception in [ArgumentError, ErlangError] ->
      error(field, "must contain JSON-encodable values")
  end

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_), do: false

  defp validate_normalize(value) do
    with :ok <- object(value, :normalize),
         :ok <- strings(Map.get(value, "downcase", []), :normalize),
         :ok <- strings(Map.get(value, "dates", []), :normalize),
         do: :ok
  end

  defp validate_rosters(value) do
    with :ok <- object(value, :rosters),
         :ok <- each(value, fn {_name, entries} -> validate_roster_entries(entries) end),
         :ok <- decode(:rosters, fn -> Codec.rosters_from_map(value) end),
         do: :ok
  end

  defp validate_roster_entries(entries) when is_list(entries) do
    each(entries, fn entry ->
      with :ok <- object(entry, :rosters),
           :ok <- object(Map.get(entry, "meta", %{}), :rosters),
           do: :ok
    end)
  end

  defp validate_roster_entries(_), do: error(:rosters, "roster entries must be a list")

  defp validate_rules(rules) when is_list(rules) do
    each(rules, fn rule ->
      case validate_rule(rule) do
        :ok -> :ok
        {:error, {field, message}} -> error(:rules, "#{field}: #{message}")
      end
    end)
  end

  defp validate_rules(_), do: error(:rules, "must be a list of rule objects")

  defp validate_conditions(conditions) when is_list(conditions),
    do: each(conditions, &validate_condition/1)

  defp validate_conditions(_), do: error(:conditions, "must be a list of condition objects")

  defp validate_condition(condition) do
    with :ok <- object(condition, :conditions),
         :ok <- validate_children(condition),
         :ok <- validate_regex(condition),
         :ok <- decode(:conditions, fn -> Codec.condition_from_map(condition) end),
         do: :ok
  end

  defp validate_children(%{"op" => op} = condition) when op in ["all", "any", "none"],
    do: validate_conditions(Map.get(condition, "conditions"))

  defp validate_children(%{"op" => "not"} = condition),
    do: validate_condition(Map.get(condition, "condition"))

  defp validate_children(_), do: :ok

  # The codec retains unflagged regex sources as strings; validate their syntax
  # here without changing the runtime's case-sensitive compilation behavior.
  defp validate_regex(%{"op" => "matches", "pattern" => pattern} = condition)
       when is_binary(pattern) do
    if Map.has_key?(condition, "flags") do
      :ok
    else
      case Regex.compile(pattern) do
        {:ok, _} -> :ok
        {:error, reason} -> error(:conditions, "bad regex: #{inspect(reason)}")
      end
    end
  end

  defp validate_regex(_), do: :ok

  defp decode(field, fun) do
    fun.()
    :ok
  rescue
    exception in ArgumentError -> error(field, Exception.message(exception))
  end

  defp each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp error(field, message), do: {:error, {field, message}}
end
