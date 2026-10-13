# PR #52 Review — `admin_edit_path` helper and a read-only record page

**Reviewer:** Claude
**Author:** timujinne (`admin-edit-path`)
**Merge:** `f609517` (change in `c5448e6`)
**Date:** 2026-10-13
**Verdict:** Approve with fixes. The page is read-only, takes no lock, checks
that the record belongs to the URL's entity, and has 31 tests. The fixes
below are small and were applied after the merge.

---

## Summary

- `/admin/entities/:slug/data/:uuid` now renders `Web.DataShow`; the editor
  moves to `…/edit`. The navigator's title links go to `…/edit`; its "View"
  menu entries already pointed at the bare URL and now reach the new page.
- `PhoenixKitEntities.admin_edit_path/2,3` builds the editor path through
  `Routes.path/2`; the entity name and record uuid are validated so a caller
  cannot add path segments.
- README and AGENTS.md document both.

### Verified

- No leftover `:show` action in `Web.DataForm`; both route blocks (localized
  and not) switched, with a test pinning it.
- `Web.ProjectDataLive` links to the bare URL, so the projects hub now opens
  the read-only page, which matches its "mutations stay in the entities admin"
  contract.
- Permission: the gate is the same as `DataForm`'s (tested).
- `EntityData.get!/2` on an unknown uuid raises like the edit form did.

## Findings

### IMPROVEMENT - MEDIUM — Choice fields ignored option translations (fixed)

`select`, `radio` and `checkbox` values fell through to `scalar_text/1`, so
a Spanish viewer saw the stored English option value even when the field
carried `translations.<lang>.options`. The form shows the raw value too, but
a read-only page is where the label is expected. Now rendered through
`FormBuilder.translated_option_label/3`; an empty value shows a dash.

### IMPROVEMENT - MEDIUM — Blueprint changes were ignored (fixed)

`Web.Hooks` forwards `{:entity_updated, uuid}` / `{:entity_deleted, uuid}`
but the catch-all `handle_info` dropped them. An open page kept the old
`fields_definition` (stale labels, a removed field still listed) and a
deleted entity left the viewer on an orphan page. `entity_updated` now
re-reads the entity and re-resolves labels; `entity_deleted` flashes and
navigates to the list, as `DataForm` does.

### IMPROVEMENT - MEDIUM — Back link and breadcrumbs dropped the locale (fixed)

`back_path/1`, the section path and the delete redirect used
`Routes.path/1`, while `DataForm` passes `locale: current_locale_base`. In a
non-primary locale the Back button flipped the admin to the primary one.
All now pass the locale.

### NITPICK — Image `alt` used the raw label (fixed)

Now `field_label/2`, so the translated label is used.

### NITPICK — Doc says `/2` in AGENTS.md, `/2,3` in README (left)

Both are right (`opts \\ []`); the merge title says `/3`. Not worth a churn.

### Not changed

- `Edit` is shown to everyone who can open the page. The editor is gated by
  the same permission, so there is nothing to hide.
- Dates are shown as stored (`date`, `decimal`, `number` through
  `scalar_text/1`). Formatting a date needs the user's locale rules, so it is
  left to a follow-up.

## Pre-existing test failures fixed along the way

The `libs` commit (`d1b3e16`) moved core from 2.40.1 to 2.62.2, which builds
primary-language admin paths without a locale segment
(`/phoenix_kit/admin/…`). Four tests (3 in `DataNavigatorLiveTest`, 1 in
`EntityFormLiveTest`) had been failing since, on `main`, independent of this
PR. The test router gains the prefixless scope, the navigator tests start
there, and the entity-form assertion matches the stable tail of the path.

## PR #51 spot check

Read the public-form controller diff and `bump_public_form_stats/2`: the IP
extraction, size caps, no-public-value types and the atomic `jsonb_set` bump
hold up. No changes. A fuller review of #51 was not done; it is the owner's
own sweep and already carries a "Fix review findings" commit.

## Validation

`mix precommit` clean (compile, format, credo --strict, dialyzer, hex.audit,
`mix test.js`); `mix test` 1513 tests, 0 failures. `mix format` also
re-wrapped one line in `relations_test.exs`.
