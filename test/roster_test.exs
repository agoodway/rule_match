defmodule RuleMatch.RosterTest do
  use ExUnit.Case, async: true
  alias RuleMatch.Roster

  test "effective date is inclusive and termination date is exclusive" do
    book =
      Roster.put(Roster.new(), :access, "member", "read",
        effective_on: ~D[2025-12-31],
        terminates_on: ~D[2026-01-02],
        meta: %{source: "import"}
      )

    refute Roster.member?(book, "access", "member", "read", ~D[2025-12-30])

    for date <- [~D[2025-12-31], ~D[2026-01-01]] do
      assert {:ok, %{meta: %{source: "import"}}} =
               Roster.member(book, :access, "member", "read", date)
    end

    refute Roster.member?(book, :access, "member", "read", ~D[2026-01-02])
    refute Roster.member?(book, :access, "member", "read", nil)
  end

  test "unbounded cells accept nil dates but either bound requires a date" do
    for opts <- [[], [effective_on: ~D[2026-01-01]], [terminates_on: ~D[2026-01-01]]] do
      book = Roster.put(Roster.new(), :access, "member", "read", opts)
      assert Roster.member?(book, :access, "member", "read", nil) == (opts == [])
    end
  end

  test "wildcard cells cover concrete categories and normalize member and category identifiers" do
    book = Roster.put(Roster.new(), :access, :Member, :any)
    assert Roster.member?(book, "access", " MEMBER ", " READ ", nil)
    assert Roster.member?(book, :access, :member, :any, nil)
    refute Roster.member?(book, :missing, :member, :read, nil)
    refute Roster.member?(book, :access, :other, :read, nil)
    exact = Roster.put(Roster.new(), :access, " MEMBER ", " READ ")
    assert Roster.member?(exact, :access, :member, :read, nil)
    refute Roster.member?(exact, :access, :member, :any, nil)
  end

  test "a specific category cell takes precedence over a wildcard even when expired" do
    book =
      Roster.new()
      |> Roster.put(:access, "member", :any)
      |> Roster.put(:access, "member", "read", terminates_on: ~D[2026-01-01])

    refute Roster.member?(book, :access, "member", "read", ~D[2026-01-01])
    assert Roster.member?(book, :access, "member", "write", ~D[2026-01-01])
  end

  test "put replaces only the addressed cell and preserves other rosters" do
    book =
      Roster.new()
      |> Roster.put(:a, 123, 1)
      |> Roster.put(:a, 123, 2)
      |> Roster.put(:b, 123, 1)
      |> Roster.put(:a, 123, 1, meta: %{updated: true})

    assert {:ok, %{meta: %{updated: true}}} = Roster.member(book, :a, 123, 1, nil)
    assert Roster.member?(book, :a, 123, 2, nil)
    assert Roster.member?(book, :b, 123, 1, nil)
  end
end
