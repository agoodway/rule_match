defmodule RuleMatch.Adapters.File do
  @moduledoc """
  Read a JSON ruleset from a file on every load.

  The identifier is a file path. This default adapter requires no Repo and
  ignores database options. File errors and decoding failures return error
  tuples. Select explicitly with `adapter: RuleMatch.Adapters.File` when
  the application has configured a different loader.
  """

  @behaviour RuleMatch.Adapter

  @impl true
  def load(path, _opts) do
    with {:ok, json} <- File.read(path) do
      RuleMatch.Ruleset.from_json(json)
    end
  end
end
