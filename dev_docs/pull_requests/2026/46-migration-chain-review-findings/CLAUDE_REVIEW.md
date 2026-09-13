# PR #46 Review — Migration-chain review findings from #42

**Reviewer:** Claude
**Author:** Timujeen
**Merge:** `26c38fa` (branch `timujinne/fix/migration-chain-review-findings`)
**Date:** 2026-09-13
**Verdict:** Approve with a doc fix. The code and tests are correct, but the
README rewrite kept the stale core-migration history it was meant to correct.

---

## Summary

- README: the tree points at `migrations.ex`, and the Database section plus the
  closing note now say the module owns the tables' future shape.
- `Migrations` moduledoc: states the core V169 floor (nullable
  `phoenix_kit_entity_data.created_by_uuid`, first shipped in `phoenix_kit`
  2.4.0).
- `mix.exs`: a comment explains why the pin stays `~> 2.0`.
- `migrations_test.exs`: pins every adopted index and constraint name.
- New `migrations_runtime_test.exs`: covers `migrated_version_runtime/1` against
  real table comments — no marker, a foreign prefix, deprecation prose, a
  malformed payload, and `pkn_schema:1`.

### Verified

- **V169 → 2.4.0.** Core's CHANGELOG `## 2.4.0 - 2026-08-14` says "Chain moves
  V166 → V169", and V169 is where the nullable creator column lands, so the new
  moduledoc claim is accurate.
- **The runtime tests don't leak.** Each `COMMENT ON TABLE` runs inside the
  DataCase sandbox transaction, and Postgres DDL is transactional, so the real
  `pkn_schema:1` marker comes back on rollback. The module is `async: false`.

---

## Findings

### IMPROVEMENT - MEDIUM — the README still describes core's pre-squash migration history

The rewritten Database paragraph and closing note still said the tables are
"created by core's `V17` migration and evolved by `V40` / `V58` / `V67` /
`V74` / `V81`". Core squashed those into its `V135` baseline, which is what the
moduledoc and AGENTS.md say.

Three more lines were wrong:
- The Troubleshooting entry credited `V17` with seeding `entities_enabled`.
  The seed is in `v135.ex`.
- The closing note said the test suite builds its schema with
  `PhoenixKit.Migrations.up()`. It actually runs core's chain and then this
  module's own chain.
- "As of this version" pointed at no version.

**Fix:** all three README spots now name the `V135` baseline, with `V169` /
2.4.0 for the nullable creator column. They also describe the two-chain test
setup.

### NITPICK — the hand-copied index/constraint list overlaps the manifest-derived drift guard (not changed)

`@indexes` / `@constraints` repeat names that the existing `ExpectedSchema`
drift guard already derives from core. It is harmless: it pins names literally,
so a manifest change that renames an object fails loudly here as well.
