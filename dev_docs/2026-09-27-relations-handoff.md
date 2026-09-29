# Handoff: `relation` field type (0.5.0) — please recheck

**Status:** implemented, **uncommitted** on `main` (working tree only). Version
already bumped to `0.5.0` in `mix.exs`; `CHANGELOG.md` has a `0.5.0 - 2026-09-27`
entry. Nothing pushed, tagged or published. The maintainer will decide on
commit/push/publish after your review.

Gate at handoff: `mix precommit` clean (compile `--warnings-as-errors`, format,
credo --strict, dialyzer, `test.js`); `mix test` → 1324 tests, 0 failures
(10 excluded, same as before). The new test files passed 5 runs with random seeds.
The ~246 "Cache settings unavailable" log warnings in the test output are
pre-existing (same count on a clean checkout).

## Why

A host app (client project "Wood Matrix") needs a panel-size record to link
to many grade records and many thickness records. `relation` existed only as a
placeholder: it passed as a type, but it had no registry entry, a
"coming soon" box instead of an input, values dropped by `LiveDataForm`, no
validation, no read helper, and a setting nothing checked. The host's
8-point request was implemented in full, with these agreed deviations:

| Request | What was built instead | Why |
|---|---|---|
| target by "name or uuid" | admin stores the **uuid**; a name still resolves | a stored name breaks on rename |
| picker offers "published" records | offers every **non-trashed** record (drafts flagged) | admins build grades and sizes together while both are drafts |
| — | links live in the **primary language only** | a link is language-independent |
| mirror (not in request) | export target as entity **name**, links as record **slug**; import maps back | uuids differ between installs; maintainer chose this ("option b") |
| picker | **both**: checkbox/select up to 50 records, core `SearchPicker` above | maintainer's choice |

## Where the code is

| File | What changed |
|---|---|
| `lib/phoenix_kit_entities/relations.ex` | **New.** All relation logic: value casting, target resolution, write-time reference check, `resolve/3`, labels, admin picker contexts + search, delete pruning, mirror export/import helpers. Start here; the moduledoc states the rules. |
| `field_types.ex` | `"relation"` registry entry (category `:advanced`), `relation_field/4`, `validate_field` requires `target_entity` (`:missing_target_entity`). |
| `phoenix_kit_entities.ex` | Removed the hand-appended `~w(relation)`; entity changeset requires `target_entity` and enforces `entities_allow_relations` for NEW relation fields (compares to `changeset.data.fields_definition`). |
| `entity_data.ex` | Changeset: `validate_relation_shape` in the type dispatch, and `normalize_and_check_relations/1` after `validate_data_against_entity`. `delete/2` + `bulk_delete/2` call `Relations.prune_deleted/1` inside the txn and `broadcast_pruned/1` after. New public `resolve_relations/3`, `count_relation_references/1`, `@doc false sort_order_for/1`. |
| `form_builder.ex` | `validate_type` relation clause (shape only, DB-free), `blank_relation/2` before the required check, secondary-language validation skips relations, full `build_field` relation clause + helpers, `relation_picker_id/2`. |
| `web/data_form.ex` | Loads `:relation_ctx` in `hydrate_data_form`; events `relation_search` / `relation_pick` / `relation_remove`; `ensure_relation_labels/1` on reload/remote/save paths; **new `flash_data_errors/2`** (changeset `:data` errors were silently swallowed on save before, for every field type). |
| `components/live_data_form.ex` | Relation values pass `sanitize_values` (string / list of strings); `assign_relations/1` with a cache key; the same three events (`:edit` only); readonly shows titles. Moduledoc's "readonly is DB-free" claim amended. |
| `web/entity_form.ex` | "Links to" entity select + "allow several" toggle; relation hidden from type list when the setting is off (unless editing an existing relation); default-value input hidden for relations; relation fields excluded from public-form field list; list summary "Links to many X". |
| `web/data_navigator.ex` | `format_data_preview/2` shows titles; trashed rows' "Delete forever" confirm says how many records link to them (`ngettext`). |
| `controllers/entity_form_controller.ex`, `components/entity_form.ex` | Public form never accepts/renders relation fields. |
| `mirror/exporter.ex`, `mirror/importer.ex` | Slug/name export; importer first pass keeps resolvable links, `link_relations/1` second pass after the whole run (`import_all`, `import_selected`, `import_from_data`); preview compares in export form. |
| `components/field_input.ex` | Comment only (relation stays "unsupported" there, renders no input). |
| `errors.ex` | `:missing_target_entity`, `:relations_not_allowed`. |
| `priv/gettext/*` | ~30 hand-added msgids (en/et/ru + pot). |
| Docs | `OVERVIEW.md` (new "Relation fields" section), `DEEP_DIVE.md`, `README.md`, `AGENTS.md` (convention bullet, architecture tree, settings table). |
| Tests | New `test/phoenix_kit_entities/relations_test.exs` (23), `test/phoenix_kit_entities/web/relation_fields_live_test.exs` (9). Two existing tests rewritten because they pinned the placeholder behaviour: `entity_changeset_test.exs` ("all supported field types" now gives relation a target, + a no-target test) and `live_data_form_test.exs` (file-only drop test + new relation shape test). |

## Rules the implementation promises (verify these)

1. Stored value: uuid (single) or list of uuids (multiple), canonicalised on
   write (dedupe, `""`/`[""]` → none, single uuid accepted for multiple,
   one-item list for single). Two links in a single field → error.
2. Only **added** uuids are checked (`new -- old` per field): each must be a
   record of the target entity and not trashed. Held links are never
   re-checked, so a trashed/deleted target or a deleted target entity never
   blocks saving the source record.
3. Relation keys under secondary languages are stripped on write; secondary
   language tabs show the primary's links read-only.
4. `FormBuilder` performs no DB access; callers pass `opts[:relations]`
   (from `Relations.picker_contexts/3`). Without a context the value still
   rides hidden inputs so a save can't drop it.
5. Reads (`resolve/3`, labels) skip missing and trashed targets; one
   `phoenix_kit_entity_data` query per target entity.
6. Hard delete prunes the uuid from every referencing record (including
   trashed ones) inside the delete transaction; `:data_updated` broadcast
   only after commit. Trash does not prune.
7. Public submissions never carry relation values.

## Where I'd look hardest

- **`Relations.prune_deleted/1` / `candidate_rows/3`**: a textual pre-filter
  `data::text ~ 'uuid1|uuid2…'`, then per-row `update_all`. That bypasses the
  changeset, activity log and mirror auto-export for the rewritten rows.
  Is that acceptable? Large bulk deletes build a long regex.
  `referencing_fields/1` loads every entity per delete (small table, but
  check it).
- **Per-keystroke cost in `DataForm`**: `do_validate` runs
  `EntityData.change/2`. When the links differ from the saved record, that
  runs `check_references` (up to 2 queries) on every validate. The changeset
  also loads the entity once more than before.
- **Race**: a `validate` in flight before a pick's re-render can post the
  old hidden inputs and undo the pick (same class of race as the existing
  media picker). Judge whether it matters.
- **SearchPicker in the browser is untested.** LiveViewTest does not run JS.
  The picker input gets `form="<id>-detached"` so typing in it does not fire
  the surrounding form's `phx-change`. This relies on LV 1.2's `input.form`
  check (read in `deps/phoenix_live_view/priv/static/phoenix_live_view.js`
  around `bindForms`). It needs a manual browser check: search, pick, chip
  remove, save, and two relation pickers on one page (routing by echoed
  `id`). It also assumes the host admin loads core's `PhoenixKitHooks`.
- **Secondary-tab detection** uses `opts[:primary_placeholders]` (set only
  when the data is already multilang). A brand-new record opened on a
  secondary tab would show an editable picker whose value the secondary
  validation then ignores. New records open on the primary tab, so this is
  an edge case, but confirm.
- **`LiveDataForm.put_relation_value/3`** persists immediately via
  `do_autosave`. If the save is refused (required field empty), the pick
  stays only in the form and rides the next autosave. Check that it isn't
  lost on the next `update/2` from the parent: `assign_form` resets the form
  from `record`.
- **Importer second pass** (`relink_record/2`): re-reads the record and
  `EntityData.update(..., activity_log: false)`. `relink_definition/1` calls
  `update_entity` and silently ignores refusals (managed blueprints). The
  cross-file order is tested only via sequential `import_from_data` calls,
  not a real `import_all` over Storage (the containment guard makes tmp
  paths flaky in tests).
- **`sanitize_values` in LiveDataForm** now lets relation lists through. The
  changeset is the final gate. Confirm no render path can crash on a
  malformed stored relation value (`Relations.uuids/1` filters non-uuids
  everywhere I render).
- **Gettext**: entries were added by hand. `gettext_catalogue_test.exs`
  passes, but a native-speaker sanity check of et/ru wording would help.
- **`relation_field/4` default** sets `"allow_multiple" => false` explicitly.
  `multiple?/1` accepts `true`/`"true"`, and the entity editor stores a
  boolean.

## Known gaps (deliberate, not bugs)

- No settings-page toggle for `entities_allow_relations` (the settings form
  renders none of the `entities_*` flags; pre-existing).
- `FieldInput` (host inline editor) has no relation control.
- Target order follows the target entity's sort mode: `auto` = newest first.
  Set the target to `manual` for a curated order.
- No DB-level FK or index on links (JSONB). Reverse lookups rely on the text
  pre-filter.

## How to check

```bash
mix test test/phoenix_kit_entities/relations_test.exs test/phoenix_kit_entities/web/relation_fields_live_test.exs
mix test
mix precommit
git diff; git status   # three new untracked files: relations.ex + two test files
```

Per repo convention, put findings in a review file rather than editing
silently (`dev_docs/pull_requests/{year}/…/{AGENT}_REVIEW.md` if this gets a
PR number; otherwise next to this handoff). Severities: `BUG -
CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`. Do not commit,
push, tag or publish; the maintainer does that.
