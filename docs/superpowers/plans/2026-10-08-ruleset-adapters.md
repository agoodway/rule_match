# Ruleset Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load equivalent runtime rulesets from files or PostgreSQL, provide validated database CRUD, and make local dev/test PostgreSQL and test execution reproducible.

**Architecture:** A loader behaviour selects an uncached file or Ecto adapter using application configuration and per-call overrides. Separate Ecto records and a Store context handle persistence; both loaders converge on the existing runtime codec. EctoEvolver ships versioned SQL, while Compose and a local-only Repo support development and tests.

**Tech Stack:** Elixir 1.18+, ExUnit, Ecto SQL, EctoEvolver, Postgrex in dev/test, PostgreSQL 17, Docker Compose, built-in Elixir JSON.

**Spec:** [Approved design](../specs/2026-10-08-ruleset-adapters-design.md). Read the complete spec before executing this plan.

## Global Constraints

- Elixir 1.18+; matching and normalization behavior remain governed by existing runtime structs and codec.
- Regular dependencies: `ecto_sql`, `ecto_evolver`; Postgrex and the local Repo are available only in dev/test.
- File remains the default adapter. Neither adapter caches. Remove the existing file cache.
- Default PostgreSQL prefix: `"rule_match"`; application Repo is configurable, with no production Repo supplied by this package.
- Database keys are exact, case-sensitive, nonblank strings; rule identifiers are unique within their ruleset.
- Tables: `rulesets`, `rules`; generated bigint IDs; rule foreign key cascades on parent deletion.
- Conditions use a PostgreSQL JSONB array; outcome, normalization, rosters, and metadata use JSONB objects. Rule tags are a string array.
- Rules load by position, then primary key. Equal positions and gaps are valid. Specificity is recomputed.
- `RuleMatch.Store` returns ok/error tuples; missing records use `{:error, :not_found}`; invalid writes return changesets.
- `RuleMatch.ruleset` and `Ruleset.load!` raise on expected loading failures; unexpected adapter/database exceptions propagate.
- Rule writes lock the parent row in a transaction; omitted creation positions append from zero.
- Compose service: `postgres`; databases: `rule_match_dev`, `rule_match_test`; credentials: `rule_match` / `rule_match`.
- Loopback port defaults to `5432`; overrides: `RULE_MATCH_POSTGRES_PORT`, `RULE_MATCH_DATABASE_URL`.
- README section: `Running tests locally`; setup task: `mix rule_match.setup`; the full suite runs against real PostgreSQL.

## Review Focus

1. Mixed top-level atom/string attributes and unknown field names must not create atoms or ambiguously replace a field; pin this in Task 4.
2. JSON `false`, `nil`, nested compound conditions, and unflagged invalid regex patterns must survive valid writes or produce validation errors; pin this in Tasks 4 and 6.
3. Quoted schema prefixes and identical keys in different prefixes must stay isolated, and rollback must preserve unrelated objects; pin this in Tasks 3 and 5.
4. Concurrent parent deletion/key renaming and rule writes must remain scoped and return ordinary results rather than partial writes; pin this in Task 5.
5. Per-call configuration overrides and database URL precedence must select the intended connection; adapter exceptions must retain their meaning; pin this in Tasks 1, 2, and 6.

## File map

| Files | Responsibility |
| --- | --- |
| `compose.yaml`, `docker/postgres/init.sql` | Local PostgreSQL service and second database initialization |
| `config/config.exs`, `config/runtime.exs` | Dev/test connection and pool configuration |
| `dev/support/repo.ex`, `dev/support/postgres_types.ex` | Local Repo and Postgrex types using built-in JSON |
| `dev/support/migration.ex`, `dev/support/setup.ex`, `dev/support/unboxed_repo.ex` | Local migration wrapper, idempotent setup, and regular migration/concurrency connections |
| `lib/mix/tasks/rule_match.setup.ex` | Dev/test-only setup command |
| `lib/rule_match/adapter.ex`, `lib/rule_match/config.ex` | Loader contract and shared configuration resolution |
| `lib/rule_match/adapters/file.ex`, `lib/rule_match/adapters/ecto.ex` | Source-specific loading |
| `lib/rule_match/migration.ex`, `lib/rule_match/migrations/v01.ex` | EctoEvolver entry point and first version |
| `priv/rule_match/sql/versions/v01/v01_up.sql`, `priv/rule_match/sql/versions/v01/v01_down.sql` | Tables, constraints, indexes, rollback |
| `lib/rule_match/stored_data.ex` | Shared JSON shape and semantic validation |
| `lib/rule_match/schemas/ruleset.ex`, `lib/rule_match/schemas/rule.ex` | Stored record fields, associations, changesets |
| `lib/rule_match/store.ex` | Scoped queries, CRUD, parent locking, transaction results |
| `test/support/data_case.ex` | Sandbox ownership for ordinary integration tests |
| `test/local_database_test.exs`, `test/adapter_test.exs`, `test/migration_test.exs` | Infrastructure, dispatch, migrations |
| `test/schema_test.exs`, `test/store_test.exs`, `test/store_concurrency_test.exs`, `test/ecto_adapter_test.exs` | Validation, CRUD, concurrency, loader equivalence |
| Existing `lib/rule_match.ex`, `lib/rule_match/ruleset.ex`, tests, `mix.exs`, `mix.lock`, README | Public loader integration, dependency/build setup, regression coverage, documentation |

## Execution prerequisites

The initial checkout is clean on `main`. Create or select an isolated worktree
using the worktree skill at execution time. Do not reset or delete existing
Compose volumes. Use a unique Compose project for verification against a fresh
volume, then remove only that project's resources.

Elixir 1.19.4/OTP 28 and Docker Compose are installed in the current workspace.
The initial `docker info` call was denied access to `/var/run/docker.sock`.
Resolve access through an available authorized Docker context before the
Compose checks. If that remains unavailable, report the exact limitation and
do not claim database verification succeeded.

## Task 1: Local PostgreSQL and dev/test connection setup

**Files:** Create the Compose, bootstrap SQL, config, Repo/types files in the file map and `test/local_database_test.exs`; modify `mix.exs`, `mix.lock`, `test/test_helper.exs`.

**Interfaces:**
- Produces `RuleMatch.Dev.Repo`, an Ecto PostgreSQL Repo started explicitly by tooling/tests.
- Produces `RuleMatch.Dev.PostgresTypes` via `Postgrex.Types.define/3`, with `json: JSON`.
- Produces environment-aware Repo configuration used by later setup and integration tasks.

- [ ] **Step 1: Write connection tests.** Name the tests `test database matches the selected Repo configuration` and `JSONB arrays round-trip with built-in JSON`. Start the Repo in `test_helper.exs` and run connection-only checks with `Sandbox.unboxed_run/2`:

  ```elixir
  assert Repo.query!("SELECT current_database()").rows == [[Repo.config()[:database]]]
  value = %{"flag" => false, "nested" => [nil, %{"op" => "blank", "field" => "x"}]}
  assert Repo.query!("SELECT $1::jsonb", [value]).rows == [[value]]
  assert Repo.query!("SELECT $1::jsonb[]", [[value]]).rows == [[[value]]]
  ```

- [ ] **Step 2: Run the new test and record its failure.** `mix test test/local_database_test.exs` must fail because the local Repo/support does not exist. A connection failure caused by inaccessible Docker is a separate prerequisite, not this expected red result.
- [ ] **Step 3: Implement connection infrastructure.** Add `{:ecto_sql, "~> 3.13"}`, `{:ecto_evolver, "~> 0.1.0"}`, and `{:postgrex, "~> 0.22.0", only: [:dev, :test]}`. Keep `lib` as the production compile path; add `dev/support` for dev/test and `test/support` for test. Define the Repo/types modules only in dev support. Configure runtime connections only for dev/test: URL override first, otherwise loopback/default port and `rule_match_#{config_env()}`. Configure test Sandbox/manual ownership and pool size 10. Do not start a local Repo in the library application supervision tree.
- [ ] **Step 4: Implement Compose.** Use `postgres:17`, named volume `postgres_data` mounted at `/var/lib/postgresql/data`, a read-only init SQL mount, and `127.0.0.1:${RULE_MATCH_POSTGRES_PORT:-5432}:5432`. Set the approved credentials and `POSTGRES_DB=rule_match_dev`; bootstrap creates `rule_match_test` owned by `rule_match`. Health check uses TCP `pg_isready` against the dev database so readiness follows entrypoint initialization; use interval 2s, timeout 5s, retries 30.
- [ ] **Step 5: Verify defaults and overrides.** Run `mix deps.get`, `docker compose config`, `docker compose up -d --wait`, and the connection tests. With a separate Compose project and unused host port, rerun the tests using `RULE_MATCH_POSTGRES_PORT`; then use `RULE_MATCH_DATABASE_URL` pointing to that same test database while setting an intentionally different port override. Both test runs must connect successfully, proving URL precedence. Check `SELECT datname FROM pg_database` includes both approved databases. Preserve these command results for final verification.
- [ ] **Step 6: Commit this independently usable infrastructure.** Stage only Task 1 files; commit `build: add local PostgreSQL development and test setup`.

## Task 2: Adapter dispatch and uncached file loading

**Files:** Create `lib/rule_match/adapter.ex`, `lib/rule_match/config.ex`, `lib/rule_match/adapters/file.ex`, and `test/adapter_test.exs`; modify `lib/rule_match.ex`, `lib/rule_match/ruleset.ex`, `test/configured_ruleset_test.exs`, `test/ruleset_edge_test.exs`.

**Interfaces:**
- Produces `RuleMatch.Adapter.load/2` callback returning `{:ok, Ruleset.t()} | {:error, term()}`.
- Produces `RuleMatch.Config.loader(opts)` returning `{:ok, resolved_keyword_opts} | {:error, {:invalid_config, message}}`; preserve extra caller options for custom adapters.
- Produces `RuleMatch.Config.store(opts)` returning `{:ok, {repo, prefix}} | {:error, {:invalid_config, message}}`, validating a Repo module and nonblank prefix for later Store use.
- Produces `RuleMatch.ruleset/0,1,2`, `Ruleset.load/1,2`, `Ruleset.load!/1,2`, and `RuleMatch.Adapters.File.load/2` with the approved signatures.

- [ ] **Step 1: Replace cache assertions with fresh-read assertions and add dispatch tests.** Each application-config test saves/restores all changed keys and runs with `async: false`. A test adapter defined in `adapter_test.exs` returns `Ruleset.new(name: identifier)` and reports received options. A throwing adapter raises `RuntimeError, "adapter failure"`.

  ```elixir
  assert {:ok, %{name: "coverage"}} = Ruleset.load("coverage", adapter: TestAdapter)
  assert RuleMatch.ruleset("override", adapter: TestAdapter).name == "override"
  assert {:error, {:invalid_config, _}} = Ruleset.load("x", adapter: String)
  assert {:error, {:invalid_config, _}} = Ruleset.load(nil)
  assert_raise RuntimeError, "adapter failure", fn ->
    Ruleset.load("x", adapter: ThrowingAdapter)
  end
  ```

  Also assert configured-default dispatch, per-call option precedence, unknown caller options reaching the custom adapter, missing Repo/prefix errors from `Config.store/1`, and no atom creation from invalid configuration strings.
- [ ] **Step 2: Run targeted tests to establish red.** `mix test test/adapter_test.exs test/configured_ruleset_test.exs`; fresh reads with preserved timestamps must fail under the old cache, and adapter calls must fail under the old API.
- [ ] **Step 3: Implement dispatch and configuration.** Merge per-call options over application keys, default the adapter to File, and validate it exports `load/2`. Ecto-specific configuration resolution validates Repo modules without requiring them to be running; genuine connection exceptions must remain runtime exceptions. File ignores database-specific settings. Validate identifiers without making atoms from input. `RuleMatch.ruleset/0` resolves the configured identifier; all raising paths format expected errors as `ArgumentError`. Delegate File loading to `File.read/1` and `Ruleset.from_json/1`, avoiding recursion through the new dispatcher. Remove `:persistent_term`, stat lookups, and cache cleanup in tests. Preserve `Ruleset.save/2` as file export.
- [ ] **Step 4: Verify file compatibility and errors.** Run the adapter, configured ruleset, existing ruleset, and edge tests. Assert an edited file with unchanged mtime loads its new name; a malformed replacement returns a decoding error; a deleted file returns `:enoent` and raising wrappers now raise `ArgumentError`, rather than the former stat-induced `File.Error`. Add readable formatting for `:not_found` and `{:invalid_config, message}`. Existing JSON round trips and matching tests must pass.
- [ ] **Step 5: Commit.** Stage Task 2 files; commit `feat: add ruleset loader adapters and remove file caching`.

## Task 3: Versioned tables and repeatable local setup

**Files:** Create `lib/rule_match/migration.ex`, `lib/rule_match/migrations/v01.ex`, both version SQL files, `dev/support/migration.ex`, `dev/support/setup.ex`, `lib/mix/tasks/rule_match.setup.ex`, `dev/support/unboxed_repo.ex`, and `test/migration_test.exs`; modify `mix.exs` packaging, `config/config.exs`, `config/runtime.exs`, and `test/test_helper.exs`.

**Interfaces:**
- Produces `RuleMatch.Migration.up/1`, `down/1`, `current_version/0`, and `migrated_version/1` through EctoEvolver; migration functions execute within Ecto migration context.
- Produces `RuleMatch.Dev.Migration`, an Ecto migration wrapper passing `prefix() || "rule_match"` to the library migration.
- Produces `RuleMatch.Dev.Setup.run/0 :: :ok` and `Mix.Tasks.RuleMatch.Setup.run/1`, for `mix rule_match.setup` in dev/test.
- Produces `RuleMatch.Dev.UnboxedRepo`, with the same target database/types as the local Repo and `DBConnection.ConnectionPool` instead of Sandbox; use it for setup, migrations, and true concurrent transactions.

- [ ] **Step 1: Write migration/setup integration tests.** Use `async: false`, UnboxedRepo, and unique temporary schema prefixes created before invoking `Ecto.Migrator`. Read migration version via `EctoEvolver.Adapters.Postgres.get_version(UnboxedRepo, prefix, {:table, "rulesets"})`; calling the generated `migrated_version/1` outside migration context is invalid. Test `version one creates the tables and tracks upgrades`, `repeat setup is safe`, and `quoted-prefix rollback preserves unrelated tables`.

  ```elixir
  assert RuleMatch.Migration.current_version() == 1
  assert Ecto.Migrator.up(UnboxedRepo, 1, RuleMatch.Dev.Migration, prefix: prefix) == :ok
  assert EctoEvolver.Adapters.Postgres.get_version(UnboxedRepo, prefix, {:table, "rulesets"}) == 1
  assert Ecto.Migrator.up(UnboxedRepo, 1, RuleMatch.Dev.Migration, prefix: prefix) == :already_up
  assert Ecto.Migrator.up(UnboxedRepo, 2, RuleMatch.Dev.Migration, prefix: prefix) == :ok
  ```

  Use a prefix containing a hyphen and uppercase letters. After `Ecto.Migrator.down/4`, assert the two library tables are absent, the schema and a sentinel table still exist, and tracked library version is zero. Register cleanup only for the unique test prefix. The second migration timestamp above deliberately exercises EctoEvolver's already-migrated path inside a new wrapper invocation.
- [ ] **Step 2: Run to establish red.** `mix test test/migration_test.exs` must fail because the migration/setup modules do not exist. Do not use Sandbox for these tests; the Ecto migrator needs independent connections.
- [ ] **Step 3: Implement the version modules and SQL.** Configure EctoEvolver with `otp_app: :rule_match`, `default_prefix: "rule_match"`, tracking table `rulesets`, and `[RuleMatch.Migrations.V01]`. V01 uses version `"01"` and SQL path `"rule_match/sql/versions"`. Implement all fields/defaults from the spec: BIGSERIAL IDs, UTC microsecond timestamps, TEXT identifiers, JSONB objects, JSONB[] conditions, TEXT[] tags, NOT NULL fields, a nonnegative position check, cascading FK, unique key index, composite unique rule index, and ordered lookup index. Name constraints `rulesets_key_index`, `rules_ruleset_id_rule_id_index`, `rules_ruleset_id_fkey`, and `rules_position_nonnegative`. Use `$SCHEMA$` and `--SPLIT--`; down drops only the two tables, children first.
- [ ] **Step 4: Implement setup and test connections.** The local setup task checks dev/test before dynamically invoking local-only helpers, starts required applications, invokes adapter `storage_up` and accepts `:already_up`, then uses `Ecto.Migrator.with_repo/3` on `RuleMatch.Dev.UnboxedRepo` and `Ecto.Migrator.up/4` for migration timestamp `1`. Configure both local Repos with the same connection/type options; UnboxedRepo always uses a regular pool, including under `MIX_ENV=test`. Treat `:ok` and `:already_up` as success. Raise a clear Mix error in production or on connection failure. Start UnboxedRepo explicitly in the test harness; it must not own a Sandbox connection or run migrations automatically. Dynamic helper invocation keeps production compilation independent of absent local modules.
- [ ] **Step 5: Verify installed and packaged migrations.** Run `mix rule_match.setup`, `MIX_ENV=test mix rule_match.setup` twice, migration tests, and existing tests. Query tables/constraints in both databases. Set package files explicitly to include `lib`, `priv/rule_match`, `mix.exs`, `.formatter.exs`, README, and LICENSE, excluding `dev`, `docker`, Compose, and test support. Verify SQL files are present in a locally built package archive. No publication is part of this task.
- [ ] **Step 6: Commit.** Stage Task 3 files; commit `feat: ship versioned ruleset migrations and local setup task`.

## Task 4: Stored schemas and shared definition validation

**Files:** Create `lib/rule_match/stored_data.ex`, `lib/rule_match/schemas/ruleset.ex`, `lib/rule_match/schemas/rule.ex`, `test/support/data_case.ex`, and `test/schema_test.exs`.

**Interfaces:**
- Produces Ecto schemas `RuleMatch.Schemas.Ruleset` / `RuleMatch.Schemas.Rule` with fields and associations from the spec and `changeset(record, attrs) :: Ecto.Changeset.t()`.
- Produces `RuleMatch.StoredData.normalize_attrs(map) :: {:ok, string_keyed_map} | {:error, message}` for top-level field keys; nested JSON remains string-keyed.
- Produces `RuleMatch.StoredData.validate_ruleset(map)` and `validate_rule(map)`, each returning `:ok | {:error, {field_atom, message}}` for existing JSON-format maps. Field atoms come from a fixed internal set, never user input.
- Produces `RuleMatch.DataCase`, owning a Sandbox transaction per ordinary integration test and supplying `repo: RuleMatch.Dev.Repo`, `prefix: "rule_match"`. Consumers default to `async: false`; enable asynchronous cases only with unique fixture identities and no global configuration mutations.

- [ ] **Step 1: Write schema/validation tests.** Use table-driven cases and explicit field assertions. Valid rule tests initialize the record with trusted `ruleset_id` and `position` in the struct; user attributes must not set the parent. Include the following assertions:

  ```elixir
  assert RulesetRecord.changeset(%RulesetRecord{}, %{key: "coverage"}).valid?
  refute RulesetRecord.changeset(%RulesetRecord{}, %{key: " "}).valid?
  refute RulesetRecord.changeset(%RulesetRecord{}, %{key: "x", rules: []}).valid?
  assert RuleRecord.changeset(record, %{rule_id: "catch_all", conditions: []}).valid?
  refute RuleRecord.changeset(record, %{rule_id: "x", position: -1}).valid?
  refute RuleRecord.changeset(record, %{rule_id: "x", ruleset_id: 99}).valid?
  assert StoredData.validate_rule(%{"id" => "x", "conditions" => [], "outcome" => %{"flag" => false}}) == :ok
  ```

  Add named tests for normalization lists with nonstrings, explicit null objects, malformed roster dates/products, unknown condition ops, invalid compound children, invalid flagged and unflagged regexes, nonobject outcomes, non-JSON metadata, and missing identifiers. For mixed attributes, accept distinct atom/string field keys after normalization; reject conflicting duplicate keys with a changeset error. Unknown dynamic attribute names must not become atoms. Keys/rule IDs preserve case and spelling; whitespace-only identifiers fail. Server-managed attributes must not change generated IDs/timestamps.
- [ ] **Step 2: Run to establish red.** `mix test test/schema_test.exs` must fail for missing schema/validation modules, with the test database already prepared through the setup task.
- [ ] **Step 3: Implement JSON validation and changesets.** Validate complete candidate field values including unchanged defaults on update. Guard JSON container types recursively before using `Codec.rule_from_map/1`, `Codec.rosters_from_map/1`, or `Ruleset.from_map/1`. Validate unflagged regex strings with `Regex.compile/1`, since their codec representation stays a string. Reject unencodable values as validation errors; preserve JSON booleans/nulls. Schema changesets cast a fixed field list, attach semantic errors to the corresponding field, and translate constraint failures using the names from Task 3. Do not hard-code schema prefixes or persist specificity as authority.
- [ ] **Step 4: Test live constraints and associations.** In separate Sandbox-owned tests insert through Repo and assert duplicate ruleset keys and duplicate `{ruleset_id, rule_id}` produce changeset errors, while another ruleset can reuse a rule ID. Assert a missing parent triggers the FK constraint and deleting a parent removes its rules. Since a constraint error aborts the current PostgreSQL transaction, isolate each failing write in its own test or a savepoint; subsequent queries must not use an aborted sandbox transaction. Confirm typed JSONB[] conditions and UTC timestamps round-trip. Run schema tests and the existing codec/ruleset tests.
- [ ] **Step 5: Commit.** Stage Task 4 files; commit `feat: add stored ruleset and rule schemas with validation`.

## Task 5: Scoped CRUD, ordering, and transactional rule writes

**Files:** Create `lib/rule_match/store.ex`, `test/store_test.exs`, and `test/store_concurrency_test.exs`.

**Interfaces:**
- Consumes `Config.store/1`, both schema changesets, and migration-installed tables.
- Produces exactly the ten Store functions and return shapes in the spec's Persistence API table. All accept a final `opts \\ []`; mutations return stored/deleted Ecto records and errors return changesets, `:not_found`, or invalid configuration.
- `fetch_ruleset(key, opts)` produces a parent with ordered rules through one left-joined query, shared with the Ecto adapter in Task 6.

- [ ] **Step 1: Write CRUD and query tests.** Ordinary cases use DataCase. Name the main test `CRUD preserves scoped identities and ordered rules` and exercise every public function:

  ```elixir
  assert {:ok, []} = Store.list_rulesets(opts)
  assert {:ok, parent} = Store.create_ruleset(%{key: "coverage"}, opts)
  assert {:ok, %{rules: []}} = Store.fetch_ruleset("coverage", opts)
  assert {:ok, first} = Store.create_rule("coverage", %{rule_id: "first"}, opts)
  assert first.position == 0
  assert {:ok, second} = Store.create_rule("coverage", %{rule_id: "second"}, opts)
  assert second.position == 1
  assert {:ok, [^first, ^second]} = Store.list_rules("coverage", opts)
  assert {:ok, ^second} = Store.fetch_rule("coverage", "second", opts)
  ```

  Assert updates/renames use the new lookup key/ID, deleted identities return `:not_found`, metadata-only parent updates preserve rules, and invalid writes leave stored data intact. Test explicit equal positions by primary-key order, negative priorities, gaps after deletion, all empty/missing-parent list cases, scoped duplicate rule IDs, and invalid options. Verify nested rules and parent reassignment produce errors rather than silent mutation.
- [ ] **Step 2: Add isolation and concurrent-write tests.** Use UnboxedRepo, `async: false`, committed fixtures, unique keys, and explicit cleanup. Start ten tasks behind a message barrier, each appending a distinct rule through Store; assert every result is ok and final positions are exactly `0..9`, with all ten IDs present. For parent deletion and key renaming, hold the parent lock in a transaction, start a rule write using the old key, then commit the delete/rename; assert the waiting write returns `{:error, :not_found}`, with no orphaned or wrong-parent write. Use bounded message waits, not shared Sandbox ownership. Test two migrated prefixes holding the same key and rule ID; updating/deleting one must not alter the other.
- [ ] **Step 3: Run to establish red.** `mix test test/store_test.exs test/store_concurrency_test.exs` must fail because Store is missing.
- [ ] **Step 4: Implement Store.** Resolve Repo/prefix once per public call. Scope all queries by prefix, parent key, and rule ID as applicable. Parent listing orders by key. Parent fetch left-joins and preloads child rules ordered by position/ID; do not limit joined rows and truncate the preload. Ruleset mutations cast only parent attributes. Rule mutations acquire the parent with `FOR UPDATE` inside `repo.transaction/1`; omitted positions use max plus one after locking. Initialize trusted parent/position on the rule struct before changeset casting. Roll back expected failures with their reason and unwrap transaction results to the documented tuple. Unexpected database exceptions propagate. No bulk replacement or automatic renumbering.
- [ ] **Step 5: Verify all CRUD and concurrency assertions.** Run both test files plus schema/migration tests. Ensure same-key cross-prefix assertions use real migrated prefixes. Rejected writes must leave later valid writes usable; no transaction wrapper may leak `{:ok, {:ok, record}}`. Each unboxed test cleans only its own fixtures/prefixes, including on failure.
- [ ] **Step 6: Commit.** Stage Task 5 files; commit `feat: add ruleset and rule database CRUD`.

## Task 6: Ecto adapter and equivalent runtime rulesets

**Files:** Create `lib/rule_match/adapters/ecto.ex` and `test/ecto_adapter_test.exs`.

**Interfaces:**
- Consumes `Store.fetch_ruleset/2`, `StoredData.validate_ruleset/1`, and `Ruleset.from_map/1`.
- Produces `RuleMatch.Adapters.Ecto.load(key, opts) :: {:ok, RuleMatch.Ruleset.t()} | {:error, term()}` implementing the loader behaviour.
- Converts stored fields to the existing JSON map privately within the adapter; no additional public conversion API.

- [ ] **Step 1: Write loader equivalence and freshness tests.** Build one JSON-format fixture with name/version/description, metadata, payer downcasing, date normalization, roster participation, nested conditions, and two rules tied on priority/specificity with different outcomes. Decode/write it using existing file APIs. Persist the parent through `create_ruleset/2`; enumerate its rules in source order and use `create_rule/3`, mapping each JSON `"id"` to stored `"rule_id"`. Use fixed string-key mappings, not dynamic atom creation.

  ```elixir
  assert {:ok, from_file} = Ruleset.load(path, adapter: RuleMatch.Adapters.File)
  assert {:ok, from_db} = Ruleset.load("coverage", Keyword.put(opts, :adapter, RuleMatch.Adapters.Ecto))
  assert Ruleset.to_map(from_db) == Ruleset.to_map(from_file)
  assert RuleMatch.decide(from_db, candidate) == RuleMatch.decide(from_file, candidate)
  assert Enum.map(from_db.rules, & &1.id) == Enum.map(from_file.rules, & &1.id)
  assert {:error, :not_found} = Ruleset.load("missing", ecto_opts)
  ```

  Name additional tests `empty rulesets load through the left join`, `edits and deletions are visible on the next load`, `malformed stored JSON returns a decoding error`, and `unmigrated prefixes propagate database errors`. Change parent attributes and individual rule outcomes between loads; assert the new values appear and the old runtime struct remains its earlier snapshot. Delete rules and the parent and assert the next load reflects each change. Directly corrupt JSON through Repo: unknown condition op, invalid normalization list, and JSONB `null` object; each must yield `{:error, {:invalid_ruleset, message}}`.
- [ ] **Step 2: Add query-count and configuration assertions.** Capture only this Repo's query telemetry around one load and assert exactly one SELECT. Assert no extra queries during later `RuleMatch.decide/3` calls. Configure the Ecto adapter/default key and verify `RuleMatch.ruleset/0`; override it with File and verify a path loads. For an unmigrated but valid prefix, assert `Postgrex.Error` propagates, distinguishing that failure from a missing key in migrated tables. Preserve explicit JSON false/null values and correct `rule_id` outcomes.
- [ ] **Step 3: Run to establish red.** `mix test test/ecto_adapter_test.exs` must fail because the Ecto adapter does not exist.
- [ ] **Step 4: Implement the Ecto loader.** Fetch the joined stored record through Store, assemble format `1` with all parent JSON fields and ordered child rule fields, and map child `rule_id` to JSON `"id"`. Exclude database IDs, timestamps, positions, and the storage key from runtime JSON. Run shared shape/semantic validation before `Ruleset.from_map/1`; convert shared validation errors to `{:invalid_ruleset, message}`. Allow the existing decoder/compiler to compute specificity and roster/date representation. Propagate Store/config errors and unexpected exceptions without blanket rescue. Do not add cache state.
- [ ] **Step 5: Verify loader integration.** Run Ecto adapter, adapter dispatch, Store, and existing engine/ruleset tests. Assert matching outcomes, explanations, alternatives, metadata, roster dates, and tie winners agree between file and database sources. Verify the joined preload contains every associated rule rather than the first joined row alone.
- [ ] **Step 6: Commit.** Stage Task 6 files; commit `feat: load runtime rulesets from the Ecto store`.

## Task 7: README guide and complete verification

**Files:** Modify `README.md`, `lib/rule_match.ex`, `lib/rule_match/ruleset.ex`, and documentation on new public modules; update `.formatter.exs` to include `dev/support` alongside existing source/config/test paths if necessary.

**Interfaces:**
- Documents all approved loader/Store APIs and the existing runtime return types.
- Produces a verified `Running tests locally` guide using the implemented Compose service, setup task, and real test paths/line numbers.

- [ ] **Step 1: Update documentation.** Replace file-only, dependency-free, and cached-loading descriptions. Document configured File/Ecto loading and per-call overrides, application Repo setup, prefix agreement, EctoEvolver host migrations, all ten CRUD signatures/results, JSON attribute shape, ordering/ties, and uncached snapshots. Explain that `Ruleset.save/2` exports a file. Include one complete persistence example from creating a parent/rule to loading and deciding.
- [ ] **Step 2: Write the local test guide with exact commands.** State Elixir 1.18+/compatible OTP and Docker Compose prerequisites, PostgreSQL 17, host-run Mix, default credentials/database names, and the default sequence:

  ```sh
  mix deps.get
  docker compose up -d --wait
  MIX_ENV=test mix rule_match.setup
  mix test
  ```

  Add one-file and one-test examples using a real final test line, `mix rule_match.setup` for the dev database, port/URL overrides, `docker compose ps`, `docker compose logs postgres`, `docker compose down`, and the explicit data-deleting `down -v` reset followed by recreation. Show the same alternate port passed to Compose, setup, and tests. State that a new volume triggers bootstrap SQL and that the full suite requires PostgreSQL.
- [ ] **Step 3: Run the README workflow on a fresh isolated Compose volume.** Use a unique `COMPOSE_PROJECT_NAME` and an unused host port via `RULE_MATCH_POSTGRES_PORT`; do not delete an existing project volume. Follow the guide's dependency/start/setup/test commands in order. Verify both databases exist, setup succeeds twice, and all tests pass with no skipped integration coverage. Initialize the dev database and use a uniquely named sentinel row to show test writes do not affect it. Clean only that verification sentinel. Verify port and URL examples against this isolated database.
- [ ] **Step 4: Verify production compilation, formatting, and package contents.** Run `mix format --check-formatted`, `mix test`, `MIX_ENV=prod mix compile --warnings-as-errors`, `mix hex.build`, and `git diff --check`. The production build must succeed without Postgrex or dev/test Repo/types modules. Inspect the built archive for the two version SQL files and absence of Docker/dev/test support. A local archive build is not publication. If formatting changes files, rerun the formatter check and tests appropriate to those changes.
- [ ] **Step 5: Review the full implementation against the spec.** Confirm no hidden cache, production Repo, automatic migrations, additional schema tables, nested CRUD replacement, or swallowed database exceptions. Review transaction behavior, joined preload cardinality, constraints/changeset names, and every Review Focus test. Use the execution method chosen by the user for the required code review; address actionable findings and repeat only affected checks before completion.
- [ ] **Step 6: Commit and hand off the verified result.** Stage Task 7 files; commit `docs: explain database rulesets and local Compose testing`. Report actual test/build results, the README guide, and any material limitations. Stop the isolated verification Compose project and remove its newly created disposable volume; preserve other local projects and volumes. Publication, merge, and deployment are outside this plan.

## Self-review coverage

| Spec requirement | Owning tasks |
| --- | --- |
| Adapter contract, configuration, overrides, tuple/bang APIs | 2, 6 |
| Uncached file/database behavior and file export | 2, 6, 7 |
| Two schemas, JSON storage, associations, identifiers, ordering | 3, 4, 5 |
| CRUD, changesets, constraints, no nested writes | 4, 5 |
| Parent locking, concurrent appends, scoped mutation | 5 |
| Single-query snapshots and common runtime decoding | 5, 6 |
| Error distinctions and malformed persisted definitions | 2, 4, 5, 6 |
| Versioned SQL, prefix isolation, rollback, package assets | 3, 5, 7 |
| Compose dev/test databases, overrides, local setup, Sandbox | 1, 3, 4, 5 |
| README test guide and executed fresh-volume workflow | 7 |

## Implementation references

- [EctoEvolver source and usage](https://github.com/agoodway/ecto_evolver): version modules, tracking table, SQL substitution.
- [Ecto Migrator](https://hexdocs.pm/ecto_sql/Ecto.Migrator.html): wrapper migration execution and independent migration connections.
- [Postgrex types](https://github.com/elixir-ecto/postgrex/blob/v0.22.4/lib/postgrex/types.ex): `json: JSON` on a local type module, avoiding global application changes.
- [Official PostgreSQL image](https://github.com/docker-library/docs/blob/master/postgres/README.md): bootstrap scripts, database environment settings, volume initialization.

The plan is ready for user review and execution-method selection. Implementation
begins after that review; design approval alone does not authorize skipping the
plan handoff required by the invoked skills.
