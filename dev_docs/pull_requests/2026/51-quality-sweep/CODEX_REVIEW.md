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

## Recheck — 2026-10-23

Reviewed the current tree at `7596fc0`, including Claude's error-rendering fix
and the earlier fixes in `314367c`. Claude's placeholder fix is sound: real
bindings still interpolate, unknown placeholders remain literal, and no atom
conversion is needed. The existing regression test passes.

Three remaining entity-editor state bugs were reproduced and fixed. They
concern tabs belonging to the same user, which are deliberately editable
together under the presence lock.

### BUG - MEDIUM — Remote settings disappear on the next validation or save

Incoming form state updated the changeset but left `entity.settings` stale.
Settings controls and `merge_translation_params/2` read that working copy,
so receiving another tab's public-form configuration and then typing or
saving silently discarded it. A newly opened editable tab also skipped the
presence snapshot entirely because only spectators loaded it.

Remote state now updates the settings working copy and sort-mode assign as
well as the changeset. Newly opened tabs load the owner's snapshot through
the same helper used for subsequent messages. Ordinary typed attributes stay
in the changeset, and settings remain unsaved until an explicit save.

### BUG - MEDIUM — A second tab's save undoes saved backup switches

Backup switches wrote only their own keys correctly, but never broadcast
the updated form state. Other tabs belonging to the same user ignore the
generic `entity_updated` notification while they own the editing lock.
Their next save therefore rewrote the old settings and disabled the backups
again. Both switches now broadcast the merged working copy after their
successful write, preserving unsaved text and sharing the saved keys.

### BUG - MEDIUM — Statistics-reset intent does not follow shared form state

`form_stats_reset?` was local to the tab that requested it. Saving the shared
form from another tab retained the counters instead of resetting them.
Conversely, discarding the reset from another tab left the original flag
set, so a later save still erased the counters. A consumed reset could also
remain pending in its originating tab after another tab saved.

The reset flag now travels in both form broadcasts and presence snapshots.
Successful saves and form resets broadcast its cleared value, and fresh
forms and spectator promotion initialize it to false. The context's atomic
stats preservation and explicit-reset contract are unchanged.

### Regression evidence

Five added LiveView tests reproduced the failures before their respective
fixes: settings lost after validation/save; newly opened tabs missing pending
settings/reset state; backup switches undone by another tab; resets ignored
or retained after another tab saves; and canceled resets still erasing
counters. A sixth test covers a newly opened third tab reading a stale
presence snapshot after another tab completed the reset. Receiving a peer's
state now refreshes the receiving session's snapshot too, so joining tabs
cannot revive consumed reset intent. Spectator promotion clears its cached
snapshot when reloading the stored row. The tests also check that unsaved settings
never reach the row and that submissions counted after a completed reset
survive the next save.

The initial full suite passed (1524 tests, zero failures, two existing
exclusions), confirming these were coverage gaps. Final validation is
recorded in [FOLLOW_UP.md](FOLLOW_UP.md).

### Gate maintenance — Patch the audited dependency

The first `mix precommit` run stopped at `mix hex.audit` on the existing
`plug_crypto 2.2.0` lock. The advisory was published after Claude's review:
wrong argument types can expose the secret key base in stack traces. The
[upstream changelog](https://github.com/elixir-plug/plug_crypto/blob/main/CHANGELOG.md)
identifies 2.2.1 as the patch for CVE-2026-105963 / GHSA-ffw9-w85g-f2vh.
Ran `mix deps.update plug_crypto`; it changed only that lock entry to 2.2.1.
No direct dependency, version, or changelog change was needed.
