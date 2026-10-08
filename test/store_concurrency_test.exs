defmodule RuleMatch.StoreConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias EctoEvolver.Adapters.Postgres
  alias RuleMatch.Dev.UnboxedRepo
  alias RuleMatch.Schemas.{Rule, Ruleset}
  alias RuleMatch.Store

  setup do
    key = "store-concurrency-#{System.unique_integer([:positive, :monotonic])}"
    opts = [repo: UnboxedRepo, prefix: "rule_match"]

    on_exit(fn ->
      UnboxedRepo.delete_all(from(p in Ruleset, where: p.key in ^[key, key <> "-renamed"]),
        prefix: "rule_match"
      )
    end)

    %{key: key, opts: opts}
  end

  test "ten concurrent appends serialize on the parent and receive distinct positions", %{
    key: key,
    opts: opts
  } do
    assert {:ok, _} = Store.create_ruleset(%{key: key}, opts)
    caller = self()

    tasks =
      for n <- 0..9 do
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :append -> Store.create_rule(key, %{rule_id: "rule-#{n}"}, opts)
          after
            5_000 -> flunk("append barrier timed out")
          end
        end)
      end

    for _ <- 0..9, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :append))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %Rule{}}, &1))
    assert {:ok, rules} = Store.list_rules(key, opts)
    assert Enum.map(rules, & &1.position) == Enum.to_list(0..9)

    assert MapSet.new(Enum.map(rules, & &1.rule_id)) ==
             MapSet.new(~w(rule-0 rule-1 rule-2 rule-3 rule-4 rule-5 rule-6 rule-7 rule-8 rule-9))
  end

  for operation <- [:delete, :rename] do
    test "a write waiting on parent #{operation} returns not_found for the old key", %{
      key: key,
      opts: opts
    } do
      assert {:ok, parent} = Store.create_ruleset(%{key: key}, opts)
      caller = self()

      locker =
        Task.async(fn ->
          UnboxedRepo.transaction(fn ->
            locked =
              UnboxedRepo.one!(from(p in Ruleset, where: p.id == ^parent.id, lock: "FOR UPDATE"),
                prefix: "rule_match"
              )

            send(caller, :parent_locked)

            receive do
              :commit ->
                case unquote(operation) do
                  :delete ->
                    UnboxedRepo.delete!(locked, prefix: "rule_match")

                  :rename ->
                    UnboxedRepo.update!(Ruleset.changeset(locked, %{key: key <> "-renamed"}),
                      prefix: "rule_match"
                    )
                end
            after
              5_000 -> flunk("parent lock barrier timed out")
            end
          end)
        end)

      assert_receive :parent_locked, 5_000
      writer = Task.async(fn -> Store.create_rule(key, %{rule_id: "waiting"}, opts) end)

      try do
        await_blocked_writer()
      after
        send(locker.pid, :commit)
      end

      assert {:ok, _} = Task.await(locker, 10_000)
      assert {:error, :not_found} = Task.await(writer, 10_000)

      assert UnboxedRepo.all(from(r in Rule, where: r.ruleset_id == ^parent.id),
               prefix: "rule_match"
             ) == []

      if unquote(operation) == :rename do
        assert {:ok, %{rules: []}} = Store.fetch_ruleset(key <> "-renamed", opts)
        assert {:ok, _} = Store.create_rule(key <> "-renamed", %{rule_id: "valid"}, opts)
      end
    end
  end

  for parent_change <- [:delete, :rename], waiting_mutation <- [:update, :delete] do
    test "parent #{waiting_mutation} waiting on #{parent_change} resolves the old key after locking",
         %{key: key, opts: opts} do
      assert {:ok, parent} = Store.create_ruleset(%{key: key}, opts)
      caller = self()

      locker =
        Task.async(fn ->
          UnboxedRepo.transaction(fn ->
            UnboxedRepo.one!(from(p in Ruleset, where: p.id == ^parent.id, lock: "FOR UPDATE"),
              prefix: "rule_match"
            )

            [[backend_pid]] = UnboxedRepo.query!("SELECT pg_backend_pid()").rows
            send(caller, {:parent_locked, backend_pid})

            receive do
              :commit ->
                case unquote(parent_change) do
                  :delete ->
                    assert {:ok, _} = Store.delete_ruleset(key, opts)

                  :rename ->
                    assert {:ok, _} = Store.update_ruleset(key, %{key: key <> "-renamed"}, opts)
                end
            after
              5_000 -> flunk("parent mutation barrier timed out")
            end
          end)
        end)

      assert_receive {:parent_locked, backend_pid}, 5_000

      waiter =
        Task.async(fn ->
          try do
            case unquote(waiting_mutation) do
              :update -> Store.update_ruleset(key, %{meta: %{"unexpected" => true}}, opts)
              :delete -> Store.delete_ruleset(key, opts)
            end
          rescue
            error in Ecto.StaleEntryError -> {:raised, error.__struct__}
          end
        end)

      try do
        await_blocked_parent_mutation(backend_pid)
      after
        send(locker.pid, :commit)
      end

      assert {:ok, _} = Task.await(locker, 10_000)
      assert {:error, :not_found} = Task.await(waiter, 10_000)
      assert {:error, :not_found} = Store.fetch_ruleset(key, opts)

      if unquote(parent_change) == :rename do
        assert {:ok, %{id: id, meta: %{}}} = Store.fetch_ruleset(key <> "-renamed", opts)
        assert id == parent.id
      end
    end
  end

  test "same identities in two migrated prefixes stay isolated" do
    prefixes = for _ <- 1..2, do: "Store-Prefix-#{System.unique_integer([:positive, :monotonic])}"

    for prefix <- prefixes do
      escaped = Postgres.escape_identifier(prefix)
      UnboxedRepo.query!("CREATE SCHEMA #{escaped}")
      on_exit(fn -> UnboxedRepo.query!("DROP SCHEMA #{escaped} CASCADE") end)

      assert Ecto.Migrator.up(UnboxedRepo, 1, RuleMatch.Dev.Migration, prefix: prefix, log: false) ==
               :ok
    end

    [left, right] = Enum.map(prefixes, &[repo: UnboxedRepo, prefix: &1])

    for opts <- [left, right] do
      assert {:ok, _} = Store.create_ruleset(%{key: "same"}, opts)
      assert {:ok, _} = Store.create_rule("same", %{rule_id: "same"}, opts)
    end

    assert {:ok, right_rule} = Store.fetch_rule("same", "same", right)
    assert {:ok, _} = Store.update_rule("same", "same", %{priority: -5}, left)
    assert {:ok, ^right_rule} = Store.fetch_rule("same", "same", right)
    assert {:ok, _} = Store.delete_rule("same", "same", left)
    assert {:ok, ^right_rule} = Store.fetch_rule("same", "same", right)
    assert {:ok, _} = Store.create_rule("same", %{rule_id: "replacement"}, left)
    assert {:ok, _} = Store.update_ruleset("same", %{key: "renamed"}, left)
    assert {:error, :not_found} = Store.fetch_ruleset("same", left)
    assert {:ok, %{rules: [^right_rule]}} = Store.fetch_ruleset("same", right)
    assert {:ok, _} = Store.delete_ruleset("renamed", left)
    assert {:ok, []} = Store.list_rulesets(left)
    assert {:ok, %{rules: [^right_rule]}} = Store.fetch_ruleset("same", right)
    assert {:ok, [^right_rule]} = Store.list_rules("same", right)
  end

  defp await_blocked_parent_mutation(backend_pid, attempts \\ 100)

  defp await_blocked_parent_mutation(_backend_pid, 0),
    do: flunk("parent mutation did not wait on the parent lock")

  defp await_blocked_parent_mutation(backend_pid, attempts) do
    [[blocked]] =
      UnboxedRepo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity
          WHERE datname = current_database() AND wait_event_type = 'Lock'
            AND $1 = ANY(pg_blocking_pids(pid)) AND query LIKE '%rulesets%'
        )
        """,
        [backend_pid]
      ).rows

    if blocked do
      :ok
    else
      receive do
      after
        10 -> await_blocked_parent_mutation(backend_pid, attempts - 1)
      end
    end
  end

  defp await_blocked_writer(attempts \\ 100)
  defp await_blocked_writer(0), do: flunk("writer did not wait on the parent lock")

  defp await_blocked_writer(attempts) do
    [[blocked]] =
      UnboxedRepo.query!("""
      SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND query LIKE '%rulesets%' AND query LIKE '%FOR UPDATE%'
          AND pid <> pg_backend_pid()
      )
      """).rows

    if blocked do
      :ok
    else
      receive do
      after
        10 -> await_blocked_writer(attempts - 1)
      end
    end
  end
end
