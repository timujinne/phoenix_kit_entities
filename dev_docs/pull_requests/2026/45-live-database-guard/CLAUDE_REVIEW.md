# PR #45 Review — Refuse to run the test suite against a live database

**Reviewer:** Claude
**Author:** Timujeen
**Merge:** `c854a88` (branch `timujinne/chore/s014-live-database-guard`)
**Date:** 2026-09-13
**Verdict:** Approve with a doc fix. The guard is correct and wired first in
`test_helper.exs`, but the repo's own documented invocation now trips it.

---

## Summary

`Test.LiveDatabaseGuard.check!/1` refuses a resolved test database name before
any connection. The name must match `_test\d*$`, and it must not appear in the
comma-separated `PHOENIX_KIT_LIVE_DATABASES`. It is called on the
already-resolved `db_name`, so `config/test.exs` stays the single source of
truth for which database that is.

Two test files cover it:
- `live_database_guard_test.exs` unit-tests the decision.
- `live_database_guard_wiring_test.exs` boots a real `mix test` subprocess
  against an unreachable host. That proves the call is wired, not just that the
  logic is correct; the moduledoc records the mutation check.

Scratch database names in `schema_owner_guard_wiring_test.exs` gained a `_test`
suffix so they still pass the guard.

### Verified

- The guard runs before the `PostgresPreflight` / repo-start fallback. A cut
  wiring call therefore shows up as exit 0, not as the guard's exception, and
  that is exactly what the wiring test asserts.
- Every other name the repo uses still passes: `phoenix_kit_entities_test`,
  `phoenix_kit_entities_v169_test` (TODOs), and the I067 scratch names.

---

## Findings

### BUG - MEDIUM — the documented shared-instance invocation is now refused

AGENTS.md (Testing) documented pointing the suite at a shared instance with
`PGDATABASE=migration_test_db PGPOOL=6 mix test`. The name does not end in
`_test`, so that command now dies with `LiveDatabaseError`.

**Fix:**
- The example now uses `shared_migration_test`.
- A paragraph states the guard's two rules and names `migration_test_db` as a
  refused shape.
- `Test.LiveDatabaseGuard` is added to the support-modules list.

### NITPICK — five `mix test` subprocesses on every run (not changed)

The wiring test spawns four refusal boots and one pass boot under
`async: true`, adding real wall-clock time to every `mix test`. Tagging the
refusal cases `:integration` would be wrong, because they deliberately need no
database. The pass case runs green without a DB too, via the fallback. The cost
is the price of proving the wiring, the same trade `SchemaOwnerGuard`'s wiring
test already makes.
