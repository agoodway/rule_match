defmodule RuleMatch.Types.StoredJSON do
  @moduledoc """
  A stored JSON object with ordinary Ecto map casting and dumping.

  Loading preserves database JSON shapes so that `RuleMatch.StoredData` can
  report malformed definitions instead of Ecto raising while loading a record.
  """
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: Ecto.Type.cast(:map, value)

  @impl true
  def dump(value), do: Ecto.Type.dump(:map, value)

  @impl true
  def load(value), do: {:ok, value}
end
