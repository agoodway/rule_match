defmodule RuleMatch.Schemas.Rule do
  @moduledoc """
  An Ecto record for a stored rule, distinct from a runtime `RuleMatch.Rule`.

  Writable attributes are `rule_id`, `description`, `reading`, `priority`,
  `position`, `conditions`, `outcome`, `tags`, and `meta`.
  `reading_fingerprint` is set by the library and rejected in attributes.
  Conditions use string-keyed
  codec objects; outcome and metadata are JSON objects, and tags are strings.
  `rule_id` is unique within the parent. Priorities fit a signed 32-bit integer;
  positions range from zero to 2_147_483_647 and may tie or have gaps.
  `RuleMatch.Store` supplies the parent and default append position; changesets reject parent reassignment. Primary keys and timestamps
  are server-managed.
  """
  use Ecto.Schema

  import Ecto.Changeset
  alias RuleMatch.StoredData
  alias RuleMatch.Types.StoredJSON

  @fields [
    :rule_id,
    :description,
    :reading,
    :priority,
    :position,
    :conditions,
    :outcome,
    :tags,
    :meta
  ]
  @json_fields [:conditions, :outcome, :tags, :meta]

  schema "rules" do
    belongs_to(:ruleset, RuleMatch.Schemas.Ruleset)
    field(:rule_id, :string)
    field(:description, :string)
    field(:reading, :string)
    field(:reading_fingerprint, :string)
    field(:priority, :integer, default: 0)
    field(:position, :integer)
    field(:conditions, {:array, StoredJSON}, default: [])
    field(:outcome, StoredJSON, default: %{})
    field(:tags, {:array, :string}, default: [])
    field(:meta, StoredJSON, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    case StoredData.normalize_attrs(attrs) do
      {:ok, attrs} ->
        record
        |> cast(attrs, @fields -- [:tags])
        |> cast(attrs, [:tags], empty_values: [])
        |> validate_required([:ruleset_id, :rule_id, :priority, :position])
        |> validate_storage_integer(:priority, -2_147_483_648, 2_147_483_647)
        |> validate_storage_integer(:position, 0, 2_147_483_647)
        |> reject_parent(attrs)
        |> cast_reading(attrs)
        |> validate_definition(attrs)
        |> unique_constraint(:rule_id, name: :rules_ruleset_id_rule_id_index)
        |> foreign_key_constraint(:ruleset_id, name: :rules_ruleset_id_fkey)
        |> check_constraint(:position, name: :rules_position_nonnegative)

      {:error, message} ->
        record |> change() |> add_error(:base, message)
    end
  end

  # Check complete fields: Store's automatic append starts on the record,
  # so validate_number/3 (which only checks changes) would miss its overflow.
  defp validate_storage_integer(changeset, field, minimum, maximum) do
    case get_field(changeset, field) do
      value when is_integer(value) and value < minimum ->
        add_error(changeset, field, "must be greater than or equal to %{number}",
          validation: :number,
          kind: :greater_than_or_equal_to,
          number: minimum
        )

      value when is_integer(value) and value > maximum ->
        add_error(changeset, field, "must be less than or equal to %{number}",
          validation: :number,
          kind: :less_than_or_equal_to,
          number: maximum
        )

      _ ->
        changeset
    end
  end

  defp reject_parent(changeset, attrs) do
    Enum.reduce([:ruleset_id, :ruleset], changeset, fn field, changeset ->
      if Map.has_key?(attrs, Atom.to_string(field)),
        do: add_error(changeset, field, "cannot be assigned through rule attributes"),
        else: changeset
    end)
  end

  defp cast_reading(changeset, attrs) do
    cond do
      Map.has_key?(attrs, "reading_fingerprint") ->
        add_error(changeset, :reading_fingerprint, "is set by the library")

      not Map.has_key?(attrs, "reading") ->
        changeset

      is_nil(attrs["reading"]) or blank_reading?(attrs["reading"]) ->
        changeset
        |> put_change(:reading, nil)
        |> put_change(:reading_fingerprint, nil)

      is_binary(attrs["reading"]) ->
        put_change(changeset, :reading, attrs["reading"])

      true ->
        add_error(changeset, :reading, "must be a string")
    end
  end

  defp blank_reading?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_reading?(_), do: false

  defp validate_definition(changeset, attrs) do
    candidate =
      Map.new(@fields -- [:position], fn
        :rule_id -> {"id", get_field(changeset, :rule_id)}
        field -> {Atom.to_string(field), get_field(changeset, field)}
      end)

    candidate = Map.merge(candidate, Map.take(attrs, Enum.map(@json_fields, &Atom.to_string/1)))

    case StoredData.validate_rule(candidate) do
      :ok -> changeset
      {:error, {:id, message}} -> add_error(changeset, :rule_id, message)
      {:error, {field, message}} -> add_error(changeset, field, message)
    end
  end
end
