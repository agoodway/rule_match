defmodule RuleMatch.Adapters.Ecto do
  @moduledoc "Load a runtime ruleset from an ordered database snapshot on every call."

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
