defmodule RuleMatch.Reading do
  @moduledoc """
  Fingerprint and freshness of a rule's plain-English reading.

  The fingerprint is a checksum of the rule the sentence was accepted
  against. It does not judge the English. Matching does not call this module.
  """

  alias RuleMatch.{Codec, Rule, Ruleset}

  @type status :: :absent | :unsealed | :fresh | :stale

  @spec fingerprint(Ruleset.t(), Rule.t()) :: String.t()
  def fingerprint(%Ruleset{} = ruleset, %Rule{} = rule) do
    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, canonical(document(ruleset, rule))), case: :lower)
  end

  @spec status(Ruleset.t(), Rule.t()) :: status()
  def status(%Ruleset{} = ruleset, %Rule{} = rule) do
    cond do
      not present?(rule.reading) -> :absent
      not present_fingerprint?(rule.reading_fingerprint) -> :unsealed
      rule.reading_fingerprint == fingerprint(ruleset, rule) -> :fresh
      true -> :stale
    end
  end

  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_), do: false

  defp present_fingerprint?(value) when is_binary(value), do: value != ""
  defp present_fingerprint?(_), do: false

  defp document(ruleset, rule) do
    %{
      "conditions" => Enum.map(rule.conditions, &Codec.condition_to_map/1),
      "normalize" => %{
        "dates" => normalize_list(ruleset.normalize.dates),
        "downcase" => normalize_list(ruleset.normalize.downcase)
      },
      "outcome" => Codec.to_json_value(rule.outcome),
      "priority" => rule.priority,
      "rosters" =>
        Map.new(roster_names(rule.conditions), fn name ->
          {name, roster_value(ruleset.rosters, name)}
        end)
    }
  end

  defp normalize_list(list) do
    list |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.uniq()
  end

  defp roster_names(conditions) when is_list(conditions) do
    conditions |> Enum.flat_map(&roster_names/1) |> Enum.uniq()
  end

  defp roster_names({:all, conditions}), do: roster_names(conditions)
  defp roster_names({:any, conditions}), do: roster_names(conditions)
  defp roster_names({:none, conditions}), do: roster_names(conditions)
  defp roster_names({:not, condition}), do: roster_names(condition)
  defp roster_names({:roster, name, _opts}), do: [to_string(name)]
  defp roster_names(_), do: []

  defp roster_value(book, name) do
    if Map.has_key?(book, name) do
      book
      |> Codec.rosters_to_map()
      |> Map.fetch!(name)
      |> Enum.sort_by(&entry_sort_key/1)
    else
      nil
    end
  end

  defp entry_sort_key(entry) do
    {
      entry["member"],
      date_key(entry["effective_on"]),
      date_key(Map.get(entry, "terminates_on")),
      entry["categories"],
      canonical(Map.get(entry, "meta", %{})),
      canonical(entry)
    }
  end

  defp date_key(nil), do: {0, ""}
  defp date_key(value) when is_binary(value), do: {1, value}

  defp canonical(value), do: IO.iodata_to_binary(encode(value))

  defp encode(%{} = map) do
    pairs =
      map
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))

    [
      "{",
      pairs
      |> Enum.map(fn {key, item} -> [JSON.encode!(key), ":", encode(item)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp encode(list) when is_list(list) do
    ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  defp encode(value), do: JSON.encode!(value)
end
