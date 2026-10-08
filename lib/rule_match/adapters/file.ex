defmodule RuleMatch.Adapters.File do
  @moduledoc "Read a JSON ruleset from a file on every load."

  @behaviour RuleMatch.Adapter

  @impl true
  def load(path, _opts) do
    with {:ok, json} <- File.read(path) do
      RuleMatch.Ruleset.from_json(json)
    end
  end
end
