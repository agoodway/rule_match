defmodule RuleMatch.Store do
  @moduledoc """
  Database CRUD for stored rulesets and rules.

  Each call resolves the configured Repo and prefix, with caller options taking
  precedence. Parent and rule mutations lock the parent within a transaction.
  Omitted creation positions append after the current maximum. Positions are
  otherwise preserved, including ties and gaps.

  Always uses the database, regardless of the configured loader adapter.
  Supply an application Repo through `:rule_match, :repo` or `repo:`; the
  prefix defaults to `"rule_match"` and may be overridden with `prefix:`.
  Successful calls return `{:ok, record}` or `{:ok, records}` using stored
  schema structs. Missing parents or rules return `{:error, :not_found}`,
  invalid writes return `{:error, Ecto.Changeset.t()}`, and configuration
  errors return `{:error, {:invalid_config, message}}`. Database exceptions
  propagate. Empty lists are successful results.

  Attribute maps accept atom or string field names; nested JSON objects
  require string keys and JSON values. Conditions use the codec's JSON
  representation. Ruleset writes affect only parent attributes; nested
  `rules` input is rejected. Rule parents come from the key argument;
  `ruleset_id` and parent associations cannot be assigned through attrs.
  Primary keys and timestamps are server-managed. Keys are case-sensitive;
  `rule_id` is unique within its parent. Updates may rename either identifier.

  Omitting a creation position appends from zero. Rules load by position then
  primary key, including equal positions and gaps. `fetch_ruleset/2` loads
  ordered rules in one joined query; list results do not preload associations.
  Deleting a parent cascades to its rules. Use `RuleMatch.Ruleset.load/2`
  with the Ecto adapter to decode a runtime snapshot for matching.
  """

  import Ecto.Query
  alias RuleMatch.Codec
  alias RuleMatch.Config
  alias RuleMatch.Reading
  alias RuleMatch.Schemas.{Rule, Ruleset}
  alias RuleMatch.StoredData

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
      with_locked_parent(repo, prefix, key, fn parent ->
        repo.update(Ruleset.changeset(parent, attrs), prefix: prefix)
      end)
    end
  end

  @doc "Delete a ruleset and its rules."
  def delete_ruleset(key, opts \\ []) do
    with {:ok, {repo, prefix}} <- Config.store(opts),
         :ok <- identifier(key, :key) do
      with_locked_parent(repo, prefix, key, fn parent ->
        repo.delete(parent, prefix: prefix)
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
        repo.insert(seal_changeset(record, attrs, parent), prefix: prefix)
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
          repo.update(seal_changeset(rule, attrs, parent), prefix: prefix)
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

  defp seal_changeset(record, attrs, parent) do
    changeset = Rule.changeset(record, attrs)

    with {:ok, normalized} <- StoredData.normalize_attrs(attrs),
         true <- changeset.valid? and Map.has_key?(normalized, "reading"),
         reading when is_binary(reading) <- Ecto.Changeset.get_field(changeset, :reading) do
      Ecto.Changeset.put_change(
        changeset,
        :reading_fingerprint,
        Reading.fingerprint(reading_ruleset(parent), runtime_rule(changeset))
      )
    else
      _ -> changeset
    end
  end

  defp reading_ruleset(parent) do
    normalize = parent.normalize || %{}

    %RuleMatch.Ruleset{
      normalize: %{
        downcase: Map.get(normalize, "downcase", []),
        dates: Map.get(normalize, "dates", [])
      },
      rosters: Codec.rosters_from_map(parent.rosters || %{})
    }
  end

  defp runtime_rule(changeset) do
    Codec.rule_from_map(%{
      "id" => Ecto.Changeset.get_field(changeset, :rule_id),
      "priority" => Ecto.Changeset.get_field(changeset, :priority),
      "conditions" => Ecto.Changeset.get_field(changeset, :conditions) || [],
      "outcome" => Ecto.Changeset.get_field(changeset, :outcome) || %{},
      "reading" => Ecto.Changeset.get_field(changeset, :reading)
    })
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
