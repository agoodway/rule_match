defmodule RuleMatch.Store do
  @moduledoc """
  Database CRUD for stored rulesets and rules.

  Each call resolves the configured Repo and prefix, with caller options taking
  precedence. Rule mutations lock their parent within a transaction; omitted
  creation positions append after the current maximum. Positions are otherwise
  preserved, including ties and gaps.
  """

  import Ecto.Query
  alias RuleMatch.Config
  alias RuleMatch.Schemas.{Rule, Ruleset}

  @doc "List rulesets in key order."
  def list_rulesets(opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts) do
      {:ok, repo.all(from(p in Ruleset, order_by: p.key), prefix: prefix)}
    end
  end

  @doc "Fetch a ruleset and all ordered rules in one joined snapshot."
  def fetch_ruleset(key, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key) do
      query =
        from(p in Ruleset,
          left_join: r in assoc(p, :rules),
          where: p.key == ^key,
          order_by: [asc: r.position, asc: r.id],
          preload: [rules: r]
        )

      found(repo.one(query, prefix: prefix))
    end
  end

  @doc "Create an empty ruleset from its own attributes."
  def create_ruleset(attrs, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts) do
      transaction(repo, fn ->
        repo.insert(Ruleset.changeset(%Ruleset{}, attrs), prefix: prefix)
      end)
    end
  end

  @doc "Update a ruleset's attributes, including its key when supplied."
  def update_ruleset(key, attrs, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key) do
      transaction(repo, fn ->
        with {:ok, parent} <- find_parent(repo, prefix, key) do
          repo.update(Ruleset.changeset(parent, attrs), prefix: prefix)
        end
      end)
    end
  end

  @doc "Delete a ruleset and its rules."
  def delete_ruleset(key, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key) do
      transaction(repo, fn ->
        with {:ok, parent} <- find_parent(repo, prefix, key) do
          repo.delete(parent, prefix: prefix)
        end
      end)
    end
  end

  @doc "List a parent's rules in position and primary-key order."
  def list_rules(key, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key),
         {:ok, parent} <- find_parent(repo, prefix, key) do
      {:ok, repo.all(ordered_rules(parent.id), prefix: prefix)}
    end
  end

  @doc "Fetch a rule by its parent's key and its scoped identifier."
  def fetch_rule(key, rule_id, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key),
         :ok <- identifier(rule_id, :rule_id) do
      query =
        from(r in Rule,
          join: p in assoc(r, :ruleset),
          where: p.key == ^key and r.rule_id == ^rule_id
        )

      found(repo.one(query, prefix: prefix))
    end
  end

  @doc "Create a rule under the supplied parent, appending when position is omitted."
  def create_rule(key, attrs, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key) do
      with_locked_parent(repo, prefix, key, fn parent ->
        max_position =
          repo.one(from(r in Rule, where: r.ruleset_id == ^parent.id, select: max(r.position)),
            prefix: prefix
          )

        record = %Rule{ruleset_id: parent.id, position: (max_position || -1) + 1}
        repo.insert(Rule.changeset(record, attrs), prefix: prefix)
      end)
    end
  end

  @doc "Update a rule's attributes, including its scoped identifier when supplied."
  def update_rule(key, rule_id, attrs, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key),
         :ok <- identifier(rule_id, :rule_id) do
      with_locked_parent(repo, prefix, key, fn parent ->
        with {:ok, rule} <- find_rule(repo, prefix, parent.id, rule_id) do
          repo.update(Rule.changeset(rule, attrs), prefix: prefix)
        end
      end)
    end
  end

  @doc "Delete a rule by its parent's key and its scoped identifier."
  def delete_rule(key, rule_id, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key),
         :ok <- identifier(rule_id, :rule_id) do
      with_locked_parent(repo, prefix, key, fn parent ->
        with {:ok, rule} <- find_rule(repo, prefix, parent.id, rule_id) do
          repo.delete(rule, prefix: prefix)
        end
      end)
    end
  end

  defp ordered_rules(parent_id) do
    from(r in Rule, where: r.ruleset_id == ^parent_id, order_by: [asc: r.position, asc: r.id])
  end

  defp find_parent(repo, prefix, key) do
    found(repo.one(from(p in Ruleset, where: p.key == ^key), prefix: prefix))
  end

  defp find_rule(repo, prefix, parent_id, rule_id) do
    query = from(r in Rule, where: r.ruleset_id == ^parent_id and r.rule_id == ^rule_id)
    found(repo.one(query, prefix: prefix))
  end

  defp with_locked_parent(repo, prefix, key, fun) do
    transaction(repo, fn ->
      query = from(p in Ruleset, where: p.key == ^key, lock: "FOR UPDATE")

      with {:ok, parent} <- found(repo.one(query, prefix: prefix)) do
        fun.(parent)
      end
    end)
  end

  defp transaction(repo, fun) do
    repo.transaction(fn ->
      case fun.() do
        {:ok, record} -> record
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp found(nil), do: {:error, :not_found}
  defp found(record), do: {:ok, record}

  defp identifier(value, field) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, {:invalid_config, "#{field} must be a nonblank string, got: #{inspect(value)}"}}
    end
  end
end
