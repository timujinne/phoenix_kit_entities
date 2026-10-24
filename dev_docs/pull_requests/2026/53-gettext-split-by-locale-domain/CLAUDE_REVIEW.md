# PR #53 Review — Split the Gettext backend by locale and domain

**Reviewer:** Claude
**Author:** mdon
**Merge:** `e32312c` (change in `0decb93`)
**Date:** 2026-10-22
**Verdict:** Approve. No findings, no changes.

---

## Summary

`PhoenixKitEntities.Gettext` now uses
`split_module_by: [:locale, :domain]`, so each locale/domain catalogue
compiles into its own module and compiles in parallel.

### Verified

- **Option exists at the pinned version.** `deps/gettext` (1.0.2, the locked
  version) documents and implements `:split_module_by`; the declared range
  `~> 1.0` cannot resolve to anything older.
- **Lookups unchanged.** Against the test build, `ru`, `et` and `en` return
  their own translations for the same msgids (`"Entity not found"` →
  `Сущность не найдена` / `Üksust ei leitud` / unchanged), an unshipped
  locale (`de`) falls back to the msgid, and `known_locales/1` reports
  `["en", "et", "ru"]`.
- **Catalogue invariants still hold.** `gettext_catalogue_test.exs`
  (no fuzzy, no empty `msgstr`, no foreign `%{binding}`) passes.
- **Hand-maintained catalogues are unaffected.** The change touches only
  compilation; there is no extraction step to interact with.
- **Landmines in `AGENTS.md`.** Re-declaring the backend after
  `use PhoenixKitWeb, :live_view` still resolves to this module; the split
  concerns only which compiled module answers a lookup.

### Not changed

The comment above `use Gettext.Backend` sits between `@moduledoc` and the
`use`, which matches how the surrounding modules place such notes.
