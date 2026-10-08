defmodule RuleMatch.ConfiguredRulesetTest do
  use ExUnit.Case, async: false

  alias RuleMatch.Ruleset

  setup do
    previous = Application.fetch_env(:rule_match, :ruleset)

    path =
      Path.join(System.tmp_dir!(), "configured_rules_#{System.unique_integer([:positive])}.json")

    Ruleset.save(Ruleset.new(name: "original"), path)
    Application.delete_env(:rule_match, :ruleset)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:rule_match, :ruleset, value)
        :error -> Application.delete_env(:rule_match, :ruleset)
      end

      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "loads the configured default ruleset", %{path: path} do
    Application.put_env(:rule_match, :ruleset, path)
    assert RuleMatch.ruleset().name == "original"
  end

  test "explicit paths override the configured default", %{path: path} do
    Application.put_env(:rule_match, :ruleset, path <> ".missing")
    assert RuleMatch.ruleset(path).name == "original"
  end

  test "requires a configured identifier for the default" do
    assert_raise ArgumentError, ~r/no ruleset configured/, fn -> RuleMatch.ruleset() end
    Application.put_env(:rule_match, :ruleset, :invalid)
    assert_raise ArgumentError, ~r/ruleset.*string/, fn -> RuleMatch.ruleset() end
  end

  test "reads edited files even when their modification time is unchanged", %{path: path} do
    assert RuleMatch.ruleset(path).name == "original"
    mtime = File.stat!(path).mtime
    Ruleset.save(Ruleset.new(name: "updated"), path)
    File.touch!(path, mtime)

    relative = Path.relative_to(path, File.cwd!())
    assert RuleMatch.ruleset(relative).name == "updated"
  end

  test "reloads files when their modification time changes", %{path: path} do
    assert RuleMatch.ruleset(path).name == "original"
    Ruleset.save(Ruleset.new(name: "updated"), path)
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    assert RuleMatch.ruleset(path).name == "updated"
  end

  test "rejects malformed replacements with unchanged modification times", %{path: path} do
    RuleMatch.ruleset(path)
    mtime = File.stat!(path).mtime
    File.write!(path, "invalid json")
    File.touch!(path, mtime)
    assert {:error, {:invalid_json, _}} = Ruleset.load(path)
    assert_raise ArgumentError, ~r/cannot load ruleset/, fn -> RuleMatch.ruleset(path) end
  end

  test "reports deleted files after a successful load", %{path: path} do
    RuleMatch.ruleset(path)
    File.rm!(path)
    assert {:error, :enoent} = Ruleset.load(path)
    assert_raise ArgumentError, ~r/no such file/, fn -> RuleMatch.ruleset(path) end
  end
end
