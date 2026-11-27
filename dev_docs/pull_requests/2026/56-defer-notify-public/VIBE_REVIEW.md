# PR #56 review record — `defer_notify` public + `EntityData.notify_committed/2`, and the post-v0.7.0 sweep

**Reviewer:** Mistral Vibe
**Scope:** everything on `main` since the v0.7.0 tag — PR #56 (`42577ec`,
`efd709f`/`9a11057`/`cfdfcd5`) plus the direct commits `cd84722` (core floor
`>= 3.5.0 and < 4.0.0`, shim removal), `007c0e9`/`42248a4` (dependency upgrades,
`phoenix_kit` 3.0.0 → 3.7.0 in `mix.lock`).
**Date:** 2026-11-23
**Verdict:** approve with fixes; two fixes applied (one bug in the dep
upgrades, one robustness improvement in the new API), plus a spec correction.

---

## Findings

### 1. BUG - MEDIUM — stale `ex_aws_ec2` lock broke `mix precommit` — FIXED

The dependency upgrades moved `phoenix_kit` to 3.7.0, which no longer depends
on `ex_aws_ec2`, but the lock entry survived: `mix deps.unlock --check-unused`
exited 1 listing `:ex_aws_ec2`, so the repo's own precommit alias failed on a
clean checkout. Fixed with `mix deps.unlock ex_aws_ec2`; `--check-unused` now
exits 0 and `mix hex.audit` reports no retired/advisory packages.

### 2. IMPROVEMENT - LOW — `notify_committed/2` raised a bare `FunctionClauseError` on an unknown event — FIXED

The doc said "no other event is accepted", but the implementation had no
clause for one, so `notify_committed(record, :deleted)` died with an
uninformative `FunctionClauseError`. The module's own convention for exactly
this situation (`update/3`'s `require_status`) is a descriptive
`ArgumentError` "rather than reaching a confusing CaseClauseError". Added the
catch-all clause raising `ArgumentError` naming the accepted events, updated
the doc, and added a test asserting the raise and that nothing was broadcast.

### 3. IMPROVEMENT - LOW — `update_data/3`'s `@spec` was narrower than the function it delegates to — FIXED

`update_data/3` forwards `opts` to `update/3`, which can return
`{:error, :status_mismatch}` (with `:require_status`) and
`{:error, :locked_key}` (managed blueprints), but the alias's spec allowed
only `{:error, Ecto.Changeset.t()}`. Widened the spec to match `update/3`.

## Verified clean (no change needed)

- **Floor 3.5.0 really ships everything the removed shims guarded.** Checked
  core's `v3.5.0` tag directly: `PhoenixKit.TestSupport.PostgresPreflight.check/1`,
  `PhoenixKit.TestSupport.ModuleChainCheck.build_alone/4`,
  `PhoenixKit.Modules.Storage.builtin_file_references/0`,
  `PhoenixKit.Dashboard.Tab.localized_label/1`,
  `PhoenixKit.Utils.Routes.admin_area_path?/1`, and the `expected_schema/0`
  `PhoenixKit.Module` callback all exist at 3.5.0 — so `cd84722`'s removal of
  the `Code.ensure_loaded?`/`function_exported?` fallbacks (test_helper,
  `Web.EntityForm.admin_area_path?/1`, the `:requires_*` test exclusions) is
  safe at the new floor, not just at the locked 3.7.0.
- **`defer_notify` is honored by exactly the functions the new docs name.**
  Only the `:created`/`:updated` clauses of `notify_data_event/3` check the
  option; `:deleted`/`:trashed`/`:restored` and the bulk paths announce at
  once, matching the `create/2` doc. `update_data/3` delegates to `update/3`,
  so it inherits the option.
- **`notify_committed/2`'s `:: :ok` spec holds**: the body ends in
  `maybe_mirror_data/1`, which returns `:ok` explicitly even when it spawns
  the mirror export task.
- **The rollback semantics the docs describe are real**: `create/2` and the
  unguarded `update/3` path roll back via `repo().rollback/1` inside their
  own (nested) transaction, and `update_with_status_guard/4` returns
  `{:error, :status_mismatch}` both on a stale status and on a vanished row —
  all of which mark a caller's surrounding transaction for rollback, as the
  `create/2` and `update/3` docs now state.
- **The mirror importer** (`Mirror.Importer`) still hand-rolls its
  post-commit announce in `announce/1` — deliberately not switched to
  `notify_committed/2`, because it batches the mirror export per entity
  (`Exporter.export_entity/1`) while `notify_committed/2` exports per record.
  Left as is.
- **Pin conformance test** matches `mix.exs`: admits 3.5.x–3.9.x, rejects
  2.x/3.0–3.4/4.0.0; sibling modules in the workspace carry the same 3.5.0
  floor, confirming "ecosystem-wide minimum".

## Gate

- `mix test`: 1566 tests, 0 failures (2 excluded: `:needs_unreleased_core`).
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict` (no issues), `mix hex.audit` (clean),
  `mix deps.unlock --check-unused` (clean after fix), `mix test.js` (pass),
  `mix dialyzer` (clean).
