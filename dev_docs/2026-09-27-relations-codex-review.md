# Relations 0.5.0 — Codex review

Reviewed 2026-09-27 against the uncommitted working tree based on `2402907`, using
[the handoff](2026-09-27-relations-handoff.md). **Hold release for the findings below.**
No implementation changes, commits, pushes, tags or publishing were performed.

The existing relation tests pass, but six additional regression probes fail on
observable behavior. They are preserved in
[2026-09-27-relations-review-repro.exs](2026-09-27-relations-review-repro.exs), outside
`test/` so the regular suite is unchanged. Assertions describe the desired
behavior; these are intentionally failing review evidence, not a passing gate.

## 1. BUG - HIGH: picking/removing a relation clears unrelated checkbox answers

**Location:** `lib/phoenix_kit_entities/components/live_data_form.ex:553`
(`put_relation_value/3`, also `persist_data/3:586` and
`normalize_absent_checkboxes/2:886`).

The search pick/remove handler passes only `%{relation_key => value}` into
`do_autosave/2`. That function uses the full-form persistence path, which treats
EVERY absent checkbox field as an unchecked group and inserts `[]`. Those empty
lists overwrite the record's previously saved answers. This affects ordinary
checkbox fields, not just relation fields, and happens immediately upon picking
or removing a chip.

**Reproduced:** save `tools: ["Hammer"]`, then dispatch a relation pick. The link
is saved successfully, but reloading the record returns `tools: []`. A required
checkbox instead prevents the relation save because its answer was cleared.

**Fix direction:** distinguish a partial field update from a complete form
submission. Only complete form submissions should normalize absent checkboxes.
Preserve other staged values when persisting a picker event.

## 2. BUG - HIGH: delete-time pruning overwrites intervening edits to the entire data map

**Location:** `lib/phoenix_kit_entities/relations.ex:737–746`,
`candidate_rows/3:791–805`.

Pruning reads source rows without row locks, computes a replacement JSONB map in
Elixir, then writes the WHOLE map with `update_all`. The surrounding delete
transaction does not protect those unlocked reads from another writer. If a
source edit commits between the SELECT and UPDATE, pruning overwrites that edit
with its earlier snapshot. Two target deletions pruning the same source can also
replace each other's cleanup.

**Reproduced:** a deterministic telemetry hook injects a `note: "after"` write
after the candidate SELECT has captured its result, before pruning updates it.
Deletion succeeds and the link is removed, but `note` returns to `"before"`.
This probe models the specific interleaving on one sandbox connection; it is
not a multi-connection concurrency stress test. The missing lock and full-map
replacement are visible in the implementation.

**Fix direction:** lock affected source rows before reading/modifying them, with
a consistent lock order, or perform an atomic JSONB transformation against the
current database value. Coordinate this with ordinary relation writers; a
transaction around an unlocked read is insufficient.

## 3. BUG - HIGH: valid required forward/cyclic relations cannot be imported

**Location:** `lib/phoenix_kit_entities/mirror/importer.ex:269–282`,
`relink_record/2:158–175`.

The first import pass replaces unresolved slug references with `[]`/`nil`, then
calls the normal record changeset. For a required relation this fails validation
and no source row is created. The second pass only handles `:created` and
`:updated` results; it never retries the failed row. Import ordering therefore
still determines success for required fields. Cycles of required links cannot
be imported in any order.

**Reproduced:** one self-referencing entity file containing `first → second` and
`second → first`, with the relation required. Both rows return
`{:error, {:validation_failed, changeset}}` with `field 'Links' is required`.
Using one file exercises the real second pass without filesystem/path fixtures.
The same first-pass failure affects a source file imported before its target
in `import_all/1`.

**Fix direction:** plan identities and references before final validation and
persist a complete valid graph transactionally. Deferred retries can address
acyclic forward references, but required cycles need an explicit graph import
strategy. Do not globally weaken required-field validation. Also propagate
second-pass failures/incomplete links into the import result rather than
silently discarding them.

## 4. BUG - MEDIUM: required relations accept an empty hidden-input list

**Location:** `lib/phoenix_kit_entities/entity_data.ex:201–202`,
`validate_relation_shape/3:670–674`.

Requiredness is checked before relation normalization. `[""]` and `[nil]` are
not among the empty values recognized by `validate_single_data_field/3`.
`cast_value/2` accepts them, then normalization turns them into `[]` or `nil`
after the required check has already passed.

**Reproduced:** `EntityData.create/2` with a required multiple relation and
`%{"links" => [""]}` returns `{:ok, record}` whose stored `links` is `[]`.
`FormBuilder` correctly rejects this shape, but callers can reach the write API
directly; `LiveDataForm` also explicitly treats FormBuilder validation as
best-effort and falls back to the original params on error.

**Fix direction:** normalize relation values before required-field validation,
or apply the required check to the successfully cast value. Cover both single
and multiple relations and the hidden-input empty-list shape.

## 5. BUG - MEDIUM: a stale source save resurrects a permanently pruned link

**Location:** `lib/phoenix_kit_entities/relations.ex:310–323`,
`lib/phoenix_kit_entities/entity_data.ex:709–710` (`check_relation_references/3`).

The added-link calculation compares with `changeset.data.data`, which comes
from the caller's potentially stale struct. It does not compare with the
source row after pruning. A form/API caller opened before the delete still
holds the old link, so it is classified as "held" and skips all reference
checks even though the database row no longer holds it.

**Reproduced:** load source `{links: [target], note: "before"}`, delete target,
verify the fresh source has `links: []`, then save `note: "after"` using the old
source struct and its data. The fresh source once again contains the deleted
target UUID. No simultaneous requests are needed.

This differs from deliberately allowing links that are **still persisted** to
trashed/missing targets: the link here was already removed by the module's own
hard-delete operation.

**Fix direction:** reconcile against current persisted link state under the
write protocol used for pruning. Reject or reconcile stale attempts to re-add
pruned UUIDs, while retaining the promised behavior for links genuinely held
in the current row.

## 6. BUG - MEDIUM: a parent update discards an unsaved search-picker selection

**Location:** `lib/phoenix_kit_entities/components/live_data_form.ex:202–220`,
`put_relation_value/3:532–554`.

A refused picker autosave leaves its selection only in `form.source`, as the
handoff describes. However, every parent `update/2`, even with identical assigns,
unconditionally calls `assign_form/1`, replacing that changeset with the saved
record. A parent rerender therefore removes the visible chip and its hidden
input before the next successful save can carry it through.

**Reproduced:** create a record, add a required field to its entity, pick a
relation while that required answer is missing, then call `update/2` with the
same record/mode/id. The staged link exists immediately after the pick and is
`nil` after the parent update.

**Fix direction:** preserve the draft changeset across unchanged parent
updates; define how to reconcile genuinely changed records. Test refused pick
and remove operations as well as successful autosaves.

## Additional follow-up: mirror files stay stale after cross-entity pruning

**Code inspection, not an additional runtime probe:**
`Relations.broadcast_pruned/1:728–731` only broadcasts. It never schedules the
source entity mirror exports performed by the normal update path in
`EntityData.maybe_mirror_data/1:1189`. The deleted target's own entity is exported,
but other entities whose JSONB rows were rewritten retain old slug references
on disk. If that slug is later reused, importing an unchanged stale source file
can attach it to the replacement record.

Schedule one post-commit export per affected mirrored source entity. Target
slug/entity-name changes also deserve a dependency-refresh policy now that
exports use those mutable identifiers. The missing source activity entries are
an audit-policy decision; stale mirror contents are a functional consistency
issue.

## Verification and remaining coverage

- Existing focused relation suite: **32 tests, 0 failures**.
- Full suite: `PGPOOL=6 mix test --max-cases 4` → **1324 tests, 0 failures,
  10 excluded**. The first default-pool run had two connection-limit failures;
  the bounded-pool rerun passed. Maintenance-database tests are excluded because
  this role cannot connect to `postgres`; the other exclusions follow the
  repository configuration.
- Review probes: **6 tests, 6 expected failures**, each at its behavioral
  assertion, after fixture setup completed. Run explicitly:

  ```bash
  PGPOOL=6 mix test dev_docs/2026-09-27-relations-review-repro.exs
  ```

- `mix precommit`: **passed**, including compile with warnings as errors,
  dependency checks, formatting, Credo, Dialyzer and the 3 JavaScript tests.
- `git diff --check`: clean at review time.
- Browser SearchPicker interaction remains unverified. Local core source does
  route hook events to the containing component and supports echoed IDs; the
  server-only tests do not verify detached-input behavior in a browser or the
  oldest supported LiveView version.
- No native-speaker assessment of the Estonian/Russian additions was performed.
