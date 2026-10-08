# Ruleset adapters and database persistence

Date: 2026-10-08

Status: Conversational design approved; written spec awaiting review.

## Intent and agreed scope

Applications should be able to load a ruleset from a JSON file or from their
existing Ecto Repo through a shared adapter interface. Database rulesets have a
unique string lookup key, and their individual rules are associated records.
Loading from either source produces the existing `RuleMatch.Ruleset` struct so
the matcher keeps the same behavior.

The user approved regular Ecto dependencies, CRUD functions for rulesets and
rules, two database schemas, JSON data for rosters, and uncached loading. The
existing file cache will be removed. The consuming application supplies and
starts its Repo and runs the library migrations.

The repository will also include Docker Compose configuration for a local
PostgreSQL database used during development and integration testing.

Success means file and database representations produce equivalent matching
results, database edits appear on the next load, and applications can manage
stored rules through validated persistence functions.

## Approach

Ship the adapters, schemas, persistence context, and migrations in this package.
This was selected over optional Ecto support or a separate integration package
because regular dependencies simplify compilation, testing, and consumption.

Add `ecto_sql` and `ecto_evolver` as regular dependencies. PostgreSQL is the
initial supported database, matching EctoEvolver's current support. The
consuming application's PostgreSQL Repo supplies its database driver and
connection configuration; this repository's development and test setup uses
a local Repo and Postgrex, available only in those environments.

Keep these responsibilities separate:

| Component | Responsibility |
| --- | --- |
| `RuleMatch.Adapter` | Contract for loading a runtime ruleset |
| `RuleMatch.Adapters.File` | Read and decode a JSON file |
| `RuleMatch.Adapters.Ecto` | Look up stored records and decode a runtime ruleset |
| `RuleMatch.Schemas.Ruleset` | Ruleset record, association, and changeset |
| `RuleMatch.Schemas.Rule` | Individual rule record and changeset |
| `RuleMatch.Store` | Database queries, CRUD, and write transactions |
| `RuleMatch.Migration` | Versioned migration entry point using EctoEvolver |
| Existing runtime structs and codec | Matching, normalization, and data conversion |

## Loading API and configuration

The adapter behaviour has one callback:

```elixir
@callback load(identifier :: String.t(), opts :: keyword()) ::
            {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
```

The file adapter interprets the identifier as a path. The Ecto adapter
interprets it as an exact, case-sensitive ruleset key.

```elixir
config :rule_match,
  adapter: RuleMatch.Adapters.Ecto,
  repo: MyApp.Repo,
  prefix: "rule_match",
  ruleset: "coverage"

RuleMatch.ruleset()
RuleMatch.ruleset("coverage")
RuleMatch.ruleset("coverage", repo: OtherApp.Repo, prefix: "other_rules")

RuleMatch.Ruleset.load("coverage")
RuleMatch.Ruleset.load!("coverage")
RuleMatch.Ruleset.load("rules.json", adapter: RuleMatch.Adapters.File)
```

`RuleMatch.ruleset/0,1,2` returns a runtime ruleset and raises on a loading
failure. With no identifier it uses the configured `:ruleset` value.
`RuleMatch.Ruleset.load/1,2` returns an ok/error tuple;
`RuleMatch.Ruleset.load!/1,2` raises on error. These entry points use the same
configuration resolution and adapter dispatch.

Per-call options override application configuration. The default adapter is
`RuleMatch.Adapters.File`; the default database prefix is `"rule_match"`.
There is no default Repo. The Ecto adapter requires a Repo; the file adapter
works without one. Identifiers must be nonempty strings.

Without an adapter configuration, existing file-path calls and the existing
`:ruleset` path configuration continue to work. With an Ecto adapter configured,
an explicit file adapter option selects a file path instead of a database key.

Both adapters read their source on every call. Remove the `:persistent_term`
cache and file modification-time lookup from `RuleMatch.ruleset`. A loaded
ruleset is a snapshot; applications reload it to observe later changes.

`Ruleset.save/2` remains an explicit JSON-file export. `from_json/1`,
`to_json/1`, `from_map/1`, `to_map/1`, and the matching APIs retain their roles.
The loader contract does not include writes; database writes belong to Store.

## Database schemas

Tables are `rulesets` and `rules` in the configured PostgreSQL schema prefix.
Ecto schemas use ordinary associations and receive the selected prefix through
Repo operations rather than hard-coding it.

### Ruleset record

| Field | Storage and requirements |
| --- | --- |
| `id` | Generated bigint primary key |
| `key` | Required, nonblank string; unique within the schema prefix |
| `name` | Optional string |
| `version` | Optional string; application ruleset version, independent of migration version |
| `description` | Optional string |
| `normalize` | JSONB object, default `{"downcase": [], "dates": []}` |
| `rosters` | JSONB object in the existing codec format, default `{}` |
| `meta` | JSONB object, default `{}` |
| `inserted_at`, `updated_at` | UTC timestamps with microsecond precision |

The association is `has_many :rules`. The key is a storage lookup identifier;
it does not replace `name` and need not be added to the runtime struct or JSON
file format. Keys retain their spelling and case; whitespace-only keys are
invalid.

### Rule record

| Field | Storage and requirements |
| --- | --- |
| `id` | Generated bigint primary key |
| `ruleset_id` | Required foreign key to `rulesets.id`, with cascading deletion |
| `rule_id` | Required, nonblank string; existing runtime rule identifier |
| `description` | Optional string |
| `priority` | Required integer, default `0`; negative priorities are allowed |
| `position` | Required nonnegative integer; Store appends when omitted on creation |
| `conditions` | Array of JSONB objects in existing condition format, default empty array |
| `outcome` | JSONB object, default `{}` |
| `tags` | Array of strings, default empty array |
| `meta` | JSONB object, default `{}` |
| `inserted_at`, `updated_at` | UTC timestamps with microsecond precision |

The association is `belongs_to :ruleset`. Enforce uniqueness of
`{ruleset_id, rule_id}`. Different rulesets may use the same rule identifier.
Index `{ruleset_id, position, id}` for ordered lookup. Position is not unique:
explicit equal positions are ordered by primary key. Updates and deletes do
not renumber other rules, and gaps are valid.

The generated database ID and `rule_id` are distinct. Conversion to the
existing codec maps `rule_id` to the JSON rule's `"id"` field. Runtime
specificity is computed during loading rather than treated as persisted
authority.

## Persistence API

`RuleMatch.Store` uses the configured Repo and prefix, overridden by per-call
options. It always operates on the database regardless of the configured
loader adapter. Its public functions accept attributes as maps with atom or
string field keys; condition objects and JSON data follow the codec's
string-keyed representation. Identity values are strings.

| Function | Successful result |
| --- | --- |
| `list_rulesets(opts \\ [])` | `{:ok, records}`, ordered by key |
| `fetch_ruleset(key, opts \\ [])` | `{:ok, record}`, with ordered rules loaded |
| `create_ruleset(attrs, opts \\ [])` | `{:ok, record}` |
| `update_ruleset(key, attrs, opts \\ [])` | `{:ok, record}` |
| `delete_ruleset(key, opts \\ [])` | `{:ok, deleted_record}` |
| `list_rules(key, opts \\ [])` | `{:ok, records}`, ordered by position and ID |
| `fetch_rule(key, rule_id, opts \\ [])` | `{:ok, record}` |
| `create_rule(key, attrs, opts \\ [])` | `{:ok, record}` |
| `update_rule(key, rule_id, attrs, opts \\ [])` | `{:ok, record}` |
| `delete_rule(key, rule_id, opts \\ [])` | `{:ok, deleted_record}` |

Ruleset creation produces an empty ruleset. Ruleset updates change its own
attributes, including the key when explicitly supplied; they do not mutate
associated rules. Rule changes use the rule functions. Nested rule input is
rejected with a changeset error rather than silently ignored. Rule updates may
change `rule_id`; all lookups remain scoped to the supplied ruleset key.

The rule's parent is determined by the ruleset key argument. Attempts to
override `ruleset_id` through rule attributes are rejected. Server-managed
primary keys and timestamps are not writable through Store.

Lists return an empty list inside an ok tuple when the collection is empty.
For rule functions, a missing parent ruleset is an error, including listing
rules. Missing rulesets or rules return `{:error, :not_found}`.

## Validation and transaction behavior

Changesets cast scalar fields and JSON-compatible data, validate required
identifiers and nonnegative positions, and reject malformed normalization,
roster, condition, and outcome data. Empty conditions remain valid and retain
their existing catch-all behavior. Normalization lists contain string field
names. Reuse the existing codec and `Ruleset.from_map/1` for semantic validation
where applicable; inspect container shapes before decoding so malformed input
becomes a changeset error rather than an incidental exception.

Add matching database NOT NULL, unique, foreign-key, and position check
constraints. Changesets declare those constraints so ordinary constraint
failures return `{:error, changeset}`. Existing trusted-ruleset semantics for
outcome keys also apply to stored definitions.

Rule creation, update, and deletion lock the parent ruleset row with
`FOR UPDATE` inside a transaction. After acquiring the lock, creation without
an explicit position uses `max(position) + 1`, starting at zero. This prevents
concurrent Store appends from assigning the same default position. Rule
mutation queries include both the parent ID and rule identifier. The same
parent row lock also serializes these operations with ordinary updates or
deletion of the parent record.

Transactions roll back on validation or lookup failures. Public functions
return their documented tuples, without leaking a nested transaction result.
These concurrency guarantees apply to writes made through Store; direct Repo
writes still receive the database's structural constraints.

## Database loading and data flow

Fetch a ruleset and its associated rules with one joined query and association
preload. Use a left join so an empty ruleset loads successfully. Order rules by
position and primary key. One statement provides a consistent database
snapshot of the parent attributes and child definitions.

Assemble the existing string-keyed ruleset map with format `1`, metadata,
normalization, rosters, and the ordered rules. Pass it to `Ruleset.from_map/1`
to decode conditions, normalize roster representation, and compile rules with
their specificity. The stored lookup key and database record IDs are excluded
from that runtime representation.

Guard JSON container shapes before decoding, including data written directly
through Repo. Malformed stored normalization, roster, or rule data returns
`{:error, {:invalid_ruleset, message}}` rather than an incidental shape-related
exception. Share those shape checks with changeset validation where practical.

The file adapter reads the file and calls `Ruleset.from_json/1`. Consequently,
both adapters converge on the same existing decoding and compilation path.

## Errors

- File reads preserve native errors such as `{:error, :enoent}`.
- Invalid JSON and definitions preserve the existing structured decoding errors.
- Missing database records return `{:error, :not_found}`.
- Invalid writes and ordinary database constraint failures return
  `{:error, %Ecto.Changeset{}}`.
- Invalid adapter, identifier, Repo, or prefix configuration returns
  `{:error, {:invalid_config, message}}` from tuple-returning entry points.
- Raising entry points raise `ArgumentError` with the identifier and readable
  reason. Missing configured default identifiers receive a clear configuration
  error.
- Unexpected database failures propagate Ecto or database exceptions. Do not
  turn connection failures into `:not_found` or broadly rescue adapter failures.

## Versioned migrations

Provide `RuleMatch.Migration` using `EctoEvolver`, with default prefix
`"rule_match"`, version module `RuleMatch.Migrations.V01`, and the `rulesets`
table as the tracking object. Ship the up/down SQL in
`priv/rule_match/sql/versions/v01/` and include it in the package artifact.

The initial up migration creates the schema when necessary, both tables, and
their constraints and indexes. Use EctoEvolver's `$SCHEMA$` substitution and
`--SPLIT--` statement separators. The down migration drops the rules table
before the rulesets table; it leaves the PostgreSQL schema itself in place so
unrelated objects in a supplied prefix are preserved.

Applications install the tables through their own Ecto migration:

```elixir
defmodule MyApp.Repo.Migrations.AddRuleMatch do
  use Ecto.Migration

  def up, do: RuleMatch.Migration.up(prefix: "rule_match")
  def down, do: RuleMatch.Migration.down(prefix: "rule_match")
end
```

Migration prefix and query prefix must agree. Migration version tracking is
independent of the ruleset's application-level `version` string. Migrations do
not run automatically when the library starts or a ruleset is loaded.

EctoEvolver reference: <https://github.com/agoodway/ecto_evolver>.

## Local development and test database

Add a root-level `compose.yaml` with one PostgreSQL service. Use an official
PostgreSQL image pinned to an explicit major version and document that version.
The service supplies two databases, `rule_match_dev` and `rule_match_test`,
with local username and password `rule_match`. Development and testing use
separate databases so test cleanup does not affect development data.

Configure `POSTGRES_DB` as `rule_match_dev` and mount a bootstrap SQL file at
`docker/postgres/init.sql` into `/docker-entrypoint-initdb.d/` to create
`rule_match_test` with the same owner when the database volume is initialized.
Use a Compose-managed named volume for persistent PostgreSQL data. Document
that initialization scripts run only for a new volume and that removing the
volume resets both local databases.

Bind the database port to loopback. Default the host port to `5432`, with a
`RULE_MATCH_POSTGRES_PORT` override for machines already running PostgreSQL.
Add a `pg_isready` health check so contributors can wait for database readiness
using `docker compose up -d --wait`.

The repository's development and test Repo configuration uses those local
credentials, the selected host port, and the database appropriate to its Mix
environment. Allow `RULE_MATCH_DATABASE_URL` to override the connection for an
existing PostgreSQL server or CI. Test configuration uses Ecto SQL Sandbox;
concurrency tests use separate committed connections and explicit cleanup
where sandbox sharing would conceal locking behavior.

Provide a documented development/test setup command that starts the local
Repo and runs `RuleMatch.Migration` through Ecto's migrator for the selected
database. Running the tests after setup starts the test Repo through the test
harness. This Repo and setup tooling belong to this repository's dev/test
environments; consuming applications continue to supply their own Repo and
application migrations.

The README includes the complete workflow: starting Compose and waiting for
health, initializing each database's library tables, running the tests,
overriding connection settings, stopping the service, and explicitly resetting
the local volume. Keep Docker bootstrap files outside the library's packaged
migration assets.

## Verification and documentation

Use existing ExUnit coverage for runtime matching and JSON conversion. Add
adapter contract tests, including a small custom test adapter, to verify
configuration resolution, per-call overrides, tuple results, and raising
entry points.

Replace file-cache tests with assertions that every load reads the current
contents, including edits that preserve the modification timestamp. Verify
deleted files and malformed replacements surface errors.

Use a real PostgreSQL test Repo for integration coverage of:

- Migration up, tracked version, repeat up, down, and a custom prefix.
- Both schemas, changeset validation, uniqueness, foreign keys, and cascading
  deletion.
- All Store operations, empty collections, scoped lookups, missing records,
  and rejection of nested rule writes or parent reassignment.
- Rule appending, explicit positions, deterministic ties, and concurrent
  appends through Store using separate database connections.
- A joined load of an empty ruleset and a populated ruleset.
- Fresh loads after parent and rule updates or deletions.
- A representative file/database equivalence case with normalization, nested
  conditions, priorities, order-sensitive ties, rosters, metadata, and outcome
  explanations.
- Invalid persisted definitions producing structured load errors.

Database tests must actually run against PostgreSQL for completion claims;
they must not silently pass by skipping unavailable integration coverage.
The test setup supplies database connection configuration and manages its
test Repo without adding a production Repo to the library.

Validate the Compose configuration with `docker compose config`. Verify the
documented workflow from a fresh Compose volume: the service becomes healthy,
both databases exist, dev/test migrations run, and the PostgreSQL integration
suite passes. Confirm that a test write does not appear in the development
database and that the port and database URL overrides select the intended
connection.

Update the README and module documentation with both loading modes,
configuration and override examples, CRUD return values, migration setup,
prefix requirements, uncached snapshot behavior, and the local Docker Compose
workflow. Replace statements that rules must live in files or that the package
has no runtime dependencies.

## Scope boundaries

This change provides loading, two stored schemas, CRUD, versioned schema
installation, and Docker Compose tooling for local dev/test PostgreSQL.
It does not add caching, a rule editor, a production Repo,
additional database backends, separate roster tables, bulk replacement,
automatic migrations, or a new matching algorithm.
