defmodule RuleMatch.Schemas.Ruleset do
  @moduledoc "An Ecto record for a stored ruleset definition."
  use Ecto.Schema

  import Ecto.Changeset
  alias RuleMatch.StoredData

  @fields [:key, :name, :version, :description, :normalize, :rosters, :meta]
  @json_fields [:normalize, :rosters, :meta]

  schema "rulesets" do
    field(:key, :string)
    field(:name, :string)
    field(:version, :string)
    field(:description, :string)
    field(:normalize, :map, default: %{"downcase" => [], "dates" => []})
    field(:rosters, :map, default: %{})
    field(:meta, :map, default: %{})
    has_many(:rules, RuleMatch.Schemas.Rule)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    case StoredData.normalize_attrs(attrs) do
      {:ok, attrs} ->
        record
        |> cast(attrs, @fields)
        |> validate_required([:key])
        |> reject_association(attrs)
        |> validate_definition(attrs)
        |> unique_constraint(:key, name: :rulesets_key_index)

      {:error, message} ->
        record |> change() |> add_error(:base, message)
    end
  end

  defp reject_association(changeset, attrs) do
    if Map.has_key?(attrs, "rules"),
      do: add_error(changeset, :rules, "cannot be assigned through ruleset attributes"),
      else: changeset
  end

  defp validate_definition(changeset, attrs) do
    candidate =
      Map.new(@fields, fn field -> {Atom.to_string(field), get_field(changeset, field)} end)

    # Check supplied JSON before casting can transform array items or discard
    # empty values, and validate unchanged fields on updates as well.
    json_keys = Enum.map(@json_fields, &Atom.to_string/1)
    candidate = Map.merge(candidate, Map.take(attrs, json_keys))

    case StoredData.validate_ruleset(candidate) do
      :ok -> changeset
      {:error, {field, message}} -> add_error(changeset, field, message)
    end
  end
end
