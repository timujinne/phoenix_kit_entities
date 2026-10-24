# PR #51 Review — Quality sweep

**Reviewer:** Claude
**Author:** mdon
**Merge:** `1241dd0`
**Date:** 2026-10-22
**Verdict:** Approve. One small robustness fix applied after the merge.
Codex's review (`CODEX_REVIEW.md`) already covers the stale-restore, stats
lock and CLI findings; those landed in `314367c` and are not repeated here.
This review is an independent read of the same diff against the current tree.

---

## Summary

Public forms accept booleans and cap every value; the public-form counters
become one atomic `jsonb_set` bump; settings and mirror-switch writes read the
stored row under `FOR UPDATE`; trash/restore round-trips the prior status
(single and bulk); positions use an advisory lock; the mix tasks stop
rewriting the `entities_mirror_path` setting; the field modal backdrop becomes
a sibling of the box.

### Verified

- **No leftover `entity_id` routes.** The two `Web.DataForm.handle_params`
  clauses that matched `entity_id` were deleted; `routes.ex` declares no such
  segment, so nothing can reach a missing clause.
- **Removed `Events` functions have no callers.** `*_sync_request/response`
  and the two `subscribe_to_*_presence` helpers are gone from `lib` and
  `test`; the presence topics they used were private.
- **No dangling `stop_propagation`.** The handler and every `phx-click` that
  used it were removed together.
- **`with_root/2` and background tasks.** The override is per-process. The
  only task spawned under a mix run is the importer's post-import
  `mirror_entity/1`, which runs in another process and so writes to the
  *configured* mirror path. That is the right target (it keeps the configured
  mirror in step with the DB); `--input` is a source, not a destination.
- **Bulk trash/restore SQL.** Postgres evaluates every `SET` expression
  against the row's old values, so `to_jsonb(d.status)` stashes the status the
  row is leaving, not `"trashed"`. Restore falls back to `"draft"` for an
  unknown or missing stash.
- **Value caps.** `max_length` counts characters and the byte ceiling is
  `max(20_000, max * 4)`, so a legitimate multibyte value is not refused.
- **Lock order.** `update_entity/3` and `update_mirror_settings/3` take the
  entity row `FOR UPDATE` before the write; `bump_public_form_stats/2` is a
  single statement and cannot deadlock with them.

---

## Findings

### IMPROVEMENT - MEDIUM — `Errors.changeset_errors/1` can raise on user-typed text (fixed)

`message({:validation_failed, changeset})` and `message(%Ecto.Changeset{})`
interpolate bindings with `String.to_existing_atom/1` on whatever matches
`%{word}` in the message. Several messages already embed user-typed text
before they reach the changeset (`field '%{label}' must be a list of files`,
`invalid field type '%{type}' for field '%{key}'`), and a field label or key
from an imported mirror file can contain `%{anything}`. When no such atom
exists, the call raises `ArgumentError` while the importer is *rendering* its
error, turning a clean "a record is not valid" into a crash of the import
flash.

**Fix:** bindings are matched by name against `opts` (no atom conversion); a
placeholder with no binding stays as written. Test added to
`errors_test.exs`; it fails with `ArgumentError` without the fix.

### NITPICK — Stats bump now runs in the request

`increment_form_stats/3` used to run in a supervised task after the response;
it is now one `UPDATE` inline. That is the correct trade (the atomic form is
cheap and a failed bump is rescued), but two things are worth knowing:

- Honeypot / minimum-time rejections still write one row update per request
  when `public_form_rate_limit` is off (it is opt-in). The rate-limited path
  is correctly skipped. Not changed: the writes are bounded by one
  indexed-row update each, and turning the limiter on is the documented
  defence.
- The rescue lists `DBConnection.ConnectionError`, `Postgrex.Error` and
  `Ecto.QueryError`; an `:exit` from a dead pool would escape. Left as is,
  since `Repo` calls elsewhere in the same request would exit first.

### NITPICK — Public API removed in a feature release

The four `Events.broadcast_*_sync_*` functions and the two presence
subscribers were public. Nothing in this repo or its two known consumers
calls them, so no change; flagging only so the release notes can say so.

---

## Validation

- `mix test test/phoenix_kit_entities/errors_test.exs`: 33 tests, 0 failures
  (1 failure, `ArgumentError`, with the fix stashed).
- `mix test`: 1524 tests, 0 failures (2 excluded by `:needs_unreleased_core`).
- `mix precommit`: clean (compile, hex audit, format, credo --strict,
  dialyzer, JS tests).
