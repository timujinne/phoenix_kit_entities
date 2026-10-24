# PR #53 review — Split the Gettext backend by locale and domain

Reviewer: Codex. Date: 2026-10-23. Merge: `e32312c`.
Reviewed against `7596fc0`, including Claude's review. No findings.

The change only adds `split_module_by: [:locale, :domain]` to this package's
Gettext backend. The installed Gettext 1.0.2 supports the option, and the
declared `~> 1.0` requirement is compatible. Backend identity, locale
selection, and the hand-maintained catalogue paths remain correct.

Re-ran the existing runtime locale tests for Russian, Estonian, and an
unknown locale's fallback, plus the English error assertions and catalogue
invariant tests. All passed in the focused 91-test run. The complete suite
and repository gate are recorded in the #51
[follow-up](../51-quality-sweep/FOLLOW_UP.md) for this recheck.

No production or test change was needed for this PR.
