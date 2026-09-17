# PR #49 Review — Migrate number/decimal field inputs to core's `<.decimal_input>`

**Reviewer:** Claude
**Author:** Timujeen (`timujinne/feat/decimal-input`)
**Merge:** `37d6641` (changes in `8532c59`..`069b040`)
**Date:** 2026-09-16
**Verdict:** Approve with fixes. The migration is sound, and the review rounds
inside the PR already closed the public-form bypasses. One release-blocking
dependency floor and one crash on malformed bounds were fixed after the merge.

---

## Summary

- `number` and `decimal` fields render a free-text `inputmode="decimal"`
  control (`<.decimal_input>` in `FormBuilder`, a bare `<input>` in
  `FieldInput` so `join-item` layouts still work) instead of
  `<input type="number">`. Comma and dot both work, and browser `step`
  validation no longer blocks `phx-submit`.
- Parsing goes through core's `Number.parse_decimal/2` on the admin path
  (`FormBuilder.validate_type/2`) and in the final gate
  (`EntityData.changeset/2`). `min`/`max` are now enforced server-side for
  `number` too, because the browser no longer does it.
- `EntityData.normalize_numeric_data/1` casts public-form values through
  `FormBuilder.cast_field/2`, so both write paths store the same shape.
- `decimal` keeps the scale that was typed (`restore_typed_scale/2`), because
  `parse_decimal/2` strips trailing zeros.

### Verified

- `restore_typed_scale/2` uses the same separator rule as core's
  `normalize_decimal_text/1` (mixed separators → the last one is the point;
  a repeated single kind is grouping). `Decimal.round/2` only pads zeros back.
  It cannot change the value.
- Removing the browser `min="1" max="100"` from the entity form's
  "Max File Size (MB)" is safe: `process_max_file_size/1` clamps to
  1–100 MB on the server.
- On a malformed stored value (a map, a boolean), `normalize_numeric_data/1`
  leaves it alone, and `validate_*_field/3` still rejects it.

---

## Findings

### 1. BUG - HIGH — Core floor `~> 2.0` admits cores that cannot compile this package — FIXED

`FormBuilder` does `import PhoenixKitWeb.Components.Core.DecimalInput`, and
three modules call `PhoenixKit.Utils.Number.parse_decimal/2` /
`format_decimal/1`. Both first shipped in phoenix_kit **2.26.0**. The pin
stayed `~> 2.0`, so a host on core 2.0–2.25 would resolve this release and fail
to compile it (`import` of a module that does not exist).

**Fix:** pin raised to `~> 2.26` (still two segments, so every later 2.x
matches). `test/core_pin_conformance_test.exs` now requires the floor
(2.26.0 / 2.27.0 / 2.99.4 admitted; 2.0.0 / 2.25.9 rejected). The mix.exs
comment and AGENTS.md "Depends on" / landmine notes were updated too.

### 2. BUG - MEDIUM — Unreadable `min`/`max` crashes every save of the record — FIXED

`EntityData.validate_number_field/3` and `validate_decimal_field/3` passed
`field_def["min"]` / `["max"]` directly to `Number.parse_decimal/2`. That
function **raises** `ArgumentError` on a bound it cannot read (`""`, `"abc"`,
a map) and `Decimal.Error` on `"NaN"`. Field definitions arrive via mirror
import and the API, so a bad value there is data, not a programming error.
`FormBuilder.compare_bound/2` already documents the rule that a bad bound is
ignored. The changeset broke that rule on both write paths: an admin save
crashed the LiveView, and a public submit returned a 500.

`FormBuilder` had the same bug for a `"NaN"` bound: `Decimal.parse/1` accepts
it, but `Decimal.compare/2` raises. Before this PR that only affected
`decimal`. The PR started checking bounds on `number`, so it affected
`number` too.

**Fix:** `EntityData.numeric_bounds/1` turns each bound into a number, a
`Decimal` or `nil`. It ignores anything unreadable, including NaN.
`compare_bound/2` now treats a NaN limit as "no bound". Tests:
`entity_data_changeset_test.exs` ("malformed numeric bounds in a field
definition") and `form_builder_validation_test.exs` ("with a NaN bound").
Both failed with `Decimal.Error` before the fix.

### 3. IMPROVEMENT - MEDIUM — The 10¹² magnitude ceiling now applies to existing data — NOT FIXED (documented)

`parse_decimal/2` rejects any magnitude ≥ 10¹² (and any text over 64 bytes).
Before this PR, `number` accepted any float and `decimal` had no ceiling. If a
record already stores a larger value (a millisecond Unix timestamp is
~1.7·10¹²), that record fails validation the next time anything on it is
saved, with "must be a number" / "must be a valid number".

Not fixed. The ceiling is core's deliberate guard against pasted
`1e1000000`-class input, and copying the parser here to skip it would create
the drift the PR works to avoid. A field that needs values this large should
be a `text` field. Recorded in the CHANGELOG.

A related inconsistency: `FormBuilder.validate_type/2`'s already-numeric
clauses (integer, float, `%Decimal{}`) go straight to `apply_decimal_bounds/2`
and skip the ceiling. The changeset applies it anyway, so storage stays
consistent. Only the error message differs by path.

### 4. NITPICK — Out-of-bounds values report "must be a number" in the changeset — NOT FIXED

A public submission of `-1` into a `min: 0` field fails with "field 'Price'
must be a number", not a bounds message. Fixing it needs new
`field '%{label}' must be at least %{min}`-style msgids in three
hand-maintained catalogues. The admin form already shows the precise message
from `FormBuilder`, so this was left alone.

### 5. NITPICK — Entity is now fetched three times per changeset — NOT FIXED

`sanitize_rich_text_data/1`, the new `normalize_numeric_data/1` and
`validate_data_against_entity/1` each load the entity. This follows the
existing pattern. Passing the entity through the pipeline would be a separate
refactor.

### 6. NITPICK — `FieldTypes.decimal_step/1` is no longer used by any renderer — NOT FIXED

It is public API and still tested, so it stays. Its `@doc` (and
`decimal_input_value/1`'s) still explain behaviour in terms of
`<input type="number">`, and a field definition's `"step"` prop no longer
affects rendering.
