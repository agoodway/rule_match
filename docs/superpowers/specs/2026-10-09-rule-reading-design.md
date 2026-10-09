# Stored plain-English rule readings

Date: 2026-10-09

Status: Conversation design approved on 2026-10-09. Pending review of this document.

## Intent and agreed scope

A person should be able to read each rule as a plain-English sentence, and to see whether that sentence still belongs to the rule in front of them.

The sentence is produced outside this library. A model that generates a JSON ruleset writes it into the file. For a database ruleset, the host application supplies it. RuleMatch stores the sentence, computes a fingerprint of the rule the sentence was accepted against, and reports whether the rule has since changed. The library never calls a model and never rewrites the prose.

The fingerprint does not judge whether the English is true or well written. A wrong sentence that was sealed against the current rule is fresh. The status is only "has the rule changed since this sentence was accepted?"

Success means:

- A rule can carry a reading in a JSON file and in the database, separate from the author-written `description`.
- The library is the only writer of the fingerprint.
- A body-only edit leaves the old fingerprint in place, so the reading becomes stale.
- Sending `reading` again, or calling seal, accepts the current prose and rewrites the fingerprint.
- File and database rules report the same status for the same body, normalize spec, and referenced rosters.
- Matching ignores the reading and the fingerprint.

## Approach

Add two optional fields to each rule and a small `RuleMatch.Reading` module that owns the fingerprint and the status. This was selected over having the generating model compute the hash, and over storing the pair inside `meta`.

The library owns the hash so there is one canonical encoding, next to the codec that already encodes conditions and rosters. A generated file that has sentences and no hashes has a distinct unsealed status. A ruleset write that replaces `meta` cannot drop the reading.

Rejected alternatives:

- The generator writes `reading_fingerprint` from a documented encoding. A second implementation of the canonical form would live outside Elixir, and a hash the model got wrong would look stale on a sentence that was just written.
- Store the sentence and the hash inside `meta`. That avoids a migration, and it puts the reading in the same object authors use for their own notes.

## Fields

Each rule gains two optional strings:

| Field | JSON key | Database column | Meaning |
| --- | --- | --- | --- |
| `reading` | `"reading"` | `rules.reading TEXT NULL` | Plain-English reading of this rule |
| `reading_fingerprint` | `"reading_fingerprint"` | `rules.reading_fingerprint TEXT NULL` | Fingerprint of the inputs the reading was accepted against |

`description` stays the author's short label. The ruleset format stays 1. Existing files and rows load with both fields empty.

`RuleMatch.Rule` carries both fields, defaulting to `nil`. `Rule.new/1` accepts them. `RuleMatch.compile/1` preserves them.

A reading is absent when the value is `nil` or a string whose trim is empty. The stored reading keeps its original whitespace when the trim is non-empty. A fingerprint is absent when the value is `nil` or `""`.

## When the fingerprint is written

The library writes `reading_fingerprint`. Callers do not.

`Store.create_rule/3` and `Store.update_rule/4` accept `reading`. After `StoredData.normalize_attrs/1`, key presence uses the string key `"reading"`.

- The attrs include `"reading_fingerprint"`. The changeset adds an error on `:reading_fingerprint` with the message `"is set by the library"`. Nothing is written.
- `"reading"` is present and is neither `nil` nor a string. The changeset adds an error on `:reading` with the message `"must be a string"`.
- `"reading"` is present and blank. Both stored values become `nil`.
- `"reading"` is present and non-blank. The library stores that string and sets the fingerprint from the rule as stored after this write, together with the locked parent's current `normalize` and `rosters`. Sending the same sentence again accepts it against the current rule.
- `"reading"` is omitted. Both stored values stay as they are, including when the same update changes conditions, outcome, or priority.

The fingerprint is computed only after the rest of the changeset is valid, from the values that will be stored. An invalid definition writes nothing.

`update_ruleset/3` does not rewrite rule rows. A change to `normalize` or to any roster leaves every stored fingerprint where it is.

`Ruleset.save/2` writes the struct it is given. It does not seal. Loading a file does not seal.

File decoding:

- A blank `reading` becomes `nil`, and any fingerprint on that rule is dropped.
- A fingerprint with no reading is dropped.
- An empty-string fingerprint with a non-blank reading becomes `nil`, so the rule is unsealed.
- A non-string `reading` or `reading_fingerprint` raises `ArgumentError`, which file and Ecto loading already surface as `{:error, {:invalid_ruleset, message}}`.
- Any other string fingerprint is kept as stored. The library does not check its prefix on load. A fingerprint this library did not compute compares unequal and the status is `:stale`.

The Ecto loader's rule map copies both columns into the runtime rule.

## Status and seal

`RuleMatch.Reading.status/2` takes a ruleset and a rule. The ruleset supplies `normalize` and `rosters`. The rule supplies its conditions, outcome, priority, reading, and fingerprint. The rule does not have to be a member of `ruleset.rules`.

| Status | When |
| --- | --- |
| `:absent` | The reading is absent. A stored fingerprint is ignored. |
| `:unsealed` | A reading is present and the fingerprint is absent. |
| `:fresh` | A reading is present and the stored fingerprint equals `Reading.fingerprint/2` for this ruleset and rule. |
| `:stale` | A reading is present and the stored fingerprint differs. |

`Reading.fingerprint/2` returns the fingerprint string defined below. It does not read or write the stored fingerprint.

`Ruleset.seal_readings/1` returns a new ruleset and writes nothing. For every rule whose reading is present, it sets `reading_fingerprint` to `Reading.fingerprint/2` of the current inputs and leaves the reading text unchanged. For every rule whose reading is absent, it sets `reading_fingerprint` to `nil`.

`Store.seal_readings(key, opts \\ [])` does the same for one database key. It locks the parent with the existing `FOR UPDATE` lock, updates the rules in that transaction, and returns `{:ok, records}` in position then primary-key order, the same order as `list_rules/2`. An unknown key returns `{:error, :not_found}`. Invalid configuration returns `{:error, {:invalid_config, message}}`. Unexpected database exceptions propagate, as they do for the other store functions. Seal means the current prose is accepted as it stands. It refreshes fresh, unsealed, and stale readings alike.

A codec failure while sealing or fingerprinting raises `ArgumentError`, as other codec failures do.

`match/3`, `best/3`, `decide/3`, `explain/3`, and `select/3` ignore both fields.

## Fingerprint

`Reading.fingerprint/2` hashes one JSON object with these keys:

| Key | Value |
| --- | --- |
| `priority` | The rule's integer priority. |
| `conditions` | `Codec.condition_to_map/1` of each condition, in stored order. Nested conditions stay nested. Array order is kept. |
| `outcome` | `Codec.to_json_value/1` of the outcome. |
| `normalize` | An object with `dates` and `downcase`. Each list is sorted in UTF-8 byte order and de-duplicated. Both keys are present. Reordering the same field names does not change the hash. Adding or removing a name changes the hash for every rule. |
| `rosters` | One entry for every roster named by the rule. |

Roster names come from walking the condition tree. `all`, `any`, `none`, and `not` are walked into. A `roster` condition contributes `to_string(name)`. Every other condition is a leaf. Names are unique. The object is keyed by those strings.

A name present in the roster book is encoded with the entry shape of `Codec.rosters_to_map/1`: `member`, `categories` sorted ascending, and `effective_on`, plus `terminates_on` when it is not `nil`, plus `meta` when it is not an empty object. Those entries are then sorted by `member`, then `effective_on` with `null` before any date string, then `terminates_on` with a missing value and `null` both before any date string, then `categories` element by element with a shorter equal prefix first, then the canonical JSON of `meta` with a missing value and `{}` treated alike. A remaining tie uses the canonical JSON of the whole entry.

A referenced name that is not in the book is `null`. That is distinct from a present roster with no entries, which is `[]`. Creating the roster later changes the hash. A roster the rule does not name is omitted.

The reading text is not an input. Two different sentences accepted against one unchanged rule share one fingerprint. Also outside the hash: `description`, `tags`, `meta`, `position`, other rules, unreferenced rosters, and the host functions behind `pred` conditions. The predicate name and `args` are inside `conditions`, so editing those marks the reading stale. A change to the predicate's code does not.

### Canonical bytes

Every object in the document, at every level, is encoded with keys in ascending UTF-8 byte order. Arrays keep the order defined above. The hashed bytes are the compact UTF-8 JSON of that document: no insignificant whitespace, and string, number, boolean, and null literals produced by `JSON.encode!/1`.

The stored fingerprint is `"sha256:"` plus the lowercase hex SHA-256 of those bytes.

Golden vector. A rule with priority 10, one condition `{:eq, "payer", "acme"}`, outcome `%{network_status: "in_network"}`, normalize `%{downcase: ["payer"], dates: []}`, and no roster references hashes these bytes:

```json
{"conditions":[{"field":"payer","op":"eq","value":"acme"}],"normalize":{"dates":[],"downcase":["payer"]},"outcome":{"network_status":"in_network"},"priority":10,"rosters":{}}
```

The fingerprint is `sha256:e8a5768db85c035f7fdcc3082de725cffa784e34bb333ad3da9ba3ff7e7c8afe`.

The same body produces that fingerprint from a file, from the database, and from a struct built in code.

## Migration

Add `RuleMatch.Migrations.V02` and register it after `V01` in `RuleMatch.Migration`.

`v02_up.sql` adds `reading` and `reading_fingerprint` as nullable text columns on `$SCHEMA$.rules`. Rows that already exist gain both columns as null and keep their other values. `v02_down.sql` drops `reading_fingerprint` and then `reading`.

Applications run `RuleMatch.Migration` themselves, as they do today. Loading and sealing do not migrate.

## Documentation

The README gains a short account of the two fields, the four statuses, and the two seal functions. It tells a generating model to:

- Put the sentence in `reading` and omit `reading_fingerprint`.
- Describe this rule's conditions, outcome, and priority.
- Leave other rules, tie-breaks, and position out of the sentence. Those inputs are outside the fingerprint.

It tells the host to seal and save after generation. It states that a predicate's code and any field units sit outside the freshness check, and that matching ignores the reading.

## Tests

Fingerprint and status, in a new `test/reading_test.exs`:

- The golden vector above, including the exact bytes and the `sha256:` string.
- The same fingerprint when condition keys, outcome keys, or normalize list order differ, and when field names arrive as atoms or strings.
- A different fingerprint when priority, a condition, the outcome, a normalize field list, a referenced roster entry, or a missing referenced roster becoming present changes.
- The same fingerprint when tags, description, meta, position, an unreferenced roster, or the reading text changes.
- `:absent`, `:unsealed`, `:fresh`, and `:stale` for those cases.
- `Ruleset.seal_readings/1` fills a missing fingerprint, refreshes a stale one, preserves the reading text, and clears a fingerprint on a rule with no reading.

Codec and file, in the existing codec and ruleset tests:

- A JSON round trip keeps both fields, and omits them when they are nil.
- A blank reading and an orphan fingerprint are dropped on decode.
- Load, seal, save, and load again reports `:fresh`. Editing a condition in the saved JSON and loading again reports `:stale`.

Store and schema, in the existing store, schema, and Ecto adapter tests:

- Creating with `reading` stores a fresh fingerprint.
- Updating conditions without `reading` leaves the sentence and the fingerprint, and the loaded rule is `:stale`.
- Updating with the same `reading` string after that edit is `:fresh`.
- Setting `reading` to `nil` or `" "` clears both columns.
- Supplying `reading_fingerprint` returns a changeset error and leaves the row unchanged.
- A non-string `reading` returns a changeset error.
- `Store.seal_readings/2` after a roster edit refreshes the rule that names that roster and leaves an unrelated rule's fingerprint unchanged.
- An unknown key returns `{:error, :not_found}`.
- The Ecto loader returns both fields on the runtime rule.

Matcher, in an existing engine test:

- A rule with a reading and a fingerprint decides to the same outcome as the same rule without them.

Migration, in the existing migration test:

- Up adds both columns. Down drops them. A row written before the migration still loads, with both fields empty.

## Out of scope

- Calling a model, choosing a provider, or shipping a prompt.
- A ruleset-level narrative of overlaps and winners.
- Checking that the English matches the conditions.
- Fingerprinting predicate implementations, field labels, units, tags, description, meta, position, or other rules.
- Sealing on load or on `Ruleset.save/2`.
- Bumping the ruleset format.
- Changing match ranking or condition behavior.
