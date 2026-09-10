# Entity data lifecycle

How manual ordering and the trash (soft-delete) work for entity definitions and
entity data records.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions.

## Drag-and-drop reorder API

Both lists carry an integer `position` column that drives manual sort.

- `Entities.reorder_entities(ordered_uuids, opts)` — re-indexes the
  entity definitions to positions `1..N`. Logs `entity.reordered`,
  broadcasts `:entity_updated` for sidebar cache invalidation. Capped
  at 1000 uuids; oversized rejects with `{:error, :too_many_uuids}`
  AND audit-logs the rejection (`db_pending: true`,
  `rejected: "too_many_uuids"`).
- `EntityData.reorder(entity_uuid, ordered_uuids, opts)` — re-indexes
  records within one entity. The DB layer enforces the entity_uuid
  scope so a stray cross-entity uuid in the input list cannot rewrite
  positions in the wrong scope (every per-uuid `update_all`
  AND-filters on `entity_uuid`). Same 1000-cap + dedup behavior.
- Both functions log on `:ok` AND `:error` branches; the error branch
  carries `db_pending: true` so the audit trail covers user-initiated
  intent even when the transaction rolls back.
- The `:ok` row is emitted only when the transaction actually wrote a
  row. `EntityData.reorder/3` counts rows written, not pairs submitted —
  a uuid naming a record in another entity matches nothing (that is what
  the scope is for), and neither does a concurrently deleted one — so a
  save that moved nothing records nothing rather than logging a
  non-event.
- LV call sites (`Web.Entities`, `Web.DataNavigator`) thread
  `actor_opts(socket)` so the activity rows pin `actor_uuid`. The
  DataNavigator auto-flips `sort_mode` to `"manual"` on the first
  drag and emits a `Logger.warning` so ops can see the implicit
  setting change.

**Audit row shape** — every reorder path emits an `ActivityLog` row:

| Field                  | Success                           | DB error                | Rejected (`:too_many_uuids`) |
|------------------------|-----------------------------------|-------------------------|-------------------------------|
| `action`               | `entity.reordered` / `entity_data.reordered` | same              | same                          |
| `actor_uuid`           | from caller opts                  | same                    | same                          |
| `resource_type`        | `entity` / `entity_data`         | same                    | same                          |
| `resource_uuid`        | first uuid in list                | first uuid in list      | nil                           |
| `metadata.count`       | rows written                      | n (pairs)               | n (pairs)                     |
| `metadata.entity_uuid` | data path only                    | data path only          | data path only                |
| `metadata.db_pending`  | absent                            | `true`                  | `true`                        |
| `metadata.rejected`    | absent                            | absent                  | `"too_many_uuids"`            |

## Soft-delete (trash) for EntityData

EntityData records support soft-delete via the `status` column with the
sentinel `"trashed"` (workspace convention — same as publishing posts).
The row stays alive in the DB so parent-app FK references stay
satisfied; default `list_*` queries hide trashed rows.

**Why this matters.** Parent apps commonly use entity_data records as
controlled vocabularies (e.g. `orders.status_uuid → phoenix_kit_entity_data(uuid)`,
NOT NULL). Hard-deleting via `Repo.delete` triggers the parent's FK
action — `:nilify_all` violates NOT NULL, `:restrict` blocks, `:delete_all`
cascades — and the admin sees an opaque 500. Soft-delete sidesteps all
three: the row survives, the parent's FK keeps resolving, and the
admin can restore later or permanently delete once references clear.

**Public API:**

- `EntityData.trash/2` — flips status to `"trashed"`. Refuses
  `{:error, :already_trashed}` for already-trashed rows. Logs
  `entity_data.trashed`.
- `EntityData.restore_from_trash/2` — flips trashed → published.
  Refuses `{:error, :not_trashed}` for non-trashed rows. Logs
  `entity_data.restored`.
- `EntityData.bulk_trash/2` + `bulk_restore_from_trash/2` — batched
  versions; emit ONE `entity_data.bulk_trashed` /
  `entity_data.bulk_restored` audit row per call. Skip already-state
  rows via the WHERE clause.
- `EntityData.list_trashed_by_entity/2` + `trashed_count/1` — surface
  trashed rows for the admin trash bin.
- `EntityData.delete/2` + `bulk_delete/2` — hard-delete.
  **Wrapped in a Postgrex / Ecto.ConstraintError rescue** that catches
  FK / NOT NULL violations and returns
  `{:error, :referenced_by_external}` so the admin LV can render a
  friendly flash via `Errors.message(:referenced_by_external)` instead
  of 500. Re-raises any other constraint error so real bugs surface.
  The child check is folded INSIDE the delete transaction and returns
  the more accurate `{:error, :has_children}`; trashed children have
  their `parent_uuid` nulled first so the self-FK does not block the
  parent's delete.

**Default-list filtering.** `list_all`, `list_by_entity`,
`search_by_title`, `count_by_entity`, and `get_data_stats` exclude
trashed by default; pass `include_trashed: true` to surface them
(used by reverse-reference checks and the admin trash view).
`get_by_slug/3` is intentionally NOT filtered — slug uniqueness must
survive trashing so a restored row doesn't collide with a
freshly-created replacement.

**Reverse-reference hook.** Parent apps with FK columns to
entity_data can declare count callbacks via `Application` config:

```elixir
config :phoenix_kit_entities,
  reverse_references: [
    {"order_status", &MyApp.Orders.count_orders_with_status/1},
    {"sub_order_status", &MyApp.Orders.count_sub_orders_with_status/1}
  ]
```

`EntityData.count_external_references/1` resolves the entity name to
matching callbacks and sums them. Multiple callbacks per entity name
are fine — they all contribute (e.g. `orders` + `audit_log` both
referencing the same `order_status` add together). Informational
only, **NOT a delete-blocker** — soft-delete is safe regardless of
the count.

The `:reverse_references` key lives in the **global** OTP application
env, so in an umbrella where two parent apps both define a callback
for the same entity name (e.g. both register `"order_status"`), both
callbacks fire on every `count_external_references/1` call and the
totals add. For a single-tenant deploy this is irrelevant; multi-
tenant hosts should pick distinct entity names per app or accept
the cross-pollination.

The 1-arity form preloads `:entity` per call. When rendering many
records (admin trash bin, list views), prefer the 2-arity form
`count_external_references(record, entity)` and load the entity
once outside the loop to skip the N+1.

**Admin UX (DataNavigator).** Bulk Delete soft-trashes by default;
permanent delete is a separate action available only from the Trash
filter view (`status=trashed` query param). Per-record buttons branch
by status: published/draft → Archive + Trash, archived → Restore +
Trash, trashed → Restore-from-trash + Delete-forever. The
`toggle_status` cycle skips trashed (Restore is the only escape).
