# PR #48 follow-up

How each finding in `GROK_REVIEW.md`, `CODEX_REVIEW.md` and `CLAUDE_REVIEW.md`
was resolved.

## Fixed (Batch 1 — 2026-09-15, folded into commit bdcb389 before pushing)

- ~~Codex 4 — the concurrency test could pass on the old shared-map code by
  scheduling luck, and it left forty guard registrations behind.~~ All forty
  tasks now wait until every one exists and are then released together, and the
  test erases its registrations on exit. On the old code it failed five runs out
  of five.

## Fixed (Batch 2 — 2026-09-15, post-merge, released in 0.4.15)

- ~~Claude NITPICK — the concurrency test discarded the tasks' results, so
  nothing checked `register_delete_guard/2`'s `:ok` return now that it returns
  whatever `:persistent_term.put/2` returns.~~ The test asserts every task
  returned `:ok`.
- ~~Claude NITPICK — the `validate_delete/2` tests never erased the
  `"managed_test_owner"` / `"crashy_owner"` guards they registered, so the
  "fails closed without a registered guard" assertion failed on the second
  pass of `--repeat-until-failure`.~~ An `on_exit` in that describe block
  erases both keys.

## Skipped (with rationale)

- **Codex 2 — a node hot-upgraded onto this code without restarting would miss
  guards registered under the old map key until they re-register.** Deploys
  restart the application, and Phoenix's code reloader reloads the host app's own
  modules, not this dependency. Owners re-register at every boot.
- **Grok** — no findings: the per-owner keys remove the race, same-owner
  re-registration keeps replace semantics, and the new layout avoids the global
  GC the shared map paid on every registration. It also explained why the first
  attempt's `:global.trans` lock timed out under contention.
- **Codex 1 and 3** — reported sound.
- **Claude — hot-upgrade gap (same as Codex 2)** — agreed, not changed. The
  catalogue's single-task `DeleteGuards` workaround is now redundant but
  harmless. It stays until the catalogue's entities floor reaches 0.4.15.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_entities/managed.ex` | one `:persistent_term` key per owner |
| `test/phoenix_kit_entities/managed_test.exs` | concurrent registration test; Batch 2: `:ok` return assertion, `validate_delete/2` guard cleanup |

## Verification

- Full suite 1264 tests, 0 failures; `mix precommit` clean.
- New test: fails on the old code 5/5, passes 3/3.
- max-dev after deploy and restart: both catalogue guards registered.

## Open

None.
