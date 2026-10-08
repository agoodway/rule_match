defmodule RuleMatch.Roster do
  @moduledoc """
  Named membership tables that depend on category and date.

  A member can be any identified entity, such as a person, organization,
  device, or location. Categories can represent roles, permissions, or
  groups. Each roster stores cells as:

      {member_id, category} => %{effective_on: date, terminates_on: date | nil}

  `category` may be the atom `:any` for membership across every category.
  A lookup uses a specific category cell first, then an `:any` cell if no
  specific cell exists. An expired specific cell still takes precedence.

  `effective_on` is inclusive and `terminates_on` is exclusive. Either
  bound may be nil. A cell's termination applies to one member/category
  pair; broader restrictions, such as shutting down a category, can be
  expressed as higher-priority rules.
  """

  @type cell :: %{effective_on: Date.t() | nil, terminates_on: Date.t() | nil, meta: map()}
  @type t :: %{optional(String.t()) => %{optional({term(), term()}) => cell()}}

  @doc "Empty roster book."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Insert or replace a membership cell.

  `member_id` and `category` are normalized (strings downcased and trimmed).
  Pass `:any` as the category argument for membership across every category.
  Roster names are stored as strings; an atom name is converted. Each
  member/category pair holds one cell, so another put replaces that cell.
  """
  @spec put(t(), atom() | String.t(), term(), term(), keyword()) :: t()
  def put(book, roster, member_id, category, opts \\ []) do
    cell = %{
      effective_on: Keyword.get(opts, :effective_on),
      terminates_on: Keyword.get(opts, :terminates_on),
      meta: Keyword.get(opts, :meta, %{})
    }

    key = {normalize(member_id), normalize(category)}
    Map.update(book, normalize_name(roster), %{key => cell}, &Map.put(&1, key, cell))
  end

  @doc """
  `{:ok, cell}` when membership is active for the category on `as_of`.

  An open `effective_on` or `terminates_on` does not constrain that side.
  `as_of` must be a `Date` (or nil, which only matches cells with no bounds).
  """
  @spec member(t(), atom() | String.t(), term(), term(), Date.t() | nil) ::
          {:ok, cell()} | :not_member
  def member(book, roster, member_id, category, as_of) do
    table = Map.get(book, normalize_name(roster), %{})
    member = normalize(member_id)
    category = normalize(category)

    cell =
      Map.get(table, {member, category}) ||
        Map.get(table, {member, :any})

    if cell && covers?(cell, as_of), do: {:ok, cell}, else: :not_member
  end

  @doc "Boolean form of `member/5`."
  @spec member?(t(), atom() | String.t(), term(), term(), Date.t() | nil) :: boolean()
  def member?(book, roster, member_id, category, as_of) do
    match?({:ok, _}, member(book, roster, member_id, category, as_of))
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
