defmodule RuleMatch.DataCase do
  @moduledoc """
  Sandbox-owned database tests using the locally migrated rule_match prefix.

  Cases default to synchronous execution. Asynchronous consumers must use
  unique fixture identities and avoid global application configuration changes.
  """
  use ExUnit.CaseTemplate

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(RuleMatch.Dev.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    {:ok, repo: RuleMatch.Dev.Repo, prefix: "rule_match"}
  end
end
