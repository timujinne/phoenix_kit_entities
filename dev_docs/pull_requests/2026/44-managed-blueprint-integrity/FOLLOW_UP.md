# PR #44 — Follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Multilang save locked out for rows without a stored primary `_slug` | BUG - HIGH | Fixed: `Managed.stored_lang_slug/4` falls back to the `slug` column for the primary language. 3 unit tests + 1 LV test. |
| Bulk delete → N full reloads per open admin page | IMPROVEMENT - HIGH | Fixed: `Events.flush_data_events/0`, called by `DataNavigator` and `EntitiesSettings` before reloading. Unit test in `events_test.exs`. |
| `Routes.local_path?/1` newer than the `~> 2.0` floor | IMPROVEMENT - MEDIUM | Not fixed: the effective floor is already higher (V169 / 2.4.0), and only catalogue writes `managed_path`. Rationale in `CLAUDE_REVIEW.md`. |
| `:locked_key` reset drops other unsaved edits | NITPICK | Not fixed: reachable only through a forged payload. |
| Create/delete gaps on value records | NITPICK | Agreed scope decision; no change. |
