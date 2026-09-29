# PR #50 Review — Parent picker on core's TreePicker, tree lock, actor and activity through core

**Reviewer:** Claude
**Author:** Max Don (`mdon/main`)
**Merge:** `34a4d1c` (changes in `80edb97`..`e5df839`)
**Date:** 2026-09-26
**Verdict:** Approve with fixes. The tree lock closes a real, reproduced
cycle race, and moving the parent onto server state (`parent_pick`) is the
right call. One visible form bug and some doc drift were fixed after the merge.

---

## Summary

- The parent `<select>` is replaced by core's `TreePicker`. The tree comes
  from `Tree.from_flat/2` with the record's own subtree pruned. Validate and
  save take the parent from the server's `parent_pick`, never from the posted
  form.
- `EntityData.update/3` runs a re-parent (a move to the top level included)
  in a transaction that first takes a per-entity advisory lock
  (`pg_advisory_xact_lock(hashtext("phoenix_kit_entities:tree:<uuid>"))`).
  The status-guarded path takes the same lock whenever the attrs name a
  parent.
- The cycle check is now one recursive CTE (`TreeQuery.ancestor_uuids/2`)
  instead of an N-query walk capped at 64. A parent being SET must be live
  ("parent record is in the trash").
- `Postgrex.Error` is no longer swallowed in the parent validators. Inside
  the re-parent transaction, a swallowed error would only have moved the
  crash to the next statement of an aborted transaction.
- `actor_opts/1` (copied into five LVs) is replaced by `PhoenixKitWeb.Actor.opts/1`.
  `ActivityLog` and `Attachments` delegate to core (`Activity.log/1`, which
  rescues and catches `:exit`/`:throw`, and `Storage.ResourceFolders.parent_uuid/4`).
- Header trail: `Entities / <Plural> / <record> / Edit`. Edit forms open on
  the viewing language.
- Core floor raised to `>= 2.38.0 and < 3.0.0`.

### Verified

- Every write that can change `parent_uuid` goes through `update_in_tree/2`
  or `update_with_status_guard/4`. `trash`/`restore` and the bulk paths
  touch only `status`/`position`. `nullify_trashed_children/1` only sets
  `nil`, which cannot close a cycle.
- `reparenting?/2` compares against the caller's struct. That struct can be
  stale, but when it matches the attrs the changeset carries no
  `parent_uuid` change, so nothing is written unlocked.
- `TreeQuery`'s CTE runs against a schema with a compile-time
  `@schema_prefix`, so prefixed installs work. The CTE name itself is
  schemaless.
- `Activity.log/1` in the pinned core (2.40.1) rescues and catches `:exit`
  and `:throw`, so dropping the local guard does not let a logging failure
  reach the mutation.
- The new msgids (`Edit`, `New record`, `New entity`, `Top level`, `parent
  record is in the trash`) are present in `en`, `et` and `ru`.

---

## Findings

### 1. BUG - MEDIUM — A new pick kept showing the old pick's refusal

`handle_info({TreePicker, …})` updated `parent_pick` but left the changeset
alone. After a save was refused ("parent record is in the trash", or a cycle
from a concurrent move), picking another parent still showed the old error
under the picker. The error stayed until the next keystroke re-ran validate,
and the changeset's `parent_uuid` stayed on the old value.

**Fixed:** the pick now runs `repick_parent/2`. It puts the new parent on the
changeset and drops only the `:parent_uuid` error; other fields' errors stay.
The new pick is checked in full by the next validate or save. Test: "a new
pick clears the refusal the old one earned" in `data_form_live_test.exs`. It
fails without the fix.

### 2. NITPICK — `reset` hand-rolled the pick sync

The reset handler assigned `parent_pick` inline instead of calling
`sync_parent_pick/2`, which the PR added for exactly this purpose. **Fixed.**

### 3. NITPICK — Stale comment on `parent_uuid_error/1`

The comment still said the picker "is rendered as a raw <select>".
**Fixed.**

### 4. IMPROVEMENT - MEDIUM — AGENTS.md still documented the `~> 2.26` pin

The Overview's "Depends on" line and the Landmine on three-segment pins
still named 2.26 and the two-segment form. `mix.exs` and the conformance
test had moved to `>= 2.38.0 and < 3.0.0`. **Fixed** in both places.

### 5. IMPROVEMENT - MEDIUM — Hard delete and parented creates stay outside the tree lock (not fixed)

`delete/2` checks `has_live_children?/1` inside its transaction. Under READ
COMMITTED, that does not stop a concurrent create or re-parent from committing
a child between the check and the `DELETE`. The FK then fires, and the caller
gets `:referenced_by_external` instead of the more precise `:has_children`. The
AGENTS.md claim ("a concurrent insert cannot slip past it") overstates this.

The outcome is still safe: no orphan and no cycle, only a less precise error
atom. The window predates this PR. The fix is to take `lock_tree/1` in
`delete/2` and in `create/2` when the attrs name a parent. That serializes
every parented create per entity, so it is left for a deliberate decision, not
a post-merge patch.

### 6. NITPICK — A trashed parent races the trashed-parent check (not fixed)

`trash/2` does not take the tree lock, so a record can be moved under a
parent that is being trashed at the same moment. The tree then shows the
child at the top level, as it would for any child whose parent was trashed
later. Nothing breaks, so this is not fixed.

### 7. NITPICK — The picker's tree is built once per mount (not fixed)

Records created, renamed or trashed in another session after the form opened
do not appear in (or disappear from) the picker until a reload. A stale pick
of a since-trashed row is refused at save with a clear message, and Finding 1
now clears that message on the next pick. Rebuilding the tree on every
`:data_*` broadcast would re-query the whole entity for each event. Not worth
it for this form.
