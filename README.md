# rule_match

A small Elixir rules engine that looks for a match in a set of candidates.

It is a matcher, not a Rete network and not a forward-chaining interpreter. A candidate is a map of fields. A rule is a named list of conditions plus an outcome. Fields a rule does not mention are wildcards.

Rules are data. A ruleset holds the rules, the rosters they reference, and how to normalize a candidate. Load it from a JSON file or PostgreSQL. The package has no domain knowledge and ships no rules; you supply the definitions.

Rosters are optional. Rules can match candidate fields directly without any roster data.

## Install

```elixir
def deps do
  [
    {:rule_match, path: "rule_match"}
  ]
end
```

Requires Elixir 1.18+ for the built-in `JSON` module. Runtime dependencies include `ecto_sql` and `ecto_evolver`. Applications using PostgreSQL supply their own Postgrex dependency and supervised Ecto Repo; the package's Postgrex dependency and local Repo are only for development and testing.

## Rulesets

```elixir
{:ok, ruleset} = RuleMatch.Ruleset.load("rules.json")
RuleMatch.decide(ruleset, %{"organization" => "Acme", "tier" => "STANDARD"})
RuleMatch.Ruleset.save(ruleset, "rules.json")
```

The file adapter is the default. Set the path in your application's config:

```elixir
config :rule_match, :ruleset, "/path/to/rules.json"
```

Then load the configured ruleset or an explicit path:

```elixir
ruleset = RuleMatch.ruleset()
RuleMatch.decide(ruleset, %{"organization" => "Acme", "tier" => "STANDARD"})

other_ruleset = RuleMatch.ruleset("other_rules.json")
```

`RuleMatch.ruleset/0,1,2` returns a runtime `%RuleMatch.Ruleset{}` and raises
`ArgumentError` on expected loading failures. With no identifier it uses the
configured `:ruleset`. `RuleMatch.Ruleset.load/1,2` returns `{:ok, ruleset}` or
`{:error, reason}`; `load!/1,2` returns the ruleset or raises. Unexpected adapter
or database exceptions propagate. Identifiers must be nonblank strings.

Both adapters read their source on every call, without caching. A loaded
ruleset is a snapshot: reload it to see later changes. `Ruleset.save/2` exports
that snapshot to a JSON file and returns `:ok` or `{:error, reason}` regardless
of the loading adapter; database writes use `RuleMatch.Store`.

`from_json/1` / `to_json/1` and `from_map/1` / `to_map/1` are the in-memory forms. Saving then loading gives back the same rules and rosters. `to_json/1` uses a stable key order and puts short conditions on one line, so diffs of an edited file stay small.

```json
{
  "format": 1,
  "name": "access",
  "version": "2026-01-01",
  "normalize": {"downcase": ["organization", "tier"], "dates": ["as_of"]},
  "rules": [
    {
      "id": "acme_standard",
      "priority": 10,
      "conditions": [
        {"op": "eq", "field": "organization", "value": "acme"},
        {"op": "in", "field": "tier", "values": ["standard", "premium"]}
      ],
      "outcome": {"access_status": "allowed"}
    }
  ],
  "rosters": {
    "access_a": [{"member": "member_a", "categories": ["read", "write"], "effective_on": "2024-08-15"}]
  }
}
```

`normalize.downcase` fields are trimmed and downcased, and `normalize.dates` fields parsed from ISO strings, before matching. String keys that name a known atom become atom keys.

Decoding never creates atoms from ops, field names, or values. Outcome keys do become atoms so that `result.access_status` works; outcome values stay JSON values (`"allowed"`, not `:allowed`). Load only ruleset definitions you trust.

`match/3`, `best/3`, `select/3`, and `decide/3` take either a ruleset or a plain list of `%RuleMatch.Rule{}`. With a ruleset, its rosters join the context and its normalization runs first. `match/3` returns `{:ok, matches}` (possibly empty); `best/3` returns `{:ok, %RuleMatch.Match{}}` or `:nomatch`. `decide/3` returns `{:ok, outcome}` or `:nomatch`; the winning outcome includes `:rule_id`, `:explanation`, `:priority`, `:specificity`, and `:alternatives` (every other rule that matched). `select/3` returns a list of candidate/match maps; `explain/3` returns a list of condition explanations.

## PostgreSQL rulesets

Add `{:postgrex, "~> 0.22"}` to your application's dependencies and configure
and supervise its Ecto Repo. For an application named `:my_app`:

```elixir
# Define this in your application before the Repo uses it.
Postgrex.Types.define(MyApp.PostgresTypes, [], json: JSON)

defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

# Application configuration; supply your database connection settings too.
config :my_app, ecto_repos: [MyApp.Repo]
config :my_app, MyApp.Repo,
  url: "postgres://user:password@localhost/my_app",
  types: MyApp.PostgresTypes
```

The host-owned types module uses Elixir's built-in `JSON` for JSONB fields.
Configure it on every Repo used with RuleMatch; Postgrex's default JSON codec
otherwise requires a separate Jason dependency.

Include `MyApp.Repo` in your application's supervised children. Then select
the Ecto loader:

```elixir
config :rule_match,
  adapter: RuleMatch.Adapters.Ecto,
  repo: MyApp.Repo,
  prefix: "rule_match",
  ruleset: "coverage"
```

The Ecto identifier is an exact, case-sensitive key. The default prefix is
`"rule_match"`; there is no default application Repo. Per-call options override
application configuration for both loader entry points:

```elixir
ruleset = RuleMatch.ruleset()
ruleset = RuleMatch.ruleset("coverage")
ruleset = RuleMatch.ruleset("coverage", repo: OtherApp.Repo, prefix: "other_rules")
{:ok, ruleset} = RuleMatch.Ruleset.load("coverage")
ruleset = RuleMatch.Ruleset.load!("coverage")
{:ok, file_ruleset} = RuleMatch.Ruleset.load("rules.json", adapter: RuleMatch.Adapters.File)
```

The file override works without a Repo. Custom loaders implement
`RuleMatch.Adapter.load/2`, returning `{:ok, ruleset}` or `{:error, reason}`.

Install the library tables through your application's own Ecto migration:

```elixir
defmodule MyApp.Repo.Migrations.AddRuleMatch do
  use Ecto.Migration

  def up, do: RuleMatch.Migration.up(prefix: "rule_match")
  def down, do: RuleMatch.Migration.down(prefix: "rule_match")
end
```

Run your application's `mix ecto.migrate`. The migration prefix and the query
prefix must agree. `RuleMatch.Migration` uses EctoEvolver with versioned SQL
shipped in `priv/rule_match/sql/versions/v01/`. It creates the schema, `rulesets`
and `rules` tables, indexes, and constraints. The `rulesets` table tracks the
migration version independently of a definition's application `version` string.
Rollback drops the rules table before the rulesets table and preserves the
schema and unrelated objects. Loading a ruleset or starting the library never
runs migrations.

## Persisting rulesets

`RuleMatch.Store` always uses the database, regardless of the loader adapter.
It accepts `repo:` and `prefix:` options with the same configuration defaults
and override rules as the Ecto loader. Successful records are stored
`RuleMatch.Schemas.Ruleset` or `RuleMatch.Schemas.Rule` structs, distinct from
the runtime structs used for matching.

| Function | Successful result |
| --- | --- |
| `list_rulesets(opts \\ [])` | `{:ok, records}`, ordered by key |
| `fetch_ruleset(key, opts \\ [])` | `{:ok, record}`, with ordered rules loaded |
| `create_ruleset(attrs, opts \\ [])` | `{:ok, record}` |
| `update_ruleset(key, attrs, opts \\ [])` | `{:ok, record}` |
| `delete_ruleset(key, opts \\ [])` | `{:ok, deleted_record}` |
| `list_rules(key, opts \\ [])` | `{:ok, records}`, ordered by position and primary key |
| `fetch_rule(key, rule_id, opts \\ [])` | `{:ok, record}` |
| `create_rule(key, attrs, opts \\ [])` | `{:ok, record}` |
| `update_rule(key, rule_id, attrs, opts \\ [])` | `{:ok, record}` |
| `delete_rule(key, rule_id, opts \\ [])` | `{:ok, deleted_record}` |

Missing parents or rules return `{:error, :not_found}`, including listing rules
for a missing parent. Empty collections return `{:ok, []}`. Invalid writes
return `{:error, %Ecto.Changeset{}}`; invalid configuration returns
`{:error, {:invalid_config, message}}`. Unexpected database exceptions propagate.

Attribute maps accept atom or string field names at the top level. Nested JSON
objects require string keys and JSON values, using the same condition and roster
shapes as file definitions. Conditions are a JSONB array; `outcome`, `normalize`,
`rosters`, and `meta` are JSONB objects. Tags are a list of strings, including
empty and whitespace-only strings. Database rules use `rule_id` for the runtime
rule's `id`.

Ruleset attributes are `key`, `name`, `version`, `description`, `normalize`,
`rosters`, and `meta`. Rule attributes are `rule_id`, `description`, `priority`,
`position`, `conditions`, `outcome`, `tags`, and `meta`. Primary keys and
timestamps are server-managed. Creating a ruleset creates an empty parent;
updates change only its own attributes, including its key when supplied.
Nested `rules` input is rejected with a changeset error. Change rules through
the rule functions. The parent comes from the key argument; overriding
`ruleset_id` or assigning a parent association is rejected. Rule updates may
rename `rule_id`, which remains unique within its parent.

Parent and rule writes resolve and lock the parent row inside a transaction.
A write waiting on a parent deletion or rename returns `{:error, :not_found}`
for the old key. Omitting a creation position appends after the maximum position,
starting at zero. Priorities range from -2_147_483_648 to 2_147_483_647;
positions range from zero to 2_147_483_647. Ties and gaps are valid. Out-of-range
values, including an automatic append beyond the maximum position, return
changeset errors. The Ecto loader reads the parent and all rules in one joined
snapshot, ordered by position then primary key. Matching ranks by priority then recomputed specificity; equal
scores keep input order, so the first stored rule in that order wins a tie.
Deleting a parent cascades to its rules.

After installing the tables and starting your Repo, this example creates a
definition, loads a runtime snapshot, and makes a decision:

```elixir
opts = [repo: MyApp.Repo, prefix: "rule_match"]

{:ok, _stored} = RuleMatch.Store.create_ruleset(%{
  key: "coverage",
  name: "Coverage",
  version: "2026-10",
  normalize: %{"downcase" => ["payer"], "dates" => []}
}, opts)

{:ok, _rule} = RuleMatch.Store.create_rule("coverage", %{
  rule_id: "acme_ppo",
  priority: 10,
  conditions: [
    %{"op" => "eq", "field" => "payer", "value" => "acme"},
    %{"op" => "eq", "field" => "plan_type", "value" => "ppo"}
  ],
  outcome: %{"network_status" => "in_network"},
  tags: ["coverage"]
}, opts)

{:ok, ruleset} = RuleMatch.Ruleset.load("coverage",
  adapter: RuleMatch.Adapters.Ecto, repo: MyApp.Repo, prefix: "rule_match")

{:ok, decision} = RuleMatch.decide(ruleset, %{"payer" => " Acme ", "plan_type" => "PPO"})
decision.network_status # => "in_network"
decision.rule_id        # => "acme_ppo"
```

## Two directions

Rules can also be built in code, which is handy in tests. Rules against one subject — which rule wins:

```elixir
rules = [
  RuleMatch.rule("acme_standard",
    priority: 10,
    conditions: [{:eq, :organization, "acme"}, {:eq, :tier, "standard"}],
    outcome: %{access_status: :allowed}
  )
]

{:ok, winner} = RuleMatch.best(rules, %{organization: "Acme", tier: "STANDARD", market: "north"})
winner.outcome.access_status
```

One rule set against many candidates — which candidates match:

```elixir
RuleMatch.select(rules, [
  %{id: 1, organization: "acme", tier: "standard"},
  %{id: 2, organization: "globex", tier: "starter"}
])
```

`match/3` returns every matching rule, ranked by `{priority, specificity}` descending. Specificity is the number of leaf constraints, so a rule checking organization, tier, and region beats one checking only organization at the same priority. `explain/3` returns pass/fail for every condition.

## Conditions

| JSON | Elixir | Meaning |
| --- | --- | --- |
| `{"op": "eq", "field": f, "value": v}`, `neq` | `{:eq, field, value}` | Equality. Strings are case-insensitive. |
| `{"op": "in", "field": f, "values": [...]}`, `not_in` | `{:in, field, list}` | Membership. |
| `{"op": "contains", "field": f, "value": s}` | `{:contains, field, substring}` | Case-insensitive substring. |
| `{"op": "matches", "field": f, "pattern": p}` | `{:matches, field, regex}` | Regex. Add `"flags": "i"` (letters from `imsux`, `""` for none) to fix the flags; without it the pattern is case-insensitive. |
| `{"op": "present", "field": f}`, `blank` | `{:present, field}` | Blank is `nil` or `""`. |
| `{"op": "gte", "field": f, "value": v}`, `gt` / `lt` / `lte` | `{:gte, field, value}` | Comparison. ISO dates compare as dates. |
| `{"op": "between", "field": f, "from": a, "to": b}` | `{:between, field, from, to}` | Either bound may be `null` (open). |
| `{"op": "all", "conditions": [...]}`, `any` / `none` | `{:all, conds}` | Compound. |
| `{"op": "not", "condition": {...}}` | `{:not, cond}` | Negation. |
| `{"op": "pred", "name": n, "args": a}` | `{:pred, name, args}` | Named function passed as `predicates:`, called as `fun.(candidate, args)`. |
| `{"op": "roster", "roster": r, ...}` | `{:roster, name, opts}` | Category-and-date membership. See below. |

A roster condition reads the member from `member_field` (default `member_id`) and the date from `as_of_field` (default `as_of`). The category is a candidate field (`category_field`, default `category`), a literal (`"category": "read"`), or any category (`"category": "*"`). See `RuleMatch.Codec` for the full reference.

A missing field fails every operator that needs a value. `{:eq, field, nil}` does not match a missing key; use `:blank` for that. `false` stored under a present key is a real value (`Map.has_key?/2`, never `||`).

## Rosters

Rosters are named membership tables: a member row, a category column, and effective dates in each cell. A member can be a person, organization, device, location, or any other identified entity. Categories can represent roles, permissions, or groups.

```elixir
book =
  RuleMatch.Roster.new()
  |> RuleMatch.Roster.put(:access_a, "asset_a", "read", effective_on: ~D[2024-08-15])

RuleMatch.Roster.member?(book, :access_a, "asset_a", "read", ~D[2026-06-01])
# => true

rule = RuleMatch.rule("read_access",
  conditions: [{:roster, :access_a, []}],
  outcome: %{allowed: true}
)

RuleMatch.decide([rule],
  %{member_id: "asset_a", category: "read", as_of: ~D[2026-06-01]},
  rosters: book
)
```

In a ruleset file, each roster is a list of entries with `member` and `categories` (or a singular `category`). Use `"categories": ["*"]` for every category. Optional `effective_on` and `terminates_on` dates bound membership; `meta` carries additional data included in matching explanations. In Elixir, pass `:any` as the category argument to `Roster.put/5` for all-category membership.

Membership starts on `effective_on` and ends before `terminates_on`. Member and category strings are trimmed and downcased; roster names retain their case. A specific category cell takes precedence over an all-category cell, even when the specific cell has expired. Each member/category pair holds one cell; inserting it again replaces its dates and metadata.

A cell's own `terminates_on` applies to one member/category pair. A broader restriction, such as shutting down an entire category on a given date, can be a higher-priority rule that overrides an otherwise active membership.

The roster API now uses `member` and `category` terminology. Existing roster JSON must rename `provider` to `member`, `product`/`products` to `category`/`categories`, and `provider_field`/`product_field` to `member_field`/`category_field`. Elixir condition options are now `member:` and `category:`, and explanation maps use `:member` and `:category`. The default candidate fields are now `member_id`, `category`, and `as_of`; map other field names explicitly with `member_field`, `category_field`, and `as_of_field` (or Elixir `member:`, `category:`, and `as_of:`).

## What this is not

Not a Rete network, not a forward-chaining interpreter, and not a rule editor. Rules are only as current as the snapshot you load.

## Running tests locally

Install Elixir 1.18+, a compatible Erlang/OTP installation, and Docker with
Compose v2. PostgreSQL 17 runs in Docker; Mix and the tests run on the host.
The full suite requires PostgreSQL, including the database integration tests.

From the repository root:

```sh
mix deps.get
docker compose up -d --wait
MIX_ENV=test mix rule_match.setup
mix test
```

The service is named `postgres` and binds to `127.0.0.1:5432`. Default username
and password are both `rule_match`. Compose creates `rule_match_dev` and the
bootstrap SQL creates `rule_match_test` when a new named volume is initialized.
Initialization scripts run only for a new volume. The setup task selects
`rule_match_test` under `MIX_ENV=test`, creates the database if necessary, and
installs the library tables. Setup is safe to repeat.

Run a single file or the test beginning at line 13:

```sh
mix test test/ecto_adapter_test.exs
mix test test/ecto_adapter_test.exs:13
```

Initialize the separate development database for interactive work:

```sh
mix rule_match.setup
```

The ordinary test workflow preserves development data. The repository's test
Repo uses Ecto SQL Sandbox; concurrency tests use separate committed connections
and explicit cleanup. Store tests expect the test library tables to start empty;
keep interactive definitions in the development database. This local Repo and
setup tooling are for contributors;
consuming applications provide their own Repo and migrations.

If another PostgreSQL server uses port 5432, pass the same alternate port to
Compose, setup, and tests (the file/line examples accept this override too):

```sh
RULE_MATCH_POSTGRES_PORT=55441 docker compose up -d --wait
RULE_MATCH_POSTGRES_PORT=55441 MIX_ENV=test mix rule_match.setup
RULE_MATCH_POSTGRES_PORT=55441 mix test
RULE_MATCH_POSTGRES_PORT=55441 mix rule_match.setup
```

For an existing server or CI, `RULE_MATCH_DATABASE_URL` overrides the host,
port, credentials, and environment database selection. Use the test database
for tests and the development database for development:

```sh
RULE_MATCH_DATABASE_URL=postgres://rule_match:rule_match@127.0.0.1:55441/rule_match_test MIX_ENV=test mix rule_match.setup
RULE_MATCH_DATABASE_URL=postgres://rule_match:rule_match@127.0.0.1:55441/rule_match_test mix test test/ecto_adapter_test.exs:13
RULE_MATCH_DATABASE_URL=postgres://rule_match:rule_match@127.0.0.1:55441/rule_match_dev mix rule_match.setup
```

Inspect startup or connection problems:

```sh
docker compose ps
docker compose logs postgres
```

Stop PostgreSQL while preserving the named volume and its data:

```sh
docker compose down
```

To explicitly reset local data, the following deletes the named volume and
**both local databases**, then recreates them and the library tables:

```sh
docker compose down -v
docker compose up -d --wait
MIX_ENV=test mix rule_match.setup
mix rule_match.setup
mix test
```

Keep using the same `RULE_MATCH_POSTGRES_PORT` override on Compose, setup, and
test commands if you chose an alternate port. `COMPOSE_PROJECT_NAME` can isolate
a separate Compose project and volume when needed.
