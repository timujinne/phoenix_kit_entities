# PR #51 review — Quality sweep

Reviewer: Codex. Date: 2026-10-13. Merge: `1241dd0`.
Reviewed against `7d85172`, including Claude's spot check of this PR.
Verdict: fixes applied; validation passed.

## BUG - HIGH — A stale restore can publish a draft or overwrite a newer status

`restore_from_trash/2` trusted the caller's status and metadata. A tab holding
a published record's old trash snapshot could restore it again after someone
had restored and archived it, changing it back to published. If it had been
trashed again from draft, the same stale snapshot restored it to published
and erased metadata added meanwhile.

The single-record restore now reads the row under `FOR UPDATE`, checks the
stored trash status, and consumes the current stash. A missing or already
restored row returns `{:error, :not_trashed}`. Notification follows the
transaction. Two regression tests reproduced both failures before the fix.

## BUG - MEDIUM — Entity settings saves can still erase submission counters

The atomic bump is correct, but the entity form's read-before-save did not
lock the row. A submission committed after that read could have its counters
replaced by the settings save. Other context callers carrying stale settings
did not preserve counters at all.

`update_entity/3` now reads the stored row under `FOR UPDATE` and preserves its
stats in a settings write. Managed validation also uses that current row.
The form passes `reset_public_form_stats: true` for the explicit reset action,
replacing its earlier unlocked stats merge. An unboxed test uses separate
database connections, holds a submission transaction open, observes the save
waiting on its lock, and checks the counters after both commits. It failed
before the fix. Existing reset and subsequent-save tests still pass.

## BUG - HIGH — CLI backups omit portable relation serialization (pre-existing)

The export task used its own serializer, which wrote target entity UUIDs and
linked record UUIDs. The mirror exporter instead writes entity names and slug
references, which the importer can resolve on another installation. A CLI
backup therefore could not preserve the same relations across installations.

The task now calls `Mirror.Exporter.export_entity/2` with an explicit
`include_data` option. Existing `/1` callers retain their per-entity setting
behavior. The duplicate serializer is removed, and the shared serializer also
adds the existing multilang metadata. Counts for CLI output use a grouped
query for all entities, with no extra count query in quiet mode.

A regression test reproduced UUID output before the fix and now checks the
entity name and linked slug reference in the written JSON.

## BUG - MEDIUM — Import dry-run crashes on conflicts (pre-existing)

The importer returns `existing_uuid` for conflicting definitions and records;
the CLI read `existing_id`, raising `KeyError`. Both dry-run lookups now use
the UUID field. A regression test imports a fixture, changes its definition
and record, and checks both conflict descriptions. It crashed before the fix.

## NITPICK — Remove unused controller-test scaffolding

Removed an unused endpoint attribute and unused helper that called the
nonexistent `Phoenix.ConnTest.put_format/2`. The tests already use the direct
controller helper, so this removes warnings without changing coverage.

## Scope and validation

Read all production changes in #51, with surrounding write-path, event,
mirror, and form-state code. Checked public-field filtering, boolean casting,
value caps, trusted IP extraction, rate-limited requests avoiding writes,
atomic stats updates, trash stashes, position locks, unsaved form state,
mirror path overrides, import error rendering, and catalogue additions.
The two CLI findings predate #51 and were found while reviewing the tasks
it changed.

- `mix test`: 1523 tests, 0 failures, 2 excluded by the existing
  `:needs_unreleased_core` gate. Database-backed tests ran.
- `mix precommit`: compile with warnings as errors, unused dependency check,
  Hex audit, formatting, strict Credo, Dialyzer, and 3 JavaScript tests passed.
  Dialyzer retains the 3 existing Gettext opaque-type suppressions.
- The final CLI logging and unused-test-helper cleanup were checked again
  with the export-task and controller tests.
- Hex audit reported an expired authentication session while continuing
  successfully without credentials. Publishing authentication was not tested.

No version, changelog, dependency lock, release tag, push, or publication
changes are part of this review.
