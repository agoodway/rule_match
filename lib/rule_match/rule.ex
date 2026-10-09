defmodule RuleMatch.Rule do
  @moduledoc """
  A named set of conditions and the outcome to return when they match.

  Unspecified fields are wildcards. A rule does not fail because a candidate
  carries extra keys.
  """

  @enforce_keys [:id, :conditions]
  defstruct [
    :id,
    :description,
    :reading,
    :reading_fingerprint,
    conditions: [],
    outcome: %{},
    priority: 0,
    tags: [],
    meta: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          reading: String.t() | nil,
          reading_fingerprint: String.t() | nil,
          conditions: [RuleMatch.Condition.t()],
          outcome: map(),
          priority: integer(),
          tags: [atom() | String.t()],
          meta: map()
        }

  @doc """
  Build a rule.

  Required: `:id` and `:conditions` (also accepted as `:when`).
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    conditions = Map.get(attrs, :conditions) || Map.get(attrs, :when) || []

    %__MODULE__{
      id: fetch_id!(attrs),
      description: Map.get(attrs, :description),
      reading: Map.get(attrs, :reading),
      reading_fingerprint: Map.get(attrs, :reading_fingerprint),
      conditions: conditions,
      outcome: Map.get(attrs, :outcome) || Map.get(attrs, :result) || %{},
      priority: Map.get(attrs, :priority, 0),
      tags: Map.get(attrs, :tags, []),
      meta: Map.get(attrs, :meta, %{})
    }
  end

  defp fetch_id!(attrs) do
    case Map.get(attrs, :id) do
      id when is_binary(id) and id != "" -> id
      id when is_atom(id) and not is_nil(id) -> Atom.to_string(id)
      other -> raise ArgumentError, "rule id must be a string, got: #{inspect(other)}"
    end
  end
end
