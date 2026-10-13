# PR #52 review — Admin edit helper and read-only record view

Reviewer: Codex. Date: 2026-10-13. Merge: `f609517`.
Reviewed Claude's follow-up `7d85172` as well as the original change.
Verdict: additional fixes applied; validation passed.

## BUG - MEDIUM — Linked records remain stale

`DataShow` subscribed only to the source entity's events and handled only
updates to the displayed record. Renaming or trashing a target in another
entity left its old title visible until the page was reopened.

The view now subscribes to the all-data topic and refreshes relation labels
only for relevant target events. Target UUIDs are checked against the stored
relation values, including hidden targets, so restoring a target makes its
label reappear. Source updates and deletions retain their existing behavior.

Regression tests reproduced the stale title before the fix and cover rename,
trash, restore, and hard deletion of a linked target.

## BUG - MEDIUM — Trashed relation targets are displayed

`Relations.labels_for/2` deliberately includes trashed targets for editor
pickers. `DataShow` reused it without filtering, so the read-only view showed
records that relation reads should hide. The view now filters trashed labels
without changing editor behavior. A regression test failed before the fix
for an already trashed target; the lifecycle test checks live visibility too.

## IMPROVEMENT - MEDIUM — Verify the translated behavior Claude fixed

Claude's added choice test used the primary locale, so it did not exercise
the translated option label. Added a secondary-locale test that checks the
translated option, Back and Edit paths, breadcrumb and section paths, and
the deletion redirect. A separate test checks the translated record title
and field value while verifying the raw multilingual JSON remains unchanged.

## NITPICK — Entity rename leaves the subtitle stale

The entity-update handler reloaded the blueprint and breadcrumbs but left
`page_subtitle` naming the previous entity. It now rebuilds that subtitle
alongside the other page metadata.

## Verified and validation

The editor helper validates path inputs and delegates routing to core. Both
route blocks use `DataShow` for the bare record URL and `DataForm` for `/edit`.
The view checks record ownership, shares the editor's permission namespace,
renders rich text through the sanitizer, and takes no editing lock.
Claude's fixes to choice rendering, blueprint lifecycle handling, locale
paths, and image labels are retained. His core-path test-router adjustment
matches the installed core's primary-language path policy.

- `DataShowLiveTest`: 39 tests, 0 failures.
- Full suite: 1523 tests, 0 failures, 2 existing exclusions; database tests ran.
- `mix precommit` passed, including 3 JavaScript tests.

The #51 review and its fixes are recorded separately in
`../51-quality-sweep/CODEX_REVIEW.md`. Review fixes are committed locally;
release preparation, pushing, and Hex publication remain with the maintainer.
