defmodule RuleMatch.Adapters.Ecto do
  @moduledoc """
  Load a runtime ruleset from an ordered database snapshot on every call.

  The identifier is an exact, case-sensitive ruleset key. Configure an
  application Repo with `:rule_match, :repo` or pass `repo:`. The default
  prefix is `"rule_match"`; configure `:prefix` or pass `prefix:` to change
  it. Install tables through `RuleMatch.Migration` using the same prefix.

  A single joined query loads the parent and rules ordered by position and
  primary key. Stored JSON is validated and decoded through the common
  runtime codec, recomputing specificity. Missing keys return
  `{:error, :not_found}`; malformed definitions return
  `{:error, {:invalid_ruleset, message}}`. Database exceptions propagate.
  No migrations or caching occur during loading.
  """

  @behaviour RuleMatch.Adapter

  alias RuleMatch.{Ruleset, Store, StoredData}

  @impl true
  def load(key, opts) do
    with {:ok, stored} <- Store.fetch_ruleset(key, opts),
         map = ruleset_map(stored),
         :ok <- validate(map) do
      Ruleset.from_map(map)
    end
  end

  defp ruleset_map(stored) do
    %{
      "format" => 1,
      "name" => stored.name,
      "version" => stored.version,
      "description" => stored.description,
      "normalize" => stored.normalize,
      "rosters" => stored.rosters,
      "meta" => stored.meta,
      "rules" => Enum.map(stored.rules, &rule_map/1)
    }
  end

  defp rule_map(stored) do
    %{
      "id" => stored.rule_id,
      "description" => stored.description,
      "reading" => stored.reading,
      "reading_fingerprint" => stored.reading_fingerprint,
      "priority" => stored.priority,
      "conditions" => stored.conditions,
      "outcome" => stored.outcome,
      "tags" => stored.tags,
      "meta" => stored.meta
    }
  end

  defp validate(map) do
    case StoredData.validate_ruleset(map) do
      :ok -> :ok
      {:error, {field, message}} -> {:error, {:invalid_ruleset, "#{field}: #{message}"}}
    end
  end
end
