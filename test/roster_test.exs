defmodule RuleMatch.RosterTest do
  use ExUnit.Case, async: true
  alias RuleMatch.Roster

  test "effective date is inclusive and termination date is exclusive" do
    book =
      Roster.put(Roster.new(), :network, "provider", "basic",
        effective_on: ~D[2025-12-31],
        terminates_on: ~D[2026-01-02],
        meta: %{source: "contract"}
      )

    refute Roster.member?(book, "network", "provider", "basic", ~D[2025-12-30])

    for date <- [~D[2025-12-31], ~D[2026-01-01]] do
      assert {:ok, %{meta: %{source: "contract"}}} =
               Roster.member(book, :network, "provider", "basic", date)
    end

    refute Roster.member?(book, :network, "provider", "basic", ~D[2026-01-02])
    refute Roster.member?(book, :network, "provider", "basic", nil)
  end

  test "unbounded cells accept nil dates but either bound requires a date" do
    for opts <- [[], [effective_on: ~D[2026-01-01]], [terminates_on: ~D[2026-01-01]]] do
      book = Roster.put(Roster.new(), :network, "provider", "basic", opts)
      assert Roster.member?(book, :network, "provider", "basic", nil) == (opts == [])
    end
  end

  test "wildcard cells cover concrete products and normalize provider and product identifiers" do
    book = Roster.put(Roster.new(), :network, :Provider, :any)
    assert Roster.member?(book, "network", " PROVIDER ", " BASIC ", nil)
    assert Roster.member?(book, :network, :provider, :any, nil)
    refute Roster.member?(book, :missing, :provider, :basic, nil)
    refute Roster.member?(book, :network, :other, :basic, nil)
    exact = Roster.put(Roster.new(), :network, " PROVIDER ", " BASIC ")
    assert Roster.member?(exact, :network, :provider, :basic, nil)
    refute Roster.member?(exact, :network, :provider, :any, nil)
  end

  test "a specific product cell takes precedence over a wildcard even when expired" do
    book =
      Roster.new()
      |> Roster.put(:network, "provider", :any)
      |> Roster.put(:network, "provider", "basic", terminates_on: ~D[2026-01-01])

    refute Roster.member?(book, :network, "provider", "basic", ~D[2026-01-01])
    assert Roster.member?(book, :network, "provider", "plus", ~D[2026-01-01])
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
