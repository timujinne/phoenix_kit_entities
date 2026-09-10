# PR #42 Review — Module-owned V1 migration chain (adoptive)

**Reviewer:** Claude
**Author:** Timujeen
**Merge:** `e902e95` (branch `timujinne/feature/migrations-v01`, commit `450e7a5`)
**Date:** 2026-09-05
**Verdict:** Approve with fixes — the DDL itself is right (all 43 objects core's
manifest requires for these two tables are adopted, with core's exact names),
but nothing executed it and nothing tied it to its authority. Both gaps closed
here, plus one map-shaped rollback bug.

---

## Summary

Three files: `PhoenixKitEntities.Migrations` (a 193-line coordinator),
`migration_module/0` on the main module, and a statement-shape test. This is
the decentralized-migrations protocol from the `phoenix_kit_hello_world`
README — `current_version/0` + `migrated_version_runtime/1` + idempotent
`up/1` + version-aware `down/1`, discovered by `mix phoenix_kit.status` /
`mix phoenix_kit.update` through `PhoenixKit.Migrations.Modules`.

V1 is an **adoption**, not a create: core's V17 made both tables and they still
ship in core's squashed V135 baseline, so on every existing install the tables
predate this chain. Every statement is `IF NOT EXISTS`-guarded and
name-identical to core's objects; the only new object is the `pkn_schema:1`
marker on `phoenix_kit_entities`. `down/1` only unstamps.

That framing is correct and the package needs it — without a chain of its own,
the tables' future shape stays hostage to core releases.

### What I verified before reviewing the shape

Cross-checked V1's inventory against core's `PhoenixKit.Migrations.ExpectedSchema`
manifest (the authority `mix phoenix_kit.repair` audits against), not against
the PR description. **43 required objects** exist for these two tables — 25
columns, 12 indexes, 4 constraints, 2 tables — and V1 adopts every one, with
matching names, widths, defaults and `ON DELETE` actions. Statement order is
safe on a fresh create too: both primary keys are added before the foreign keys
that reference them.

The `created_by_uuid` split the moduledoc calls out is right, and worth pinning
because it looks like a mistake: `phoenix_kit_entities.created_by_uuid` is
adopted `NOT NULL` and `phoenix_kit_entity_data.created_by_uuid` nullable.
Core's V169 does drop and re-add the constraint (`v169.ex:77` vs `:200`), but
the re-add is conditional on the table holding no NULL rows — and this module's
own public-form contract (anonymous submissions, no actor) creates exactly
those rows. Nullable is the correct adoption.

---

## Findings

### IMPROVEMENT - HIGH — nothing ever ran the chain

`migrations_test.exs` (as merged) asserts on the *strings* `up_statements/1`
returns: that each contains `CREATE TABLE IF NOT EXISTS`, that indexes carry
`IF NOT EXISTS`, that nothing says `DROP`. Real assertions, but every one of
them passes against SQL that Postgres would reject. Nothing in the suite
executed a single statement — no `test/support/test_migration.ex`, no
`Ecto.Migrator` call in `test_helper.exs` — even though the suite has a live
database and every sibling chain in the ecosystem wires exactly that
(`phoenix_kit_inbox`, `phoenix_kit_web_analytics`, and the protocol's own
"Testing your migration" section).

The exposure is the whole point of an adoption step: V1's four `DO $$ … $$`
constraint guards, its `COMMENT ON TABLE` marker and its two `CREATE TABLE`
bodies would have first met a real Postgres on a host app running
`mix phoenix_kit.update`.

**Fixed.** Added `PhoenixKitEntities.Test.Migration` — the checked-in
equivalent of the migration `mix phoenix_kit.update` generates in a host app —
and wired it into `test_helper.exs` right after
`PhoenixKit.Migration.ensure_current/2`, so the suite builds its schema exactly
the way an install does: core's chain creates the tables, then this chain
adopts them. Verified end to end against the test database:
`Migrations.migrated_version_runtime()` reads back `1`, and an unusable prefix
raises `ArgumentError` instead of reporting `0` (the protocol's requirement —
"not installed" and "I cannot query that prefix" must not look alike to the
update task).

### IMPROVEMENT - HIGH — the adopted inventory had no tie to its authority

V1 hand-copies 43 object definitions out of core's live schema. Core keeps the
same 43 in `ExpectedSchema`. Two lists that must stay in sync, with no test
holding them together: a column core adds to `phoenix_kit_entity_data` in a
future V — or one the PR author simply missed in transcription — is invisible
here until a fresh install (the protocol's Phase 2, when creation leaves core)
comes up with a table missing it.

**Fixed.** `migrations_test.exs` now derives its expectations from
`PhoenixKit.Migrations.ExpectedSchema.objects/1` and asserts every `:required`
object for the two tables is covered by `up_statements/1` — 43 assertions
today, and automatically more when core adds one. `ExpectedSchema` is
core-internal (`@moduledoc false`), so the test skips itself if a future core
drops `objects/1` rather than failing on an API that was never promised.

### BUG - MEDIUM — a map-shaped `down/1` rolls back to the wrong version

`migrations.ex:46-50` (as merged):

```elixir
target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0
```

`validated_prefix/1` two functions below deliberately accepts **both** shapes —
a keyword list and `%{prefix: …}` — because core's own migrator threads a map
of options through its chain. `down/1` accepts the map for the prefix and then
silently discards its `:version`, so `down(%{prefix: "public", version: 1})`
unstamps to `0`: a rollback to the wrong version, from a caller that asked for
the right one. Today only the keyword path is exercised (the migration
`mix phoenix_kit.update` generates passes `down(prefix: …, version: N)`), which
is why it reads as harmless — but the map clause exists precisely because
someone expected map callers.

**Fixed.** Extracted `target_version/1` with clauses for both shapes, mirroring
`validated_prefix/1`.

### IMPROVEMENT - MEDIUM — `rescue` without `catch :exit` in the runtime reader

`migrations.ex:32-42` (as merged) guards `migrated_version_runtime/1` with a
`rescue` only. An unreachable database *raises* on an unowned checkout but
*exits* on a dead or unstarted pool — the distinction core documents on
`PhoenixKit.Migrations.Modules` and `phoenix_kit_inbox` documents on this exact
function. Core's caller catches the exit itself, so nothing crashes; the module
is just reported as `:error` ("exited: …") where every sibling reports `0`.

**Fixed.** Added `catch :exit, _ -> 0`. The `ArgumentError` re-raise for an
unusable prefix is untouched — that one must keep propagating.

### IMPROVEMENT - MEDIUM — AGENTS.md now says the opposite of the code

The PR moved DDL ownership into the package but left the project doc asserting,
in four places, that there is none: *"This module owns **no** DDL"*,
*"No module-owned DDL anywhere"*, *"no module-owned test DDL"*, and a
`test_helper.exs` comment saying the same. For a doc whose whole job is telling
the next agent what the rules are, that is the costliest kind of drift.

**Fixed.** `AGENTS.md` Key Modules, Two-Table Database Design, Database &
Migrations, and Test Infrastructure all updated — including the two protocol
consequences that only bite later: **never edit V1**, and **the first V2 shape
change is when core has to move** (the altered objects must reach core's
`@excluded_exact` and the core floor must rise, or `mix phoenix_kit.repair`
restores the old shape after every run).

### NITPICK — undocumented protocol exports

The coordinator's six public functions carried no `@doc` or `@spec`, and
`migration_module/0` was added without the `@spec` every neighbouring callback
in `phoenix_kit_entities.ex` has. These are the functions core calls by name
across a package boundary. **Fixed** — documented and spec'd, matching
`phoenix_kit_legal`'s chain.

---

## Deliberately not changed

- **`up/1` ignores `:version`.** The generated host migration calls
  `up(prefix: …, version: target)`, and this `up/1` applies everything and
  stamps `@current_version` regardless. It is safe under core's actual usage —
  `mix phoenix_kit.update` only ever passes `version: current_version()`, and
  `up_statements/1` is cumulative and idempotent — and it is what the reference
  chains (`phoenix_kit_legal`, `phoenix_kit_projects`) do at V1. Adding step
  dispatch now would diverge from every sibling to buy nothing until there is a
  V2. **It becomes load-bearing the day a V2 ships**: at that point `up/1` must
  dispatch per step, or a host asking for V1 gets stamped V2. Recorded in
  AGENTS.md as part of the V2 protocol.
- **The prefix regex is looser than core's.** `~r/^[a-zA-Z_][a-zA-Z0-9_]*$/`
  admits an upper-case prefix that core's `Helpers.validate_prefix!/1` (lower
  case, length-capped) rejects; an unquoted upper-case identifier would fold to
  lower case in the DDL while the marker query's `nspname = $1` compared it
  case-sensitively, so the chain would read as version 0 forever. Unreachable
  in practice — core validates the prefix at install time, so such a prefix
  never reaches this code — and the regex is verbatim what every sibling chain
  uses. Left alone for cross-chain consistency; noted here so the next reader
  does not have to re-derive that it is safe.
