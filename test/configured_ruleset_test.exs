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
      :persistent_term.erase({RuleMatch, Path.expand(path)})
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

  test "requires a configured path for the default" do
    assert_raise ArgumentError, ~r/no ruleset configured/, fn -> RuleMatch.ruleset() end
    Application.put_env(:rule_match, :ruleset, :invalid)
    assert_raise ArgumentError, ~r/ruleset.*path/, fn -> RuleMatch.ruleset() end
  end

  test "caches unchanged files under their absolute path", %{path: path} do
    loaded = RuleMatch.ruleset(path)
    mtime = File.stat!(path).mtime
    File.write!(path, "invalid json")
    File.touch!(path, mtime)

    relative = Path.relative_to(path, File.cwd!())
    assert RuleMatch.ruleset(relative) == loaded
  end

  test "reloads files when their modification time changes", %{path: path} do
    assert RuleMatch.ruleset(path).name == "original"
    Ruleset.save(Ruleset.new(name: "updated"), path)
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    assert RuleMatch.ruleset(path).name == "updated"
  end

  test "rejects invalid files after a cached file changes", %{path: path} do
    RuleMatch.ruleset(path)
    File.write!(path, "invalid json")
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    assert_raise ArgumentError, ~r/cannot load ruleset/, fn -> RuleMatch.ruleset(path) end
  end

  test "reports deleted files rather than returning stale cache entries", %{path: path} do
    RuleMatch.ruleset(path)
    File.rm!(path)
    assert_raise File.Error, fn -> RuleMatch.ruleset(path) end
  end
end
