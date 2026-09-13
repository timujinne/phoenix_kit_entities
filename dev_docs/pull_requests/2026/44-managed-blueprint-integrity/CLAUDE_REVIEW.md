# PR #44 Review — Managed-blueprint integrity: value-record slug lock

**Reviewer:** Claude
**Author:** Timujeen
**Merge:** `099ff59` (branch `timujinne/feat/managed-blueprint-integrity`, head `457f619`)
**Date:** 2026-09-13
**Verdict:** Approve with fixes. The write-path guard is the right shape, but it
locks out every multilang save of a common row shape. Its companion
`bulk_delete/2` broadcast also turns one bulk action into N full reloads per
open admin page. Both fixed here.

---

## Summary

- `Managed.validate_data_mutation/4` guards a managed blueprint's value records.
  A non-owner cannot rename `slug`, re-parent via `entity_uuid`, or change a
  per-language `data[lang]["_slug"]`. It is wired into `EntityData.update/3`,
  behind the cheap `data_mutation_needs_owner?/2` pre-check.
- Admin data form: the slug is disabled on existing managed records, with a
  hidden mirror input. Generate is hidden and also gated server-side. A new
  `{:error, :locked_key}` branch resets the changeset.
- `LiveDataForm` and `Mirror.Importer` split `{:error, %Changeset{}}` from other
  error reasons.
- The entities list replaces Archive/Restore with a "Managed by …" notice and an
  owner-admin link, filtered through `Routes.local_path?/1`.
- `bulk_delete/2` now returns deleted rows via `select` and broadcasts
  `:data_deleted` per row.

### Verified

- Every `EntityData.update/3` caller handles the new atom: `web/data_form.ex`,
  `components/live_data_form.ex`, and `mirror/importer.ex` (both clauses).
  `DataNavigator`'s `update_data/3` calls send only `status`, so they cannot
  trip the guard.
- `bulk_delete/2` still returns `{count, nil}`, the shape the untouched
  `delete_all` path returned before.
- `managed_blueprint?/2` is false on `/data/new` (a `uuid: nil` struct), so
  creating a record still sets its first slug.

---

## Findings

### BUG - HIGH — multilang saves of a managed value record are locked out permanently

`renames_translated_slug?/2` compared every language's posted `_slug` against
`data_record.data[lang]["_slug"]`, with nil standing in for "absent". The
multilang data form does two things with the primary language's `_slug`:

1. On mount, `seed_slug_in_data/1` seeds it from the `slug` column into the
   changeset only, not the DB.
2. On every save, `inject_db_field_into_data("slug", …)` (core
   `MultilangForm`) sets `data[primary]["_slug"]` from the hidden slug mirror.

A row whose stored data carries no primary `_slug` is exactly what
`EntityData.create/2` stores when a caller sets only `slug`, and that includes
the catalogue owner (`AttributeSets`, `EntityData.create`). For such a row the
guard read `nil → "oak"` as a rename. The save got `{:error, :locked_key}`; the
reset then rebuilt the same changeset, and the next save injected the same
value again. With the Languages module on, no save ever went through.

The LiveView suite runs with Languages off (`inject_db_field_into_data/5` is a
no-op unless `multilang_enabled`), so no test could see it.

**Fix:** `stored_lang_slug/4` compares the primary language against the `slug`
column when the row stored no primary `_slug`. That is what the form injects.
A differing primary `_slug` is still a rename, and secondary languages are
unchanged.

**Tests:**
- Three unit cases in `managed_test.exs`:
  - an injected primary `_slug` equal to the column is not a rename;
  - one that differs is a rename;
  - the column fallback never applies to a secondary language.
- One LV case in `data_form_live_test.exs`: a multilang managed row without a
  stored primary `_slug` saves. That case covers the single-language layout
  only, for the reason above.

### IMPROVEMENT - HIGH — a bulk delete fans out into N full reloads per open admin page

The per-row `:data_deleted` broadcast is right for owner subscribers that prune
slug references. But both admin subscribers ignore the payload and reload
everything, once per message:

- `DataNavigator.handle_info/2` runs `refresh_data_stats/1` and `apply_filters/1`.
- `EntitiesSettings.handle_info/2` runs `get_entities_stats/0` and
  `list_entities_with_mirror_status/0`, plus `Storage.get_stats/0`, which scans
  the filesystem.

Emptying a 500-row trash therefore ran 500 reloads in every open list and every
open settings page.

**Fix:** added `Events.flush_data_events/0`, which does a selective receive
with `after 0`. It drops queued `:data_created` / `:data_updated` /
`:data_deleted` messages, and both handlers call it before reloading. A single
reload already reflects everything the dropped messages announced.
`:data_reordered` and every other message are left alone. `DataForm` is not
touched, since it matches on the specific record uuid.

**Test:** `events_test.exs` checks that the flush drops the three data events,
keeps an interleaved `:data_reordered`, and returns on an empty mailbox.

### IMPROVEMENT - MEDIUM — `Routes.local_path?/1` is newer than the `~> 2.0` core floor (not fixed)

`entities.ex` calls `PhoenixKit.Utils.Routes.local_path?/1` when it renders a
managed blueprint that has a `managed_path`. The floor does not guarantee that
function exists; the earliest core CHANGELOG mention is 2.13.16. A host on an
older 2.x core would hit `UndefinedFunctionError` on the entities list.

**Not fixed**, on purpose:
- The effective floor is already above 2.0. The adopted V1 migration shape
  needs V169 (2.4.0), per PR #46, and `mix.lock` resolves 2.23.0.
- `managed_path` is written only by `phoenix_kit_catalogue`, which requires a
  far newer core.
- A `function_exported?/3` fallback would re-grow the private copy of core's
  guard that this PR just removed.

The pin stays two-segment by design (`core_pin_conformance_test.exs`).

### NITPICK — the `:locked_key` reset drops the user's other unsaved edits (not fixed)

`EntityData.change(socket.assigns.data_record)` discards the whole in-progress
form, not only the rejected slug. The slug input is disabled and the hidden
mirror carries the persisted value, so this branch is reachable only through a
forged payload. Losing a forged form's edits is acceptable, and the reset
reliably un-wedges the form (MINOR-2).

### NITPICK — create/delete gaps on value records (agree, no change)

The moduledoc's "Known gaps" section says the creation and deletion of value
records under a managed blueprint are unguarded, and that the safety net sits on
the owner's `:data_deleted` subscriber. That is a coherent scope decision, and
the per-row bulk broadcast is what makes it hold for "Delete forever".
