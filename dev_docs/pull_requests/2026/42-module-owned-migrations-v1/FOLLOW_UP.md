# Follow-up Items for PR #42

Reviewed against `main` on 2026-09-05. CLAUDE_REVIEW raised 6 findings
(1 MEDIUM bug, 2 HIGH improvements, 2 MEDIUM improvements, 1 NITPICK). All six
fixed in this batch; two protocol decisions deliberately left as merged and
recorded instead.

## Fixed (Batch 1 — 2026-09-05)

- **IMPROVEMENT - HIGH** `test/support/test_migration.ex` (new),
  `test/test_helper.exs` — the chain shipped with no test that executed it.
  `migrations_test.exs` asserted on the strings `up_statements/1` returns, all
  of which pass against SQL Postgres would reject, so V1's four `DO $$ … $$`
  constraint guards, its two `CREATE TABLE` bodies and its `COMMENT ON TABLE`
  marker would have first met a real database on a host running
  `mix phoenix_kit.update`. Added `PhoenixKitEntities.Test.Migration` — the
  checked-in equivalent of the migration that task generates — and wired it
  into `test_helper.exs` after `PhoenixKit.Migration.ensure_current/2`, the
  shape `phoenix_kit_inbox` and `phoenix_kit_web_analytics` use. The suite now
  builds its schema the way an install does: core creates the tables, this
  chain adopts them. Verified against the test database —
  `migrated_version_runtime()` reads `1`, and an unusable prefix raises
  `ArgumentError` rather than reporting `0`.
- **IMPROVEMENT - HIGH** `test/phoenix_kit_entities/migrations_test.exs` — V1
  hand-copies 43 object definitions that core keeps in its `ExpectedSchema`
  manifest, with nothing holding the two lists together. The new
  `"every required core object for the entities tables is in up_statements"`
  test derives its expectations from
  `PhoenixKit.Migrations.ExpectedSchema.objects/1` (43 assertions today, more
  the day core adds an object) and skips itself if a future core drops that
  core-internal function.
- **BUG - MEDIUM** `migrations.ex` — `down/1` read `:version` only from a
  keyword list, while `validated_prefix/1` deliberately accepts maps too
  (core's own migrator threads map options). `down(%{prefix: "public",
  version: 1})` therefore validated its prefix, discarded its version and
  unstamped to `0` — a rollback to the wrong version from a caller that asked
  for the right one. Now goes through `target_version/1`, which has clauses for
  both shapes.
- **IMPROVEMENT - MEDIUM** `migrations.ex` — `migrated_version_runtime/1` had
  `rescue` but no `catch :exit`; an unreachable database raises on an unowned
  checkout but *exits* on a dead pool, which made this module report `:error`
  to `mix phoenix_kit.status` where every sibling reports `0`. Added
  `catch :exit, _ -> 0`, leaving the `ArgumentError` re-raise for an unusable
  prefix intact.
- **IMPROVEMENT - MEDIUM** `AGENTS.md`, `test/test_helper.exs` — the project
  doc still asserted in four places that this module owns no DDL. Rewrote Key
  Modules, Two-Table Database Design, Database & Migrations and Test
  Infrastructure around the adoptive chain, including the two protocol rules
  that only bite later: never edit V1, and the first V2 shape change requires
  core to move first (`@excluded_exact` + a raised core floor) or
  `mix phoenix_kit.repair` restores the old shape after every run.
- **NITPICK** `migrations.ex`, `phoenix_kit_entities.ex` — the six public
  coordinator functions are what core calls across a package boundary and
  carried no `@doc`/`@spec`; `migration_module/0` was added without the `@spec`
  its neighbouring callbacks have. Documented and spec'd, matching
  `phoenix_kit_legal`'s chain.

## Not fixed (deliberate)

- **`up/1` ignores `:version`.** Safe under core's actual usage —
  `mix phoenix_kit.update` only ever passes `version: current_version()`, and
  `up_statements/1` is cumulative and idempotent — and identical to the
  reference chains at V1. Adding step dispatch now would diverge from every
  sibling for no present benefit. It becomes load-bearing the day a V2 ships:
  `up/1` must dispatch per step then, or a host asking for V1 gets stamped V2.
  Recorded in AGENTS.md's V2 protocol notes.
- **The prefix regex is looser than core's** (`[a-zA-Z_]` vs core's lower-case,
  length-capped `validate_prefix!/1`). An upper-case prefix would fold to lower
  case in the unquoted DDL while the marker query compared it case-sensitively,
  pinning the chain at version 0 forever — but core validates the prefix at
  install time, so one never reaches this code, and the regex is verbatim what
  every sibling chain uses. Kept for cross-chain consistency.

## Verified, no change needed

- V1's adopted inventory matches core's `ExpectedSchema` exactly: 43 required
  objects (2 tables, 25 columns, 12 indexes, 4 constraints), core's names,
  widths, defaults and `ON DELETE` actions.
- Statement order is safe on a fresh create — both primary keys precede the
  foreign keys referencing them.
- The `created_by_uuid` asymmetry (`phoenix_kit_entities` NOT NULL,
  `phoenix_kit_entity_data` nullable) is the correct adoption: core's V169
  re-imposes NOT NULL only when no NULL rows exist, and this module's anonymous
  public submissions create exactly those rows.
