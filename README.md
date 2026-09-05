# PhoenixKitEntities

Dynamic content types for PhoenixKit. Define custom entities (like "Product", "Team Member", "FAQ") with flexible field schemas — no database migrations needed per entity.

## Table of Contents

- [What this provides](#what-this-provides)
- [Quick start](#quick-start)
- [Dependency types](#dependency-types)
- [Project structure](#project-structure)
- [Entity definitions](#entity-definitions)
- [Entity data records](#entity-data-records)
- [Field types](#field-types)
- [Admin UI](#admin-ui)
- [Multi-language support](#multi-language-support)
- [Public forms](#public-forms)
- [Filesystem mirroring](#filesystem-mirroring)
- [Events & PubSub](#events--pubsub)
- [Available callbacks](#available-callbacks)
- [Mix tasks](#mix-tasks)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

## What this provides

- Dynamic entity definitions with JSONB field schemas (no migrations per entity)
- 16 field types: text, textarea, email, url, rich_text, heading, number, decimal, boolean, date, select, radio, checkbox, file, image, video
- Complete admin UI (LiveView) for managing entity definitions and data records
- Multi-language support (auto-enabled when 2+ languages are active)
- Collaborative editing with FIFO locking and presence tracking
- Public form builder with honeypot, time-based validation, and rate limiting
- Filesystem mirroring for export/import of entity definitions and data
- PubSub events for real-time updates across admin sessions
- Sitemap integration for published entity data
- Zero-config auto-discovery — just add the dependency

## Quick start

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_entities, "~> 0.3"}
```

Run `mix deps.get` and start the server. The module appears in:

- **Admin sidebar** (under Modules section) — browse entities and their data
- **Admin > Modules** — toggle it on/off
- **Admin > Roles** — grant/revoke access per role
- **Admin > Settings > Entities** — configure module settings

Enable the system:

```elixir
PhoenixKitEntities.enable_system()
```

Create your first entity:

```elixir
{:ok, entity} = PhoenixKitEntities.create_entity(%{
  name: "product",
  display_name: "Product",
  display_name_plural: "Products",
  icon: "hero-cube",
  created_by_uuid: admin_user.uuid,
  fields_definition: [
    %{"type" => "text", "key" => "name", "label" => "Name", "required" => true},
    %{"type" => "number", "key" => "price", "label" => "Price"},
    %{"type" => "textarea", "key" => "description", "label" => "Description"},
    %{"type" => "select", "key" => "category", "label" => "Category",
      "options" => ["Electronics", "Clothing", "Food"]}
  ]
})
```

Create data records:

```elixir
{:ok, record} = PhoenixKitEntities.EntityData.create(%{
  entity_uuid: entity.uuid,
  title: "iPhone 15",
  status: "published",
  created_by_uuid: admin_user.uuid,
  data: %{
    "name" => "iPhone 15",
    "price" => 999,
    "description" => "Latest iPhone model",
    "category" => "Electronics"
  }
})
```

## Dependency types

### Local development (`path:`)

```elixir
{:phoenix_kit_entities, path: "../phoenix_kit_entities"}
```

Changes to the module's source are picked up automatically on recompile.

### Git dependency (`git:`)

```elixir
{:phoenix_kit_entities, git: "https://github.com/BeamLabEU/phoenix_kit_entities.git"}
```

After updating the remote: `mix deps.update phoenix_kit_entities`, then `mix deps.compile phoenix_kit_entities --force` + restart the server.

### Hex package

```elixir
{:phoenix_kit_entities, "~> 0.3"}
```

## Project structure

```
lib/
  phoenix_kit_entities.ex              # Main module (schema + PhoenixKit.Module behaviour)
  phoenix_kit_entities/
    entity_data.ex                     # Data record schema and CRUD
    field_type.ex                      # Field type struct
    field_types.ex                     # Field type registry (16 types)
    form_builder.ex                    # Dynamic form generation + validation
    events.ex                          # PubSub broadcast/subscribe
    presence.ex                        # Phoenix.Presence for editing
    presence_helpers.ex                # FIFO locking, session tracking
    routes.ex                          # Admin + public route definitions
    sitemap_source.ex                  # Sitemap integration
    components/
      entity_form.ex                   # Embeddable public form component
    controllers/
      entity_form_controller.ex        # Public form submission handler
    migrations.ex                       # Module-owned V1 migration chain (pkn_schema marker)
    mirror/
      exporter.ex                      # Entity/data export to JSON
      importer.ex                      # Entity/data import from JSON
      storage.ex                       # File storage for mirror
    mix_tasks/
      export.ex                        # mix phoenix_kit_entities.export
      import.ex                        # mix phoenix_kit_entities.import
    web/
      entities.ex                      # Entity list LiveView (inline template)
      entity_form.ex                   # Entity definition builder LiveView
      data_navigator.ex                # Data record browser LiveView
      data_form.ex                     # Data record form LiveView (handles new/show/edit)
      entities_settings.ex             # Module settings LiveView
      hooks.ex                         # Shared LiveView hooks
```

## Entity definitions

Entity definitions are blueprints for custom content types. Each entity has a name, display names, and a JSONB array of field definitions.

```elixir
# List all entities
PhoenixKitEntities.list_entities()

# Get by name
PhoenixKitEntities.get_entity_by_name("product")

# Create
{:ok, entity} = PhoenixKitEntities.create_entity(%{...})

# Update
{:ok, entity} = PhoenixKitEntities.update_entity(entity, %{status: "published"})

# Delete (cascades to all data records)
{:ok, entity} = PhoenixKitEntities.delete_entity(entity)
```

### Name constraints

- Must be unique, snake_case, 2-50 characters
- Format: `^[a-z][a-z0-9_]*$`
- Examples: `product`, `team_member`, `faq_item`

### Status workflow

Entities support three statuses: `draft`, `published`, `archived`.

## Entity data records

Data records are instances of an entity definition. Field values are stored in a JSONB `data` column.

```elixir
alias PhoenixKitEntities.EntityData

# List records for an entity
EntityData.list_by_entity(entity.uuid)

# Filter by status
EntityData.list_by_entity_and_status(entity.uuid, "published")

# Search by title
EntityData.search_by_title("iPhone", entity.uuid)

# Get by slug
EntityData.get_by_slug(entity.uuid, "iphone-15")

# CRUD
{:ok, record} = EntityData.create(%{...})
{:ok, record} = EntityData.update(record, %{...})
{:ok, record} = EntityData.delete(record)
```

### Manual ordering

Both **entity definitions** (the list at `/admin/entities`) and **data records** within an entity carry an integer `position` column managed by core's V81 / V108 migrations. Two reorder surfaces are exposed:

- `Entities.reorder_entities(ordered_uuids, opts \\ [])` — re-indexes the entity list to positions `1..N` in the order given. Logs `entity.reordered` (PII-safe — count + first uuid only). Broadcasts `:entity_updated` so the dashboard sidebar's entity-summaries cache invalidates immediately. Capped at 1000 uuids; oversized payloads return `{:error, :too_many_uuids}` and still log a `db_pending` audit row so the rejected attempt is attributable.
- `EntityData.reorder(entity_uuid, ordered_uuids, opts \\ [])` — re-indexes the records of one entity. Internally enforces the `entity_uuid` scope at the DB layer so a stray cross-entity uuid in the input list cannot rewrite positions in the wrong scope. Same 1000-uuid cap and audit semantics. Broadcasts `:data_reordered` for live LV refresh.

Each entity carries a `sort_mode` setting (`"auto"` — by creation date — or `"manual"` — by `position`). Configure via:

```elixir
PhoenixKitEntities.update_sort_mode(entity, "manual")
```

The DataNavigator admin LV auto-flips an entity to `"manual"` on the first drag (otherwise the visible reorder would snap back on the next refresh) and emits a `Logger.warning` so ops can see the implicit setting change. To opt entities-list reorder out for non-admin pages, gate the LV call site on `Scope.admin?/1` — the context API itself is not auth-gated.

```elixir
# Reorder entity definitions
:ok = PhoenixKitEntities.reorder_entities([uuid_b, uuid_a, uuid_c], actor_uuid: admin.uuid)

# Reorder data records within one entity
:ok = PhoenixKitEntities.EntityData.reorder(entity.uuid, [r3.uuid, r1.uuid, r2.uuid], actor_uuid: admin.uuid)
```

## Field types

| Category | Types | Notes |
|----------|-------|-------|
| Basic | `text`, `textarea`, `email`, `url`, `rich_text`, `heading` | Rich text is HTML-sanitized; `heading` is display-only |
| Numeric | `number`, `decimal` | `number` casts through floats; `decimal` is exact (money) — `scale` sets the places (default 4), `step` the input's stepping |
| Boolean | `boolean` | Toggle/checkbox |
| Date | `date` | Date picker |
| Choice | `select`, `radio`, `checkbox` | Require `options` array |
| Media | `file`, `image`, `video` | `file` uploads; `image`/`video` store a media-library reference |
| Relations | `relation` | Coming soon |

Each field definition is a map with:

```elixir
%{
  "type" => "text",          # Required
  "key" => "title",          # Required, unique per entity
  "label" => "Title",        # Required
  "required" => true,        # Optional, default false
  "default" => "",           # Optional
  "options" => ["A", "B"],   # Required for select/radio/checkbox
  "validation" => %{...}     # Optional validation rules
}
```

Use the helper functions:

```elixir
alias PhoenixKitEntities.FieldTypes

FieldTypes.text_field("name", "Full Name", required: true)
FieldTypes.select_field("category", "Category", ["Tech", "Business"])
FieldTypes.boolean_field("featured", "Featured", default: true)
```

## Admin UI

Admin routes are registered via `PhoenixKitEntities.Routes` (returned by `route_module/0`):

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/admin/entities` | `Web.Entities` | List all entity definitions |
| `/admin/entities/new` | `Web.EntityForm` | Create entity definition |
| `/admin/entities/:id/edit` | `Web.EntityForm` | Edit entity definition |
| `/admin/entities/:name/data` | `Web.DataNavigator` | Browse entity records |
| `/admin/entities/:name/data/new` | `Web.DataForm` | Create record |
| `/admin/entities/:name/data/:uuid` | `Web.DataForm` | Edit record |
| `/admin/settings/entities` | `Web.EntitiesSettings` | Module settings |

## Multi-language support

Multilang is auto-enabled when PhoenixKit has 2+ languages configured. Both the entity definition (labels/description) and each data record support translations.

### Entity definition translations

Translatable fields: `display_name`, `display_name_plural`, `description`.

Storage: `entity.settings["translations"]` JSONB.

```elixir
%{
  "translations" => %{
    "es-ES" => %{
      "display_name" => "Producto",
      "display_name_plural" => "Productos",
      "description" => "Catálogo de productos"
    }
  }
}
```

Only fields that differ from the primary language need to be stored — missing keys fall back to the primary column value on read.

**Editing (admin UI):** the entity create/edit form renders language tabs above the translatable fields. No opt-in required — tabs appear automatically when the Languages module has 2+ languages.

**API:**

```elixir
alias PhoenixKitEntities, as: Entities

# Read
Entities.get_entity_translations(entity)
# => %{"es-ES" => %{"display_name" => "Producto", ...}}

Entities.get_entity_translation(entity, "es-ES")
# => %{"display_name" => "Producto", "display_name_plural" => "Productos", ...}

# Write (empty string removes a per-field override)
Entities.set_entity_translation(entity, "es-ES", %{"display_name" => "Producto"})

# Remove all translations for a language
Entities.remove_entity_translation(entity, "es-ES")
```

### Reading translated metadata

Every query function accepts an optional `lang:` keyword. When provided, the returned struct has `display_name` / `display_name_plural` / `description` resolved to that locale (missing fields fall back to primary):

```elixir
Entities.list_entities(lang: "es-ES")
Entities.list_active_entities(lang: "es-ES")
Entities.get_entity(uuid, lang: "es-ES")
Entities.get_entity!(uuid, lang: "es-ES")
Entities.get_entity_by_name("product", lang: "es-ES")
Entities.list_entity_summaries(lang: "es-ES")  # sidebar/navigation summaries
```

Without `lang:`, raw primary-language column values are returned (backward compatible).

Manual resolution is also available:

```elixir
resolved = Entities.resolve_language(entity, "es-ES")
resolved_list = Entities.resolve_languages(entities, "es-ES")
```

### Data record translations

Field values inside `entity_data.data` use a nested JSONB structure with a primary-language marker:

```elixir
%{
  "_primary_language" => "en-US",
  "en-US" => %{"_title" => "Hello", "body" => "..."},
  "es-ES" => %{"_title" => "Hola"}   # overrides only
}
```

The `_title` key carries the translated title (the DB `title` column still stores the primary-language title). All `EntityData` query functions accept `lang:` for automatic resolution:

```elixir
alias PhoenixKitEntities.EntityData

EntityData.get!(uuid, lang: "es-ES")
EntityData.list_by_entity(entity_uuid, lang: "es-ES")
EntityData.search_by_title("Hola", entity_uuid, lang: "es-ES")
EntityData.published_records(entity_uuid, lang: "es-ES")
EntityData.get_by_slug(entity_uuid, "my-slug", lang: "es-ES")
```

See `lib/phoenix_kit_entities/OVERVIEW.md` § "Multi-Language Support" for the full translation API (title translations, primary-language changes, compact-mode tabs).

## Public URL resolution

`PhoenixKitEntities.EntityData` exposes locale-aware URL builders for public-facing links (replaces the hand-wired `"/#{record.slug}"` pattern that silently drops locale prefixes on non-default routes).

### Pattern resolution chain

1. `entity.settings["sitemap_url_pattern"]` — per-entity override (e.g. `"/blog/:slug"`)
2. Router introspection — explicit route (`live "/pages/:slug", ...`) or catchall (`/:entity_name/:slug`)
3. Per-entity setting `sitemap_entity_<name>_pattern`
4. Global setting `sitemap_entities_pattern` (with `:entity_name` / `:slug` / `:id` placeholders)
5. Fallback `/<entity_name>/:slug`

Placeholders: `:slug` (falls back to the record UUID when the slug is nil) and `:id` (the UUID).

### Locale prefix policy

Matches `PhoenixKit.Utils.Routes.path/2`:

- `locale:` omitted or `nil` → no prefix
- Single-language mode → no prefix
- Locale matches the primary language → no prefix (default locale served at the unprefixed URL)
- Other locales → prefixed with the base code (`/es/...`, `/ru/...`)

### Helpers

```elixir
alias PhoenixKitEntities.EntityData

EntityData.public_path(entity, record)
# => "/products/my-item"

EntityData.public_path(entity, record, locale: "es-ES")
# => "/es/products/my-item"

EntityData.public_path(entity, record, locale: "en-US")  # primary language
# => "/products/my-item"

EntityData.public_url(entity, record, base_url: "https://shop.example.com")
# => "https://shop.example.com/products/my-item"

# Batch usage — pre-build the routes cache once
cache = PhoenixKitEntities.UrlResolver.build_routes_cache()
Enum.map(records, &EntityData.public_path(entity, &1, locale: locale, routes_cache: cache))
```

If `:base_url` is omitted, `public_url/3` falls back to the `site_url` setting.

## Public forms

Entities can expose public submission forms. Enable in entity settings, then embed:

```html
<EntityForm entity_slug="contact" />
```

Or use the controller endpoint. Public forms include:
- Honeypot field for bot detection
- Time-based validation (minimum 3 seconds)
- Rate limiting (5 submissions per 60 seconds)
- Browser/OS/device metadata capture

## Filesystem mirroring

Export and import entity definitions and data as JSON files:

```bash
mix phoenix_kit_entities.export
mix phoenix_kit_entities.import
```

Or programmatically:

```elixir
PhoenixKitEntities.Mirror.Exporter.export_all(path)
PhoenixKitEntities.Mirror.Importer.import_all(path)
```

## Events & PubSub

Subscribe to real-time events:

```elixir
alias PhoenixKitEntities.Events

# Entity lifecycle
Events.subscribe_to_entities()
# Receives: {:entity_created, uuid}, {:entity_updated, uuid}, {:entity_deleted, uuid}

# Data lifecycle (all entities)
Events.subscribe_to_all_data()
# Receives: {:data_created, entity_uuid, data_uuid}, etc.

# Data lifecycle (specific entity)
Events.subscribe_to_entity_data(entity_uuid)
```

## Available callbacks

This module implements `PhoenixKit.Module` with these callbacks:

| Callback | Value |
|----------|-------|
| `module_key/0` | `"entities"` |
| `module_name/0` | `"Entities"` |
| `enabled?/0` | Reads `entities_enabled` setting |
| `enable_system/0` | Sets `entities_enabled` to true |
| `disable_system/0` | Sets `entities_enabled` to false |
| `permission_metadata/0` | Icon: `hero-cube-transparent` |
| `admin_tabs/0` | Entities tab with dynamic entity children |
| `settings_tabs/0` | Settings tab under admin settings |
| `children/0` | `[PhoenixKitEntities.Presence]` |
| `css_sources/0` | `[:phoenix_kit_entities]` |
| `route_module/0` | `PhoenixKitEntities.Routes` |
| `get_config/0` | Returns enabled status, limits, stats |

## Mix tasks

```bash
# Export all entities and data to JSON
mix phoenix_kit_entities.export

# Import entities and data from JSON
mix phoenix_kit_entities.import
```

## Database

The entities tables are created by core's `V17` migration and evolved by `V40` / `V58` / `V67` / `V74` / `V81`; the host app still runs `PhoenixKit.Migrations.up()` once and gets that baseline shape. As of this version, `PhoenixKitEntities.Migrations` (V1, the `pkn_schema:` marker on `phoenix_kit_entities`) additionally owns the tables' future shape: it is discovered via `migration_module/0` and run automatically by `mix phoenix_kit.update`, and its `down/1` only unstamps the marker — it never drops the tables.

```elixir
# Two tables:
# phoenix_kit_entities       — entity definitions (blueprints)
# phoenix_kit_entity_data    — data records (instances)
# Both use UUIDv7 primary keys
```

## Testing

```bash
# Create test database
createdb phoenix_kit_entities_test

# Run all tests
mix test

# Run only unit tests (no DB needed)
mix test --exclude integration
```

## Troubleshooting

### Module not appearing in admin

1. Verify the dependency is in `mix.exs` and `mix deps.get` was run
2. Check `PhoenixKitEntities.enabled?()` returns `true`
3. Run `PhoenixKitEntities.enable_system()` if needed

### "entities_enabled" setting not found

The settings are seeded by core's `V17` migration. Run `PhoenixKit.Migrations.up()` in the host app to create them.

### Entity name validation fails

Names must be snake_case, start with a letter, 2-50 characters. Examples: `product`, `team_member`, `faq_item`. Invalid: `Product`, `123abc`, `a`.

### Changes not taking effect after editing

Force a clean rebuild: `mix deps.clean phoenix_kit_entities && mix deps.get && mix deps.compile phoenix_kit_entities --force && mix compile --force`

> **Note:** Core PhoenixKit creates the entities tables (`V17`, evolved by `V40` / `V58` / `V67` / `V74` / `V81`), and `PhoenixKitEntities.Migrations` (V1) owns their shape from here on — see [Database](#database) above. The test suite builds its schema by running `PhoenixKit.Migrations.up()` against an isolated test repo — the same call the host app makes — so test schema and production schema cannot drift apart.
