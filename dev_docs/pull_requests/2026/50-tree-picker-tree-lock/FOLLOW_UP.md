# PR #50 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved.

## Fixed (Batch 1 — 2026-09-26, post-merge)

- ~~Claude 1 (BUG - MEDIUM) — a new pick kept showing the old pick's
  refusal.~~ `repick_parent/2` puts the pick on the changeset and drops the
  stale `:parent_uuid` error. A regression test is in `data_form_live_test.exs`.
- ~~Claude 2 (NITPICK) — `reset` hand-rolled the pick sync.~~ Now calls
  `sync_parent_pick/2`.
- ~~Claude 3 (NITPICK) — stale "raw <select>" comment.~~ Reworded.
- ~~Claude 4 (IMPROVEMENT - MEDIUM) — AGENTS.md documented the old `~> 2.26`
  pin.~~ The Overview and Landmines now match `>= 2.38.0 and < 3.0.0`.

## Skipped (with rationale)

- **Claude 5 — delete and parented creates outside the tree lock.** The
  outcome is safe (only the error atom is imprecise), and the window predates
  the PR. Locking every parented create per entity is a trade-off to decide
  on its own.
- **Claude 6 — trash races the trashed-parent check.** The only effect is a
  child shown at the top level, which is already how a later-trashed parent
  renders.
- **Claude 7 — the picker tree is built once per mount.** A stale pick is
  refused at save with a clear message. Rebuilding the tree on every broadcast
  costs a full-entity query per event.
