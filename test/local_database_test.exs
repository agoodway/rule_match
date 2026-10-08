defmodule RuleMatch.LocalDatabaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias RuleMatch.Dev.Repo

  test "test database matches the selected Repo configuration" do
    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.query!("SELECT current_database()").rows == [[Repo.config()[:database]]]
    end)
  end

  test "JSONB arrays round-trip with built-in JSON" do
    Sandbox.unboxed_run(Repo, fn ->
      value = %{"flag" => false, "nested" => [nil, %{"op" => "blank", "field" => "x"}]}

      assert Repo.query!("SELECT $1::jsonb", [value]).rows == [[value]]
      assert Repo.query!("SELECT $1::jsonb[]", [[value]]).rows == [[[value]]]
    end)
  end
end
