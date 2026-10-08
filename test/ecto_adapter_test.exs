defmodule RuleMatch.EctoAdapterTest do
  use RuleMatch.DataCase

  alias RuleMatch.{Roster, Ruleset, Store}

  setup %{repo: repo, prefix: prefix} do
    opts = [repo: repo, prefix: prefix]
    path = Path.join(System.tmp_dir!(), "ecto_adapter_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    %{opts: opts, ecto_opts: Keyword.put(opts, :adapter, RuleMatch.Adapters.Ecto), path: path}
  end

  test "database and file sources produce equivalent runtime rulesets and decisions", context do
    %{opts: opts, ecto_opts: ecto_opts, path: path} = context
    fixture = fixture()
    assert {:ok, decoded} = Ruleset.from_json(JSON.encode!(fixture))
    assert :ok = Ruleset.save(decoded, path)
    persist(fixture, opts)

    assert {:ok, from_file} = Ruleset.load(path, adapter: RuleMatch.Adapters.File)
    assert {:ok, from_db} = Ruleset.load("coverage", ecto_opts)
    assert Ruleset.to_map(from_db) == Ruleset.to_map(from_file)
    assert Enum.map(from_db.rules, & &1.id) == ["z-first", "a-second", "fallback"]
    assert Enum.map(from_db.rules, & &1.id) == Enum.map(from_file.rules, & &1.id)
    assert from_db.name == "Coverage"
    assert from_db.version == "2026-10"
    assert from_db.description == "Coverage with dated participation"
    assert from_db.meta == %{"source" => "fixture", "enabled" => false, "optional" => nil}
    assert hd(from_db.rules).meta == %{"source" => "first", "optional" => nil, :specificity => 4}
    assert hd(from_db.rules).tags == ["coverage", "participation"]
    assert hd(from_db.rules).description == "First source rule wins the tie"
    assert from_db.normalize == %{downcase: ["payer"], dates: ["date_of_service"]}

    candidate = candidate()

    assert %{payer: "acme", date_of_service: ~D[2026-07-03]} =
             Ruleset.normalize(from_db, candidate)

    for product <- [" BASIC ", false, nil, 7, ["bundle"], %{"kind" => "family"}] do
      subject = Map.put(candidate, "product", product)
      assert RuleMatch.decide(from_db, subject) == RuleMatch.decide(from_file, subject)

      assert {:ok, decision} = RuleMatch.decide(from_db, subject)
      assert decision.rule_id == "z-first"
      assert decision.network_status == "in_network"
      assert decision.file_claim === false
      assert Map.fetch!(decision, :reason) === nil
      assert decision.priority == 20
      assert decision.specificity == 4
      assert Enum.map(decision.alternatives, & &1.rule_id) == ["a-second", "fallback"]
      assert Enum.all?(decision.explanation, & &1.passed)
    end

    assert {:ok, cell} =
             Roster.member(from_db.rosters, "network", " PROVIDER_A ", "basic", ~D[2026-07-03])

    assert cell == %{
             effective_on: ~D[2026-01-01],
             terminates_on: ~D[2027-01-01],
             meta: %{"source" => "contract", "optional" => nil}
           }

    assert from_db.rosters == from_file.rosters

    for date <- ["2025-12-31", "2027-01-01"] do
      subject = Map.put(candidate, "date_of_service", date)
      assert RuleMatch.decide(from_db, subject) == RuleMatch.decide(from_file, subject)
      assert {:ok, %{rule_id: "fallback"}} = RuleMatch.decide(from_db, subject)
    end

    assert RuleMatch.decide(from_db, %{"payer" => "other"}) == :nomatch
    assert {:error, :not_found} = Ruleset.load("missing", ecto_opts)
    assert {:error, :not_found} = Ruleset.load("Coverage", ecto_opts)
  end

  test "empty rulesets load through the left join", %{opts: opts, ecto_opts: ecto_opts} do
    assert {:ok, _} = Store.create_ruleset(%{key: "empty"}, opts)

    assert {:ok, %Ruleset{rules: [], rosters: %{}, meta: %{}} = ruleset} =
             Ruleset.load("empty", ecto_opts)

    assert ruleset.normalize == %{downcase: [], dates: []}
    assert RuleMatch.decide(ruleset, candidate()) == :nomatch
  end

  test "edits and deletions are visible on the next load", %{opts: opts, ecto_opts: ecto_opts} do
    persist(fixture(), opts)
    assert {:ok, old} = Ruleset.load("coverage", ecto_opts)

    assert {:ok, _} =
             Store.update_ruleset(
               "coverage",
               %{name: "Edited", version: "next", meta: %{"changed" => true}},
               opts
             )

    assert {:ok, _} =
             Store.update_rule(
               "coverage",
               "z-first",
               %{outcome: %{"network_status" => "updated", "file_claim" => false}},
               opts
             )

    assert {:ok, edited} = Ruleset.load("coverage", ecto_opts)
    assert edited.name == "Edited" and edited.version == "next"
    assert edited.meta == %{"changed" => true}

    assert {:ok, %{network_status: "updated", file_claim: false}} =
             RuleMatch.decide(edited, candidate())

    assert old.name == "Coverage" and old.version == "2026-10"
    assert old.meta == %{"source" => "fixture", "enabled" => false, "optional" => nil}
    assert {:ok, %{network_status: "in_network"}} = RuleMatch.decide(old, candidate())

    assert {:ok, _} = Store.delete_rule("coverage", "z-first", opts)
    assert {:ok, fewer} = Ruleset.load("coverage", ecto_opts)
    assert Enum.map(fewer.rules, & &1.id) == ["a-second", "fallback"]

    assert {:ok, %{rule_id: "a-second", network_status: "out_of_network"}} =
             RuleMatch.decide(fewer, candidate())

    assert Enum.map(old.rules, & &1.id) == ["z-first", "a-second", "fallback"]
    assert {:ok, _} = Store.delete_ruleset("coverage", opts)
    assert {:error, :not_found} = Ruleset.load("coverage", ecto_opts)
    assert {:ok, %{rule_id: "z-first"}} = RuleMatch.decide(old, candidate())
  end

  test "malformed stored JSON returns a decoding error", %{
    opts: opts,
    ecto_opts: ecto_opts,
    repo: repo
  } do
    persist(fixture(), opts)

    for conditions <- [[%{"op" => "unknown"}], [%{"op" => "not", "condition" => nil}], [nil]] do
      query!(
        repo,
        "UPDATE rule_match.rules SET conditions = ARRAY[$1::text::jsonb] WHERE rule_id = 'z-first'",
        [JSON.encode!(hd(conditions))]
      )

      assert {:error, {:invalid_ruleset, message}} = Ruleset.load("coverage", ecto_opts)
      assert message =~ "conditions"
    end

    assert {:ok, _} =
             Store.update_rule(
               "coverage",
               "z-first",
               %{conditions: hd(fixture()["rules"])["conditions"]},
               opts
             )

    for {field, value, expected} <- [
          {"normalize", %{"downcase" => "payer"}, "normalize"},
          {"normalize", %{"dates" => [false]}, "normalize"},
          {"normalize", nil, "normalize"},
          {"rosters", %{"network" => [nil]}, "rosters"},
          {"rosters",
           %{
             "network" => [
               %{"member" => "p", "categories" => ["basic"], "effective_on" => "soon"}
             ]
           }, "rosters"},
          {"rosters", nil, "rosters"},
          {"meta", nil, "meta"}
        ] do
      query!(
        repo,
        "UPDATE rule_match.rulesets SET #{field} = $1::text::jsonb WHERE key = 'coverage'",
        [
          JSON.encode!(value)
        ]
      )

      assert {:error, {:invalid_ruleset, message}} = Ruleset.load("coverage", ecto_opts)
      assert message =~ expected

      query!(
        repo,
        "UPDATE rule_match.rulesets SET #{field} = $1::text::jsonb WHERE key = 'coverage'",
        [
          JSON.encode!(fixture()[field])
        ]
      )
    end

    for {field, value} <- [
          {"outcome", nil},
          {"outcome", []},
          {"outcome", %{String.duplicate("x", 256) => true}},
          {"meta", nil}
        ] do
      query!(
        repo,
        "UPDATE rule_match.rules SET #{field} = $1::text::jsonb WHERE rule_id = 'z-first'",
        [
          JSON.encode!(value)
        ]
      )

      assert {:error, {:invalid_ruleset, message}} = Ruleset.load("coverage", ecto_opts)
      assert message =~ field

      query!(
        repo,
        "UPDATE rule_match.rules SET #{field} = $1::text::jsonb WHERE rule_id = 'z-first'",
        [
          JSON.encode!(hd(fixture()["rules"])[field])
        ]
      )
    end
  end

  test "one load selects once and later decisions query nothing", %{
    opts: opts,
    ecto_opts: ecto_opts,
    repo: repo
  } do
    persist(fixture(), opts)
    event = repo.config()[:telemetry_prefix] ++ [:query]
    handler_id = "ecto-adapter-query-#{System.unique_integer([:positive])}"
    assert :ok = :telemetry.attach(handler_id, event, &__MODULE__.capture_query/4, {self(), repo})
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, ruleset} = Ruleset.load("coverage", ecto_opts)
    assert_receive {:adapter_query, query}
    assert query =~ "SELECT" and query =~ "LEFT OUTER JOIN"
    refute_receive {:adapter_query, _}
    assert Enum.map(ruleset.rules, & &1.id) == ["z-first", "a-second", "fallback"]

    for opts <- [[], [case_sensitive: true], [rosters: %{}]] do
      assert {:ok, %{rule_id: "z-first"}} = RuleMatch.decide(ruleset, candidate(), opts)
    end

    refute_receive {:adapter_query, _}
  end

  test "non-object stored JSON containers return decoding errors", %{
    opts: opts,
    ecto_opts: ecto_opts,
    repo: repo
  } do
    persist(fixture(), opts)

    for {table, fields, definition} <- [
          {"rulesets", ~w(normalize rosters meta), fixture()},
          {"rules", ~w(outcome meta), hd(fixture()["rules"])}
        ],
        field <- fields,
        value <- [[], "invalid", false, 7] do
      query!(repo, "UPDATE rule_match.#{table} SET #{field} = $1::text::jsonb", [
        JSON.encode!(value)
      ])

      assert {:error, {:invalid_ruleset, message}} = Ruleset.load("coverage", ecto_opts)
      assert message =~ field

      query!(repo, "UPDATE rule_match.#{table} SET #{field} = $1::text::jsonb", [
        JSON.encode!(definition[field])
      ])
    end

    for value <- [[], "invalid", false, 7] do
      query!(repo, "UPDATE rule_match.rules SET conditions = ARRAY[$1::text::jsonb]", [
        JSON.encode!(value)
      ])

      assert {:error, {:invalid_ruleset, message}} = Ruleset.load("coverage", ecto_opts)
      assert message =~ "conditions"
    end
  end

  test "configured Ecto defaults can be overridden with a file", %{opts: opts, path: path} do
    keys = [:adapter, :repo, :prefix, :ruleset]
    previous = Map.new(keys, &{&1, Application.fetch_env(:rule_match, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:rule_match, key, value)
        {key, :error} -> Application.delete_env(:rule_match, key)
      end)
    end)

    persist(fixture(), opts)
    Application.put_env(:rule_match, :adapter, RuleMatch.Adapters.Ecto)
    Application.put_env(:rule_match, :ruleset, "coverage")
    Application.put_env(:rule_match, :repo, opts[:repo])
    Application.put_env(:rule_match, :prefix, opts[:prefix])
    assert %Ruleset{name: "Coverage"} = configured = RuleMatch.ruleset()
    assert {:ok, %{rule_id: "z-first"}} = RuleMatch.decide(configured, candidate())
    assert :ok = Ruleset.save(Ruleset.new(name: "File override"), path)

    assert %Ruleset{name: "File override", rules: []} =
             RuleMatch.ruleset(path, adapter: RuleMatch.Adapters.File)

    assert {:ok, %Ruleset{name: "Coverage"}} = Ruleset.load("coverage")
  end

  test "invalid Repo and prefix configuration returns configuration errors", %{
    ecto_opts: ecto_opts
  } do
    for invalid <- [[repo: nil], [repo: String], [prefix: nil], [prefix: " "]] do
      assert {:error, {:invalid_config, message}} =
               Ruleset.load("coverage", Keyword.merge(ecto_opts, invalid))

      assert is_binary(message)
    end
  end

  test "unmigrated prefixes propagate database errors", %{ecto_opts: ecto_opts} do
    assert {:error, :not_found} = Ruleset.load("missing", ecto_opts)
    opts = Keyword.put(ecto_opts, :prefix, "unmigrated_#{System.unique_integer([:positive])}")
    assert_raise Postgrex.Error, fn -> Ruleset.load("coverage", opts) end
  end

  def capture_query(_event, _measurements, %{repo: repo, query: query}, {pid, repo}),
    do: send(pid, {:adapter_query, query})

  def capture_query(_event, _measurements, _metadata, _config), do: :ok

  defp query!(repo, query, params), do: Ecto.Adapters.SQL.query!(repo, query, params)

  defp persist(map, opts) do
    attrs =
      Map.take(map, ~w(name version description normalize rosters meta))
      |> Map.put("key", "coverage")

    assert {:ok, _} = Store.create_ruleset(attrs, opts)

    for {rule, index} <- Enum.with_index(map["rules"]) do
      attrs =
        rule
        |> Map.take(~w(description priority conditions outcome tags meta))
        |> Map.put("rule_id", rule["id"])
        |> Map.put("position", if(index < 2, do: 8, else: 20))

      assert {:ok, _} = Store.create_rule("coverage", attrs, opts)
    end
  end

  defp candidate do
    %{
      "payer" => " ACME ",
      "provider_id" => " PROVIDER_A ",
      "product" => " BASIC ",
      "date_of_service" => "2026-07-03",
      "excluded" => false,
      "covered" => false,
      "member_note" => nil
    }
  end

  defp fixture do
    conditions = [
      %{
        "op" => "all",
        "conditions" => [
          %{"op" => "eq", "field" => "payer", "value" => "acme"},
          %{
            "op" => "not",
            "condition" => %{"op" => "eq", "field" => "excluded", "value" => true}
          },
          %{
            "op" => "any",
            "conditions" => [
              %{"op" => "eq", "field" => "covered", "value" => false},
              %{"op" => "eq", "field" => "member_note", "value" => nil}
            ]
          }
        ]
      },
      %{
        "op" => "roster",
        "roster" => "network",
        "member_field" => "provider_id",
        "category_field" => "product",
        "as_of_field" => "date_of_service"
      }
    ]

    %{
      "format" => 1,
      "name" => "Coverage",
      "version" => "2026-10",
      "description" => "Coverage with dated participation",
      "normalize" => %{"downcase" => ["payer"], "dates" => ["date_of_service"]},
      "meta" => %{"source" => "fixture", "enabled" => false, "optional" => nil},
      "rosters" => %{
        "network" => [
          %{
            "member" => " PROVIDER_A ",
            "categories" => ["basic", false, nil, 7, ["bundle"], %{"kind" => "family"}],
            "effective_on" => "2026-01-01",
            "terminates_on" => "2027-01-01",
            "meta" => %{"source" => "contract", "optional" => nil}
          }
        ]
      },
      "rules" => [
        %{
          "id" => "z-first",
          "description" => "First source rule wins the tie",
          "priority" => 20,
          "conditions" => conditions,
          "tags" => ["coverage", "participation"],
          "meta" => %{"source" => "first", "optional" => nil},
          "outcome" => %{
            "network_status" => "in_network",
            "file_claim" => false,
            "reason" => nil,
            "rule_id" => "spoofed"
          }
        },
        %{
          "id" => "a-second",
          "priority" => 20,
          "conditions" => conditions,
          "outcome" => %{"network_status" => "out_of_network"}
        },
        %{
          "id" => "fallback",
          "priority" => 1,
          "conditions" => [%{"op" => "eq", "field" => "payer", "value" => "acme"}],
          "outcome" => %{"network_status" => "fallback"}
        }
      ]
    }
  end
end
