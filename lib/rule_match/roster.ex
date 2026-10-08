defmodule RuleMatch.Roster do
  @moduledoc """
  Provider participation that depends on product and date.

  A roster is often a matrix: a provider row, a product column, and an
  effective date in the cell. A flat provider list cannot express that. This module stores cells as:

      {provider_id, product} => %{effective_on: date, terminates_on: date | nil}

  `product` may be the atom `:any` when the agreement is not product-specific.
  A lookup for a concrete product also matches an `:any` cell.

  Plan-level termination (a whole plan leaving on a given date) belongs on
  the rule, not in the cell. A cell can still carry its own
  `terminates_on` when a single provider left early.
  """

  @type cell :: %{effective_on: Date.t() | nil, terminates_on: Date.t() | nil, meta: map()}
  @type t :: %{optional(String.t()) => %{optional({term(), term()}) => cell()}}

  @doc "Empty roster book."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Insert a participation cell.

  `provider_id` and `product` are normalized (strings downcased and trimmed).
  Pass `product: :any` for an agreement that covers every product. Roster
  names are stored as strings; an atom name is converted.
  """
  @spec put(t(), atom() | String.t(), term(), term(), keyword()) :: t()
  def put(book, roster, provider_id, product, opts \\ []) do
    cell = %{
      effective_on: Keyword.get(opts, :effective_on),
      terminates_on: Keyword.get(opts, :terminates_on),
      meta: Keyword.get(opts, :meta, %{})
    }

    key = {normalize(provider_id), normalize(product)}
    Map.update(book, normalize_name(roster), %{key => cell}, &Map.put(&1, key, cell))
  end

  @doc """
  `{:ok, cell}` when the provider is participating for the product on `as_of`.

  An open `effective_on` or `terminates_on` does not constrain that side.
  `as_of` must be a `Date` (or nil, which only matches cells with no bounds).
  """
  @spec member(t(), atom() | String.t(), term(), term(), Date.t() | nil) ::
          {:ok, cell()} | :not_member
  def member(book, roster, provider_id, product, as_of) do
    table = Map.get(book, normalize_name(roster), %{})
    provider = normalize(provider_id)
    product = normalize(product)

    cell =
      Map.get(table, {provider, product}) ||
        Map.get(table, {provider, :any})

    if cell && covers?(cell, as_of), do: {:ok, cell}, else: :not_member
  end

  @doc "Boolean form of `member/5`."
  @spec member?(t(), atom() | String.t(), term(), term(), Date.t() | nil) :: boolean()
  def member?(book, roster, provider_id, product, as_of) do
    match?({:ok, _}, member(book, roster, provider_id, product, as_of))
  end

  defp covers?(%{effective_on: from, terminates_on: to}, as_of) do
    on_or_after?(as_of, from) and before?(as_of, to)
  end

  # Date structs do not compare chronologically with >=. Use Date.compare/2.
  defp on_or_after?(_as_of, nil), do: true
  defp on_or_after?(nil, _from), do: false
  defp on_or_after?(%Date{} = as_of, %Date{} = from), do: Date.compare(as_of, from) != :lt
  defp on_or_after?(as_of, from), do: as_of >= from

  defp before?(_as_of, nil), do: true
  defp before?(nil, _to), do: false
  defp before?(%Date{} = as_of, %Date{} = to), do: Date.compare(as_of, to) == :lt
  defp before?(as_of, to), do: as_of < to

  defp normalize(:any), do: :any
  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()
  defp normalize(value), do: value

  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
end
