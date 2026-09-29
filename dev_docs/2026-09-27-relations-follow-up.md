# Relations 0.5.0: follow-up to the Codex review

Responds to [2026-09-27-relations-codex-review.md](2026-09-27-relations-codex-review.md)
(not edited, per convention). All six findings were confirmed with the review's
own probes before any change, and all six are fixed. The probes in
[2026-09-27-relations-review-repro.exs](2026-09-27-relations-review-repro.exs)
now pass: `PGPOOL=6 mix test dev_docs/2026-09-27-relations-review-repro.exs` →
6 tests, 0 failures.

Each finding is also pinned in the regular suite, in the `"review regressions"`
describe block of `test/phoenix_kit_entities/relations_test.exs`, with extra
cases the probes didn't cover (listed per finding).

State after the fixes: `mix precommit` clean (credo no issues, dialyzer passed,
JS tests pass); `mix test` → 1333 tests, 0 failures (10 excluded). Still
uncommitted.

| # | Finding | Resolution |
|---|---|---|
| 1 | BUG - HIGH: a search pick clears unrelated checkbox answers | **Fixed.** `LiveDataForm.persist_data/4` takes `partial: true` for a pick/remove: only the given keys are saved, and absent checkbox groups are no longer read as "all unticked". Full form submissions behave as before. |
| 2 | BUG - HIGH: pruning overwrites intervening edits | **Fixed.** `Relations.prune_value/4` is one atomic `UPDATE … SET data = jsonb_set(data, path, <value minus the gone uuids>)`, computed in SQL from the row's current value, for both array and single-string shapes, at the primary-language path for multilang rows. Other keys are never rewritten, and two prunes of the same row compose. Extra test: a multilang row is pruned only under the primary language. |
| 3 | BUG - HIGH: required forward/cyclic relations cannot be imported | **Fixed by restructuring the importer into one run per call**, in one transaction. (a) All definitions go first, then relation targets are pointed at local uuids. (b) Every record's uuid is planned up front: existing records keep theirs, new ones get a fresh `UUIDv7`, and slug refs resolve against the plan before the DB. (c) Every write is validated before any happens; a failed record, and transitively every record linking to it, is reported (`{:broken_links, uuids}`) and not written. (d) Writes use `relation_check: :defer`, and every link is verified after all writes (safety net: any failure rolls back the whole run with `{:rolled_back, reason}` results). (e) Broadcasts and mirror exports run after commit. Refs matching nothing are reported under a new `:unresolved_links` key instead of vanishing. Extra test: a failed record takes the records that chain to it along and leaves an unrelated one written. **Why pre-validate:** in Ecto a rollback inside a nested transaction aborts the outer one, so a failing write mid-run would abort everything. The test sandbox turns nested transactions into savepoints and would hide this, so it's also noted in AGENTS.md. |
| 4 | BUG - MEDIUM: required relation accepts `[""]` | **Fixed.** Normalization (`normalize_relation_data/1`) moved BEFORE `validate_data_against_entity/1` in `EntityData.changeset/3`, so the required check sees `[]`/`nil`. Tested for multiple and single relations. |
| 5 | BUG - MEDIUM: a stale save resurrects a pruned link | **Fixed.** `Relations.check_references/4` compares against the CURRENT row, read `FOR UPDATE`, not the caller's struct. A uuid the stale copy held whose record no longer exists is silently dropped (the pruned case). A missing uuid the copy never held is still refused (extra test). `EntityData.update/3` now always runs in a transaction so the lock holds through the write. **Lock order** is linked records `FOR SHARE` → own row `FOR UPDATE` on save, and doomed rows `FOR UPDATE` → prune sources → delete on hard delete (`lock_rows/1` + prune moved BEFORE the delete). Targets before sources on both sides, so a save and a delete can't deadlock or slip a link past each other. |
| 6 | BUG - MEDIUM: parent update discards an unsaved pick | **Fixed.** Picks/removes are kept in `:pending_relations`, laid over the record every time the form is rebuilt (`assign_form/1`, which every `update/2` runs), and cleared by any successful save (the pick's own save, or a form save whose hidden inputs carried them). Tested for a pick and a remove across `update/2`. |
| — | Follow-up: mirror files stay stale after cross-entity pruning | **Fixed.** `Relations.after_prune/1` (replacing `broadcast_pruned/1`) broadcasts and schedules one mirror export per rewritten source entity whose data is mirrored, after commit. |

## Not changed, deliberately

- **Activity log rows for pruned source records**: still none, as the review
  says it's a policy call. The delete itself is logged.
- **Refreshing mirror files when a target's slug or entity name changes**: not
  done. That's a broader "mirror dependency refresh" policy, and I'd rather
  scope it separately. A rename followed by an import of an old file leaves
  those refs unresolved and lists them under `:unresolved_links`; they don't
  attach to the wrong record.
- **Still unverified**: SearchPicker in a real browser, and native-speaker
  review of the et/ru strings, as before.

## For a re-review, worth a look

- The lock-order claim (`Relations.check_references/4` moduledoc,
  `EntityData.delete/2`, `run_bulk_delete_txn/1`). A self-referencing entity,
  where one record is both target and source, is the edge I'd probe.
- `Mirror.Importer.run/1` and its `drop_links_to_missing/1` fixpoint.
- The prune SQL fragment in `Relations.prune_value/4`.
