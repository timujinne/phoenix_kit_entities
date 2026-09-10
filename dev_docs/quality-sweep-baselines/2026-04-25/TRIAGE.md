# Phase 2 — Triage Findings (2026-04-25)

Three parallel `Explore` agents ran against `lib/` and `test/` per the
playbook. Findings classified by quality-sweep scope (REFACTOR vs.
NEW FEATURE — see [feedback_quality_sweep_scope.md](../../../../..the agent memory note `feedback_quality_sweep_scope.md`).

## In scope (REFACTOR — fix in this sweep)

### Activity logging coverage gaps (C4)

- **`bulk_update_status/2` and `bulk_delete/1`** at
  `entity_data.ex` — call `repo().update_all/delete_all` directly,
  bypassing `notify_data_event/2` entirely. Need batch-level activity
  log entries (action + count + filter UUIDs).
- **`enable_system/0` and `disable_system/0`** at
  `phoenix_kit_entities.ex` — call `Settings.update_boolean_setting_with_module/3`
  with no activity log. Need `module.entities.enabled` /
  `module.entities.disabled` action atoms.
- **Translation mutations** (`set_entity_translation/3`,
  `EntityData.set_translation/3`) — pipe through `update_entity` /
  `__MODULE__.update`, which DOES log `entity.updated` /
  `entity_data.updated`, but the metadata loses the translation
  context (which language, which fields). Need a dedicated
  `translation_set` action with `language` + `fields_changed` keys.
- **Error-path coverage** — `notify_*_event` only fires on `{:ok, _}`.
  When a user-initiated mutation fails the changeset, no activity row
  exists. Per playbook: log the user-initiated action with a
  `db_pending: true` flag on the error branch too.

### Async / cleanliness (C5 + C6)

- **6× `Task.start(fn -> Exporter.export_entity(...) end)`** at
  `phoenix_kit_entities.ex:328,336`,
  `entity_data.ex:455,464`,
  `web/entities_settings.ex:449`,
  `controllers/entity_form_controller.ex:466`. Forbidden — must be
  `Task.start_link/1` (LV-coupled lifecycle) or
  `Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, _)` for
  fire-and-forget after-DB-commit work.
- **`@spec` gaps** — `PhoenixKitEntities` has 58 public fns, 4 specs.
  `EntityData` has ~20 unspecced public fns. Add at minimum on the
  CRUD surface, query helpers, and the multilang/translation API.
- **Rate-limiter rescue** at `entity_form_controller.ex:257-259` is
  `rescue _ -> :ok`. Narrow to `Hammer.BackendUnavailableError` (or
  whatever Hammer raises) so genuine bugs surface.
- **Stats-task rescue** at `entity_form_controller.ex:483-485` is
  `rescue _ -> :ok`. Narrow to expected transient failures
  (`Ecto.StaleEntryError` etc.) and log the rest.

### Translations / gettext (C5)

- **`field_types.ex:301-310` `category_list/0`** returns hardcoded
  English category labels (`"Basic"`, `"Numeric"`, etc.) as string
  literals. Not extractable. Convert to `defp category_label/1`
  clauses with `gettext("Basic")` etc.
- **`sitemap_source.ex:303` `String.capitalize(entity.name)`** — name
  is programmatic but renders user-visible. Switch to
  `entity.display_name || entity.display_name_plural || entity.name`
  (no capitalize).

### Errors module (C3)

- No `PhoenixKitEntities.Errors` module exists. Surface atoms include
  at least: `:cannot_remove_primary` (multilang), `:not_multilang`
  (multilang), import/export error tuples, plus any new error
  atoms introduced when refactoring raw error strings to atoms in C3.

### Test coverage (C8 / C10)

- `bulk_update_status/2`, `bulk_delete/1`, `bulk_update_positions/2`
  have zero tests.
- `enable_system/0` and `disable_system/0` only assert exports, not
  behaviour or activity log.
- `set_entity_translation/3` and `EntityData.set_translation/3` have
  no activity-log assertions.
- 5 admin LiveViews have NO smoke-test files (LV smoke tests added
  in C10 with full delta-pinning).

## Hardening (decided 2026-04-25 — landing in this sweep)

After Max review, three findings re-classified as REFACTOR-SHAPED
defect fixes to existing logic (the rate limiter is broken without
IP validation; the JSONB column has no caps; the path setting has no
containment). Landing in C5/C6 commits, framed as "hardening":

- **X-Forwarded-For unvalidated** at
  `controllers/entity_form_controller.ex:418-431`. Without format
  validation an attacker spoofs the header to bypass rate limiting
  (each fake IP gets its own bucket). Add IP-format guard +
  RFC1918/loopback rejection before using the value as a rate-limit
  key.
- **Metadata size caps** at
  `controllers/entity_form_controller.ex:395-416`. User-agent and
  referer stored uncapped in JSONB. Add `String.slice/3` cap (255
  chars) and drop or truncate referer.
- **Mirror path containment** at `mirror/storage.ex:96-120`.
  Admin-editable setting feeds into a filesystem write. Add
  `Path.expand` + boundary check so the export base directory can't
  escape the project's `priv/entities` root.

## Out of scope (NEW FEATURE — surface to Max separately)

- **Public form unauthenticated POST** at
  `controllers/entity_form_controller.ex:58-77` — by design (it's
  the public form submission contract). Auth would be a behaviour
  change, not a refactor.
- **`--output PATH` in mix tasks** (`mix_tasks/{export,import}.ex`).
  Lower-risk than the storage setting (the user runs the task
  themselves) — defer to a separate hardening pass if needed.

## Verified false alarms (not bugs)

- **Mirror concurrent-write race** — `Storage.write_entity` does
  full-file overwrite, not append. Concurrent writes are last-writer-
  wins, not corrupted. Pattern is fine as-is.
- **Public form field allowlist no caching** — fresh per-submission
  read is the correct design. Caching would *introduce* a TOCTOU
  window, not fix one.

## Passing categories (verified clean)

- All 5 admin LiveViews have `handle_info/2` catch-all clauses
  (added in commit `7b68d91`).
- PubSub topics all come from named functions in
  `PhoenixKitEntities.Events` and `Presence` helpers — no hardcoded
  strings.
- Broadcasts fire after DB writes (`notify_*_event` pipes through
  the `:ok` branch only).
- Broadcast payloads carry only IDs (`{:event_name, entity_uuid}`),
  no full records or PII.
- Mass-assignment risk: both `Entity` and `EntityData` changesets
  use explicit `cast/3` allowlists.
- `@type t :: %__MODULE__{}` present on both Ecto schemas.
- `IO.inspect`, `# TODO`, `# FIXME`, commented-out `def` lines —
  none found outside `@doc` examples.
- `UrlResolver` rescues already narrowed in this branch (PR #8 batch).

## Counts

| Severity | In scope | Out of scope |
|---------|----------|--------------|
| HIGH | 8 | 4 |
| MEDIUM | 7 | 3 |
| LOW | 4 | 0 |
