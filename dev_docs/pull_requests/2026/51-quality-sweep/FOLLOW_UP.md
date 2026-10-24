# PR #51 follow-up — 2026-10-23

Rechecked #51, #53, #54 and Claude's `7596fc0` fix. Full findings are in
[the #51 Codex review](CODEX_REVIEW.md),
[the #53 review](../53-gettext-split-by-locale-domain/CODEX_REVIEW.md), and
[the #54 review](../54-neutral-host-wording/CODEX_REVIEW.md).

| Finding | Severity | Resolution |
|---|---|---|
| Remote settings were discarded on validation/save, and newly opened editable tabs skipped pending state | BUG - MEDIUM | Synchronize the settings working copy and sort-mode assign; load the owner's presence snapshot for every joining tab. |
| Another editable tab could undo saved backup switches | BUG - MEDIUM | Broadcast the merged form state after each successful backup-switch write. |
| Statistics-reset intent was lost, remained pending after cancellation/save, or revived from an older snapshot | BUG - MEDIUM | Include the reset flag in broadcasts and snapshots; refresh cached state on receipt, clear the cache on spectator promotion, and initialize fresh forms explicitly. |
| Claude's changeset-error placeholder fix | Recheck | Retained; bound and unknown placeholders render correctly without atom conversion. |
| Gettext split (#53) and neutral wording (#54) | Recheck | No new findings or production changes. |

Six new LiveView regression tests reproduced the state failures before the
corresponding fixes. They verify persistence from another tab, joining-tab
state, reset cancellation/consumption, and saved backup settings surviving
another tab's save. Unsaved settings still stay out of the stored row.

The gate also required updating the existing `plug_crypto` lock from 2.2.0
to 2.2.1 for CVE-2026-105963 / GHSA-ffw9-w85g-f2vh. The targeted
`mix deps.update plug_crypto` changed no other package. The
[upstream changelog](https://github.com/elixir-plug/plug_crypto/blob/main/CHANGELOG.md)
identifies this release as the security patch.

Validation on the final code and dependency lock:

- Focused entity-editor tests: 44 tests, zero failures.
- Full `mix test`: 1530 tests, zero failures, two exclusions from the existing
  `:needs_unreleased_core` gate. Database-backed tests ran.
- `mix precommit`: passed compilation with warnings as errors, unused-dependency
  checks, Hex audit, formatting, strict Credo, Dialyzer and all three JS tests.
  Hex audit reports no retired or security-advisory packages. Dialyzer retains
  the three existing Gettext suppressions, with no new warnings.
- `git diff --check`: clean.

No version bump, CHANGELOG change or release is included.
