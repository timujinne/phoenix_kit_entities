# PR #49 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved. The in-PR review rounds
(thousands-grouping scale, `number` bounds, public-form normalization and
decimal bounds bypass) were fixed by the author before the merge, in
`bdf2b57`..`069b040`.

## Fixed (Batch 1 — 2026-09-16, post-merge, released in 0.4.16)

- ~~Claude 1 (BUG - HIGH) — the `~> 2.0` core pin admitted cores without
  `<.decimal_input>` / `Number.parse_decimal/2`, which cannot compile this
  package.~~ Pin raised to `~> 2.26`. The conformance test now enforces the
  floor.
- ~~Claude 2 (BUG - MEDIUM) — an unreadable `min`/`max` (`""`, a typo, a map,
  `"NaN"`) raised inside `EntityData.changeset/2`, and a `"NaN"` bound also
  raised in `FormBuilder`.~~ Both now ignore an unreadable bound, as
  `FormBuilder` already documented. Regression tests were added in both test
  files.

## Skipped (with rationale)

- **Claude 3 — 10¹² magnitude ceiling on existing data.** It is core's
  deliberate input guard, and copying the parser here to skip it would bring
  back the drift the PR removed. Noted in the CHANGELOG. Use a `text` field
  for values this large.
- **Claude 4 — bounds errors read "must be a number" in the changeset.** It
  needs new msgids in three hand-maintained catalogues. The admin path already
  shows the precise message.
- **Claude 5 — three entity fetches per changeset.** This is the existing
  pattern. Threading the entity through would be a separate refactor.
- **Claude 6 — `decimal_step/1` no longer drives any HTML.** It is public API,
  so it stays for callers that still render a native number input.
