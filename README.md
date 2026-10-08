# rule_match

A small Elixir rules engine that looks for a match in a set of candidates.

It is a matcher, not a Rete network and not a forward-chaining interpreter. A candidate is a map of fields. A rule is a named list of conditions plus an outcome. Fields a rule does not mention are wildcards.

Rules are data, not code. A ruleset is a JSON file holding the rules, the rosters they reference, and how to normalize a candidate. The package has no domain knowledge and ships no rules; you supply the ruleset file.

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
RuleMatch.decide(ruleset, %{"payer" => "Acme", "plan_type" => "PPO"})
RuleMatch.Ruleset.save(ruleset, "rules.json")
```

For a configured default and cached file loading, set the path in your application's config:

```elixir
config :rule_match, :ruleset, "/path/to/rules.json"
```

Then load the configured ruleset or an explicit path:

```elixir
ruleset = RuleMatch.ruleset()
RuleMatch.decide(ruleset, %{"payer" => "Acme", "plan_type" => "PPO"})

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
  "name": "coverage",
  "version": "2026-01-01",
  "normalize": {"downcase": ["payer", "plan_type"], "dates": ["date_of_service"]},
  "rules": [
    {
      "id": "acme_ppo",
      "priority": 10,
      "conditions": [
        {"op": "eq", "field": "payer", "value": "acme"},
        {"op": "in", "field": "plan_type", "values": ["ppo", "epo"]}
      ],
      "outcome": {"network_status": "in_network"}
    }
  ],
  "rosters": {
    "network_a": [{"provider": "provider_a", "products": ["basic", "plus"], "effective_on": "2024-08-15"}]
  }
}
```

`normalize.downcase` fields are trimmed and downcased, and `normalize.dates` fields parsed from ISO strings, before matching. String keys that name a known atom become atom keys.

Decoding never creates atoms from ops, field names, or values. Outcome keys do become atoms so that `result.network_status` works; outcome values stay JSON values (`"in_network"`, not `:in_network`). Load only ruleset files you trust.

`match/3`, `best/3`, `select/3`, and `decide/3` take either a ruleset or a plain list of `%RuleMatch.Rule{}`. With a ruleset, its rosters join the context and its normalization runs first. `decide/3` returns the winning outcome plus `:rule_id`, `:explanation`, `:priority`, `:specificity`, and `:alternatives` (every other rule that matched).

## Two directions

Rules can also be built in code, which is handy in tests. Rules against one subject — which rule wins:

```elixir
rules = [
  RuleMatch.rule("acme_ppo",
    priority: 10,
    conditions: [{:eq, :payer, "acme"}, {:eq, :plan_type, "ppo"}],
    outcome: %{network_status: :in_network}
  )
]

{:ok, winner} = RuleMatch.best(rules, %{payer: "Acme", plan_type: "PPO", market: "north"})
winner.outcome.network_status
```

One rule set against many candidates — which candidates match:

```elixir
RuleMatch.select(rules, [
  %{id: 1, payer: "acme", plan_type: "ppo"},
  %{id: 2, payer: "globex", plan_type: "hmo"}
])
```

`match/3` returns every matching rule, ranked by `{priority, specificity}` descending. Specificity is the number of leaf constraints, so a provider-and-product-and-date rule beats a payer-only rule at the same priority. `explain/3` returns pass/fail for every condition.

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
| `{"op": "roster", "roster": r, ...}` | `{:roster, name, opts}` | Product-and-date roster cell. See below. |

A roster condition reads the provider from `provider_field` (default `provider_id`) and the date from `as_of_field` (default `date_of_service`). The product is a candidate field (`product_field`, default `product`), a literal (`"product": "basic"`), or any product (`"product": "*"`). See `RuleMatch.Codec` for the full reference.

A missing field fails every operator that needs a value. `{:eq, field, nil}` does not match a missing key; use `:blank` for that. `false` stored under a present key is a real value (`Map.has_key?/2`, never `||`).

## Rosters

Participation is often a matrix: provider row, product column, effective date in the cell. A flat provider list cannot express that.

```elixir
book =
  RuleMatch.Roster.new()
  |> RuleMatch.Roster.put(:network_a, "provider_a", "basic", effective_on: ~D[2024-08-15])

RuleMatch.Roster.member?(book, :network_a, "provider_a", "basic", ~D[2026-06-01])
```

In a ruleset file, rosters are entries of `provider`, `products` (`"*"` for every product), `effective_on`, and optional `terminates_on` and `meta`.

A cell's own `terminates_on` is provider-specific. A plan-level termination (a whole plan leaving on a given date) is a higher-priority rule, so it still wins when the cell says the provider is participating.

## What this is not

Not a Rete network, not a forward-chaining interpreter, and not a rule editor. Rules are only as current as the file you load.
