defmodule RuleMatch.AdapterTest do
  use ExUnit.Case, async: false

  alias RuleMatch.{Config, Ruleset}

  defmodule TestAdapter do
    def load(identifier, opts) do
      send(self(), {:adapter_options, opts})
      {:ok, Ruleset.new(name: identifier)}
    end
  end

  defmodule ThrowingAdapter do
    def load(_identifier, _opts), do: raise(RuntimeError, "adapter failure")
  end

  defmodule MissingAdapter do
    def load(_identifier, _opts), do: {:error, :not_found}
  end

  defmodule UnstartedRepo do
    use Ecto.Repo, otp_app: :rule_match, adapter: Ecto.Adapters.Postgres
  end

  setup do
    keys = [:adapter, :repo, :prefix, :ruleset]
    previous = Map.new(keys, &{&1, Application.fetch_env(:rule_match, &1)})
    Enum.each(keys, &Application.delete_env(:rule_match, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:rule_match, key, value)
        {key, :error} -> Application.delete_env(:rule_match, key)
      end)
    end)
  end

  test "dispatches to a per-call adapter and preserves the identifier" do
    assert {:ok, %{name: "coverage"}} = Ruleset.load("coverage", adapter: TestAdapter)
    assert RuleMatch.ruleset("override", adapter: TestAdapter).name == "override"
    assert Ruleset.load!(" Coverage ", adapter: TestAdapter).name == " Coverage "
  end

  test "dispatches the configured default identifier through the configured adapter" do
    Application.put_env(:rule_match, :adapter, TestAdapter)
    Application.put_env(:rule_match, :ruleset, "coverage")
    assert RuleMatch.ruleset().name == "coverage"
    assert RuleMatch.ruleset("explicit").name == "explicit"
    assert {:ok, %{name: "loaded"}} = Ruleset.load("loaded")
  end

  test "per-call options override configuration and unknown options reach the adapter" do
    Application.put_env(:rule_match, :adapter, ThrowingAdapter)
    Application.put_env(:rule_match, :repo, RuleMatch.Dev.Repo)
    Application.put_env(:rule_match, :prefix, "configured")

    assert {:ok, %{name: "coverage"}} =
             Ruleset.load("coverage",
               adapter: TestAdapter,
               repo: UnstartedRepo,
               prefix: "override",
               custom: :option
             )

    assert_received {:adapter_options, opts}
    assert opts[:adapter] == TestAdapter
    assert opts[:repo] == UnstartedRepo
    assert opts[:prefix] == "override"
    assert opts[:custom] == :option
  end

  test "loader resolves default adapter and prefix while preserving caller options" do
    assert {:ok, opts} = Config.loader(custom: 42)
    assert opts[:adapter] == RuleMatch.Adapters.File
    assert opts[:prefix] == "rule_match"
    assert opts[:custom] == 42
  end

  test "rejects invalid adapters with configuration errors" do
    for adapter <- [String, nil, false, "Elixir.RuleMatch.AdapterTest.TestAdapter"] do
      assert {:error, {:invalid_config, message}} = Ruleset.load("x", adapter: adapter)
      assert message =~ "adapter"
      assert_raise ArgumentError, ~r/adapter/, fn -> Ruleset.load!("x", adapter: adapter) end
    end
  end

  test "rejects absent, blank, and non-string identifiers" do
    for identifier <- [nil, "", " \t\n", :coverage, 1] do
      assert {:error, {:invalid_config, message}} = Ruleset.load(identifier)
      assert message =~ "ruleset"
      assert_raise ArgumentError, ~r/ruleset/, fn -> RuleMatch.ruleset(identifier) end
    end
  end

  test "unexpected adapter exceptions propagate through all loading APIs" do
    assert_raise RuntimeError, "adapter failure", fn ->
      Ruleset.load("x", adapter: ThrowingAdapter)
    end

    assert_raise RuntimeError, "adapter failure", fn ->
      Ruleset.load!("x", adapter: ThrowingAdapter)
    end

    assert_raise RuntimeError, "adapter failure", fn ->
      RuleMatch.ruleset("x", adapter: ThrowingAdapter)
    end
  end

  test "expected missing-record errors are preserved and formatted in raising APIs" do
    assert {:error, :not_found} = Ruleset.load("missing", adapter: MissingAdapter)

    assert_raise ArgumentError, ~r/ruleset not found/, fn ->
      RuleMatch.ruleset("missing", adapter: MissingAdapter)
    end
  end

  test "store requires a Repo module and accepts a Repo that is not running" do
    assert {:error, {:invalid_config, message}} = Config.store([])
    assert message =~ "repo"

    for repo <- [String, nil, "Elixir.RuleMatch.Dev.Repo", false] do
      assert {:error, {:invalid_config, _}} = Config.store(repo: repo)
    end

    refute Process.whereis(UnstartedRepo)
    assert {:ok, {UnstartedRepo, "rule_match"}} = Config.store(repo: UnstartedRepo)
  end

  test "store resolves configuration with per-call precedence" do
    Application.put_env(:rule_match, :repo, RuleMatch.Dev.Repo)
    Application.put_env(:rule_match, :prefix, "configured")
    assert {:ok, {RuleMatch.Dev.Repo, "configured"}} = Config.store([])

    assert {:ok, {UnstartedRepo, "override"}} =
             Config.store(repo: UnstartedRepo, prefix: "override")
  end

  test "store rejects explicitly missing, blank, and non-string prefixes" do
    for prefix <- [nil, "", " \t\n", :rules, 1] do
      assert {:error, {:invalid_config, message}} =
               Config.store(repo: UnstartedRepo, prefix: prefix)

      assert message =~ "prefix"
    end
  end

  test "invalid configuration strings never create atoms" do
    value = "Elixir.UnknownRuleMatchModule#{System.unique_integer([:positive])}"
    assert {:error, {:invalid_config, _}} = Ruleset.load("x", adapter: value)
    assert {:error, {:invalid_config, _}} = Config.store(repo: value)
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end

  test "file loading ignores invalid database options" do
    path = Path.join(System.tmp_dir!(), "adapter_file_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    :ok = Ruleset.save(Ruleset.new(name: "file"), path)
    Application.put_env(:rule_match, :repo, "invalid repo")
    Application.put_env(:rule_match, :prefix, nil)

    assert {:ok, %{name: "file"}} = Ruleset.load(path)
    assert {:ok, %{name: "file"}} = RuleMatch.Adapters.File.load(path, repo: false)
  end
end
