# rule_match

A small Elixir rules engine that looks for a match in a set of candidates.

It is a matcher, not a Rete network and not a forward-chaining interpreter. A candidate is a map of fields. A rule is a named list of conditions plus an outcome. Fields a rule does not mention are wildcards.

Rules are data, not code. A ruleset is a JSON file holding the rules, the rosters they reference, and how to normalize a candidate. The package has no domain knowledge and ships no rules; you supply the ruleset file.

Rosters are optional. Rules can match candidate fields directly without any roster data.

## Install

```elixir
def deps do
  [
    {:rule_match, path: "rule_match"}
  ]
end
```

No runtime dependencies. Requires Elixir 1.18+ for the built-in `JSON` module.

## Rulesets

```elixir
{:ok, ruleset} = RuleMatch.Ruleset.load("rules.json")
RuleMatch.decide(ruleset, %{"organization" => "Acme", "tier" => "STANDARD"})
RuleMatch.Ruleset.save(ruleset, "rules.json")
```

For a configured default and cached file loading, set the path in your application's config:

```elixir
config :rule_match, :ruleset, "/path/to/rules.json"
```

Then load the configured ruleset or an explicit path:

```elixir
ruleset = RuleMatch.ruleset()
RuleMatch.decide(ruleset, %{"organization" => "Acme", "tier" => "STANDARD"})

other_ruleset = RuleMatch.ruleset("other_rules.json")
```

`RuleMatch.ruleset/0,1` caches each file by absolute path and modification time,
reloading on the next call when that time changes. Edits that preserve the
timestamp are not detected. Cache entries stay in memory for the VM's lifetime
and are replaced when reloaded. Missing configuration, unreadable files, and
invalid rulesets raise errors. `RuleMatch.Ruleset.load/1` and `load!/1` always
read the file without caching.

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

Decoding never creates atoms from ops, field names, or values. Outcome keys do become atoms so that `result.access_status` works; outcome values stay JSON values (`"allowed"`, not `:allowed`). Load only ruleset files you trust.

`match/3`, `best/3`, `select/3`, and `decide/3` take either a ruleset or a plain list of `%RuleMatch.Rule{}`. With a ruleset, its rosters join the context and its normalization runs first. `decide/3` returns the winning outcome plus `:rule_id`, `:explanation`, `:priority`, `:specificity`, and `:alternatives` (every other rule that matched).

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

Not a Rete network, not a forward-chaining interpreter, and not a rule editor. Rules are only as current as the file you load.
