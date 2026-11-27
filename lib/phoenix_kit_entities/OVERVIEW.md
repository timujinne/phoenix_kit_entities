# PhoenixKit Entities System

PhoenixKit's Entities layer is a dynamic content type engine. It lets administrators define custom content types at runtime, attach structured fields, and manage records without writing migrations or shipping new code. This README gives a full overview so a developer (or AI teammate) can understand what exists, how it fits together, and how to extend it safely.

---

## High-level capabilities

- **Entity blueprints** – Define reusable content types (`phoenix_kit_entities`) with metadata, singular/plural labels, icon, status, JSON field schema, and optional custom settings.
- **Dynamic fields** – 12 built-in field types (text, textarea, number, boolean, date, email, URL, select, radio, checkbox, rich text, file). Field definitions live in JSONB and are validated at creation time. `relation` fields link a record to records of another entity (see "Relation fields" below).
- **Entity data records** – Store instances of an entity (`phoenix_kit_entity_data`) with slug support, status workflow (draft/published/archived), JSONB data payload, metadata, creator tracking, and timestamps.
- **Admin UI** – LiveView dashboards for managing blueprints, browsing/creating data, filtering, and adjusting module settings.
- **Settings + security** – Feature toggle and max entities per user are enforced; additional settings (relation/file flags, auto slugging, etc.) are persisted in `phoenix_kit_settings` but reserved for future use. All surfaces are gated behind the admin scope.
- **Statistics** – Counts and summaries for dashboards and monitoring.
- **URL Resolution Engine** – Robust path resolution logic that introspects the router and entity settings to generate localized public URLs for records.
- **Public Form Builder** – Create embeddable forms for public-facing pages with security features (honeypot, time-based validation, rate limiting), configurable actions, and submission statistics.

---

## Folder structure

```
lib/modules/entities/
├── entities.ex          # Entity schema + business logic
├── entity_data.ex       # Data record schema + CRUD helpers
├── url_resolver.ex      # URL resolution engine for public paths
├── field_types.ex       # Registry of supported field types
├── form_builder.ex      # Dynamic form rendering + validation helpers
├── multilang.ex         # Multi-language data transformation helpers
├── html_sanitizer.ex    # XSS prevention for rich_text fields
├── presence.ex          # Phoenix.Presence for real-time collaboration
├── presence_helpers.ex  # FIFO locking and presence utilities
├── events.ex            # PubSub event broadcasting
├── OVERVIEW.md          # High-level guide (this file)
├── DEEP_DIVE.md         # Architectural deep dive
├── mirror/              # Entity definition/data mirroring to filesystem
│   ├── exporter.ex
│   ├── importer.ex
│   └── storage.ex
└── web/
    ├── entities.ex / .html.heex         # Entity dashboard
    ├── entity_form.ex / .html.heex      # Create/update entity definitions + public form config
    ├── data_navigator.ex / .html.heex   # Browse/filter records per entity
    ├── data_form.ex / .html.heex        # Create/update individual records (handles new/show/edit)
    ├── entities_settings.ex / .html.heex# System configuration
    └── hooks.ex                         # LiveView hooks for entity pages

lib/phoenix_kit_web/controllers/
└── entity_form_controller.ex        # Public form submission handler

lib/modules/publishing/components/
└── entity_form.ex                   # Embeddable public form component

lib/phoenix_kit/migrations/postgres/
├── v17.ex                           # Creates entities + entity_data tables, seeds settings
└── v81.ex                           # Adds position column for manual record ordering
```

---

## Database schema (migration V17, V81)

### `phoenix_kit_entities`
- `uuid` – primary key (UUIDv7)
- `name` – unique slug (snake_case)
- `display_name` – singular UI label
- `display_name_plural` – plural label (for menus/navigation and entity listing page)
- `description` – optional help text
- `icon` – hero icon identifier
- `status` – `draft | published | archived`
- `fields_definition` – JSONB array describing fields
- `settings` – optional JSONB for entity-specific config (includes `sort_mode`, `mirror_definitions`, `mirror_data`, `translations`, public form settings)
- `created_by_uuid` – admin user UUID
- `date_created`, `date_updated` – UTC timestamps

Indexes cover `name`, `status`, `created_by_uuid`. A comment block documents JSON columns.

**Entity settings keys:**
- `sort_mode` – `"auto"` (default, sort records by creation date) or `"manual"` (sort by position)
- `mirror_definitions` / `mirror_data` – filesystem mirroring toggles
- `translations` – nested map of language translations for display_name, etc.
- `public_form_*` – public form builder configuration

### `phoenix_kit_entity_data`
- `uuid` – primary key (UUIDv7)
- `entity_uuid` – foreign key → `phoenix_kit_entities`
- `title` – record label
- `slug` – optional unique slug per entity
- `status` – `draft | published | archived`
- `position` – integer for manual ordering (V81, auto-populated on create)
- `data` – JSONB map keyed by field definition (or multilang structure, see below)
- `metadata` – optional JSONB extras (tags, categories, etc.)
- `created_by_uuid` – admin user UUID
- `date_created`, `date_updated`

Indexes cover `entity_uuid`, `slug`, `status`, `created_by_uuid`, `title`, `(entity_uuid, position)`. FK cascades on delete.

### Seeded settings
- `entities_enabled` – boolean toggle (default `false`)
- `entities_max_per_user` – integer limit (default `100`)
- `entities_allow_relations` – boolean (default `true`)
- `entities_file_upload` – boolean (default `false`)

---

## Core modules

### `PhoenixKitEntities`
Responsible for entity blueprints:
- Schema + changeset enforcing unique names, valid field definitions, timestamps, etc.
- CRUD helpers (`list_entities/1`, `get_entity!/2`, `get_entity/2`, `get_entity_by_name/2`, `create_entity/1`, `update_entity/2`, `delete_entity/1`, `change_entity/2`). All query functions accept an optional `lang:` keyword option for language-aware results.
- Statistics (`get_system_stats/0`, `count_entities/0`, `count_user_entities/1`).
- Settings helpers (`enabled?/0`, `enable_system/0`, `disable_system/0`, `get_config/0`).
- Sort mode helpers (`get_sort_mode/1`, `get_sort_mode_by_uuid/1`, `manual_sort?/1`, `update_sort_mode/3`).
- Limit enforcement (`validate_user_entity_limit/1`).
- Language resolution (`resolve_language/2`, `resolve_languages/2`) for applying translations to entity structs.

Note: `create_entity/1` auto-fills `created_by_uuid` with the first admin user if not provided.

Field validation pipeline ensures every entry in `fields_definition` has `type/key/label` and uses a supported type. Note: the changeset validates but does not enrich field definitions—use `FieldTypes.new_field/4` to apply default properties.

### `PhoenixKitEntities.EntityData`
Manages actual records:
- Schema + changeset verifying required fields, slug format, status, and cross-checking submitted JSON against the entity definition.
- CRUD and query helpers (`list_all/1`, `list_by_entity/2`, `get!/2`, `get/2`, `search_by_title/3`, `create/1`, `update/2`, `delete/1`, `change/2`). All query functions accept an optional `lang:` keyword option for language-aware results.
- Public URL helpers (`public_path/3`, `public_url/3`) for generating localized front-end links.
- Ordering helpers (`update_position/2`, `move_to_position/2`, `reorder/2`, `bulk_update_positions/1`, `next_position/1`). Queries automatically respect the parent entity's sort mode.
- Language resolution (`resolve_language/2`, `resolve_languages/2`) for applying translations to data record structs.
- Field-level validation ensures required fields are present, numbers are numeric, booleans are booleans, options exist, etc.

Note: `create/1` auto-fills `created_by_uuid` with the first admin user if not provided. It also auto-populates `position` with the next sequential value for the entity.

### `PhoenixKitEntities.UrlResolver`
Shared engine for resolving public URLs:
- Introspects the application router for entity-specific or catchall routes.
- Respects `sitemap_url_pattern` and `sitemap_index_path` settings from entity blueprints.
- Handles locale prefixing for multi-language systems.
- Used by both the `SitemapSource` and `EntityData.public_url/3`.

### `PhoenixKitEntities.FieldTypes`
Registry of supported field types with metadata:
- `all/0`, `list_types/0`, `for_picker/0` – introspection for UI builders.
- Category helpers, default properties, and `validate_field/1` to ensure field definitions are complete.
- Field builder helpers for programmatic creation:
  - `new_field/4` – Create any field type with options
  - `select_field/4`, `radio_field/4`, `checkbox_field/4` – Choice fields with options list
  - `text_field/3`, `textarea_field/3`, `email_field/3`, `number_field/3`, `boolean_field/3`, `rich_text_field/3` – Common field types
- Used both when saving entity definitions and when rendering forms.

### `PhoenixKitEntities.Multilang`
Pure-function module for multi-language data transformations. No database calls — used by LiveViews and the convenience API.
- Global helpers: `enabled?/0`, `primary_language/0`, `enabled_languages/0`.
- Data reading: `get_language_data/2`, `get_primary_data/1`, `get_raw_language_data/2`, `multilang_data?/1`.
- Data writing: `put_language_data/3`, `migrate_to_multilang/2`, `flatten_to_primary/1`.
- Re-keying: `rekey_primary/2`, `maybe_rekey_data/1` — handles primary language changes.
- UI: `build_language_tabs/0` — builds tab data for language switcher UI.

### `PhoenixKitEntities.FormBuilder`
- Renders form inputs dynamically based on field definitions (`build_fields/3`, `build_field/3`).
- Provides `validate_data/2` and lower-level helpers to check payloads before they reach `EntityData.changeset/2`.
- Language-aware: accepts `lang_code` option to render fields for a specific language, with ghost-text placeholders showing primary language values on secondary tabs.
- Produces consistent labels, placeholders, and helper text aligned with Tailwind/daisyUI styling.

---

## LiveView surfaces

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/admin/entities` | `entities.ex` | Dashboard listing entities with table/card views (card view auto-selected on small screens) |
| `/admin/entities/new` / `/:id/edit` | `entity_form.ex` | Create/update entity definitions |
| `/admin/entities/:slug/data` | `data_navigator.ex` | Table & card views of records, search, status filters |
| `/admin/entities/:slug/data/new` / `/:id/edit` | `data_form.ex` | Create/update individual records |
| `/admin/settings/entities` | `entities_settings.ex` | Toggle module, configure behaviour |

LiveViews share a layout wrapper that expects these assigns:
- `@current_locale` – required for locale-aware paths
- `@current_path` – for sidebar highlighting
- `@project_title` – used in layout/head

All navigation helpers use `Routes.locale_aware_path/2` (or `PhoenixKit.Utils.Routes.path/2`) so URLs keep the active locale prefix (e.g., `/phoenix_kit/ru/admin/entities`).

---

## Field types at a glance

- **Basic**: `text`, `textarea`, `rich_text`, `email`, `url`
- **Numeric**: `number`
- **Boolean**: `boolean`
- **Date/Time**: `date`
- **Choice**: `select`, `radio`, `checkbox`
- **Media** *(coming soon)*: `image`, `file` – defined in schema but renders placeholder UI
- **Relations**: `relation` – links to records of another entity (see below)

### Relation fields

A `relation` field links a record to records of another entity — a panel
size to the grades it is sold in, say:

```elixir
%{
  "type" => "relation",
  "key" => "grades",
  "label" => "Grades",
  "target_entity" => grade_entity.uuid,   # or the entity's name
  "allow_multiple" => true
}
# or: FieldTypes.relation_field("grades", "Grades", grade_entity.uuid, multiple: true)
```

- **Storage**: `data["grades"]` holds the linked record's uuid, or a list of
  uuids with `allow_multiple`. Links live in the primary language only.
- **Writes** (`EntityData.create/2`, `update/3`, the admin form): a write may
  only ADD uuids that are live records of the target; links already held are
  never re-checked, so trashing a target does not block saving the records
  that point at it.
- **Reading**: `EntityData.resolve_relations(records, "grades")` returns
  `%{record_uuid => [linked_record]}` in the target's order, one query per
  target entity. Missing and trashed targets are skipped; `statuses:
  ["published"]` narrows further.
- **Deleting a target** for good removes its uuid from every record linking
  to it. Trashing keeps the link, so a restore brings it back.
- **Admin UI**: up to 50 target records render as checkboxes (or a select
  for a single link); more switch to a search box with chips. Lists and
  readonly views show titles.
- **Public forms** never accept relation values.
- **Mirror export/import** writes targets by entity name and links by record
  slug, and turns them back into local uuids on import.

Each field definition is a map like:
```elixir
%{
  "type" => "select",
  "key" => "category",
  "label" => "Category",
  "required" => true,
  "options" => ["Tech", "Business", "Lifestyle"],
  "validation" => %{}
}
```

`FormBuilder` merges default props (placeholder, rows, etc.) and renders the correct component. Validation ensures options exist when required and types match.

---

## Settings & configuration

| Setting | Description | Exposed via | Status |
|---------|-------------|-------------|--------|
| `entities_enabled` | Master on/off switch for the module | `/admin/modules`, `Entities.enable_system/0` | ✅ Active |
| `entities_max_per_user` | Blueprint limit per creator | `phoenix_kit_settings` (no UI), `Entities.get_max_per_user/0` | ✅ Active |
| `entities_allow_relations` | Whether NEW relation fields may be added (existing ones keep working) | `phoenix_kit_settings` (no UI) | ✅ Active |
| `entities_file_upload` | Reserved for future file/image upload toggle | Settings UI | 🚧 Not yet enforced |

**Per-entity settings** (stored in entity `settings` JSONB, not in `phoenix_kit_settings`):

| Setting | Description | API | Status |
|---------|-------------|-----|--------|
| `sort_mode` | Record ordering: `"auto"` or `"manual"` | `Entities.get_sort_mode/1`, `update_sort_mode/3` | ✅ Active |
| `mirror_definitions` | Filesystem mirroring of entity definition | `Entities.mirror_definitions_enabled?/1` | ✅ Active |
| `mirror_data` | Filesystem mirroring of entity data | `Entities.mirror_data_enabled?/1` | ✅ Active |
| `translations` | Translated display_name/description per language | `Entities.get_entity_translations/1` | ✅ Active |
| `public_form_*` | Public form builder configuration | Entity form UI | ✅ Active |

> **Note**: System-level settings marked "Not yet enforced" are persisted in the database and visible in the admin UI, but the underlying functionality is not yet implemented. They are placeholders for future features.

`PhoenixKitEntities.get_config/0` returns a map:
```elixir
%{
  enabled: boolean,
  max_per_user: integer,
  allow_relations: boolean,
  file_upload: boolean,
  entity_count: integer,
  total_data_count: integer
}
```

---

## Common workflows

### Enabling the module
```elixir
{:ok, _setting} = PhoenixKitEntities.enable_system()
PhoenixKitEntities.enabled?()
# => true/false
```

### Creating an entity blueprint
```elixir
# Note: created_by_uuid is optional - auto-fills with first admin user if omitted
{:ok, blog_entity} =
  PhoenixKitEntities.create_entity(%{
    name: "blog_post",
    display_name: "Blog Post",
    display_name_plural: "Blog Posts",
    icon: "hero-document-text",
    # created_by_uuid: admin.uuid,  # Optional!
    fields_definition: [
      %{"type" => "text", "key" => "title", "label" => "Title", "required" => true},
      %{"type" => "rich_text", "key" => "content", "label" => "Content"}
    ]
  })
```

### Creating fields with builder helpers
```elixir
alias PhoenixKitEntities.FieldTypes

# Build fields programmatically
fields = [
  FieldTypes.text_field("title", "Title", required: true),
  FieldTypes.textarea_field("excerpt", "Excerpt"),
  FieldTypes.select_field("category", "Category", ["Tech", "Business", "Lifestyle"]),
  FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"]),
  FieldTypes.boolean_field("featured", "Featured Post", default: false)
]

{:ok, entity} = PhoenixKitEntities.create_entity(%{
  name: "article",
  display_name: "Article",
  fields_definition: fields
})
```

### Creating a record
```elixir
# Note: created_by_uuid is optional - auto-fills with first admin user if omitted
{:ok, _record} =
  PhoenixKitEntities.EntityData.create(%{
    entity_uuid: blog_entity.uuid,
    title: "My First Post",
    status: "published",
    # created_by_uuid: admin.uuid,  # Optional!
    data: %{"title" => "My First Post", "content" => "<p>Hello</p>"}
  })
```

### Counting statistics
```elixir
PhoenixKitEntities.get_system_stats()
# => %{total_entities: 5, active_entities: 4, total_data_records: 23}
```

### Enforcing limits
```elixir
PhoenixKitEntities.validate_user_entity_limit(admin.uuid)
# {:ok, :valid} or {:error, {:user_entity_limit_reached, 100}}
```

### Language-aware queries

All list/get functions accept an optional `lang:` keyword to return structs with translated fields already resolved. When omitted, raw data is returned (backward compatible).

```elixir
alias PhoenixKitEntities
alias PhoenixKitEntities.EntityData

# Entity definitions — resolves display_name, display_name_plural, description
entities = Entities.list_entities(lang: "es-ES")
entity = Entities.get_entity!(uuid, lang: "es-ES")
entity = Entities.get_entity_by_name("products", lang: "fr-FR")
active = Entities.list_active_entities(lang: "ja-JP")

# Entity data — resolves title from _title, data to merged language fields
records = EntityData.list_by_entity(entity_uuid, lang: "es-ES")
record = EntityData.get!(uuid, lang: "fr-FR")
results = EntityData.search_by_title("Acme", entity_uuid, lang: "es-ES")
published = EntityData.published_records(entity_uuid, lang: "ja-JP")
record = EntityData.get_by_slug(entity_uuid, "acme", lang: "es-ES")

# Manual resolution (without opts)
resolved = Entities.resolve_language(entity, "es-ES")
resolved_list = EntityData.resolve_languages(records, "es-ES")
```

For the primary language (or when no translation exists for a field), the original value is returned unchanged. For secondary languages, overrides are merged onto primary values.

### Record ordering

Each entity has a sort mode (`"auto"` or `"manual"`) stored in `settings["sort_mode"]`. All listing queries respect this automatically.

```elixir
alias PhoenixKitEntities
alias PhoenixKitEntities.EntityData

# Check and change sort mode
Entities.get_sort_mode(entity)          # => "auto"
Entities.manual_sort?(entity)           # => false
{:ok, entity} = Entities.update_sort_mode(entity, "manual")

# Convenience lookup by UUID
Entities.get_sort_mode_by_uuid(entity_uuid)  # => "manual"

# Queries automatically use the right order:
# - "auto" → ORDER BY date_created DESC
# - "manual" → ORDER BY position ASC, date_created DESC
records = EntityData.list_by_entity(entity_uuid)

# Position is auto-populated on create (next sequential value)
{:ok, record} = EntityData.create(%{entity_uuid: entity_uuid, title: "New", ...})
# record.position => 5 (auto-assigned)

# Reordering operations (for drag-and-drop UI)
EntityData.move_to_position(record, 2)        # shift others to make room
EntityData.reorder(entity_uuid, ["uuid3", "uuid1", "uuid2"])  # full reorder
EntityData.update_position(record, 10)        # set position directly
EntityData.bulk_update_positions([{"uuid1", 1}, {"uuid2", 2}])  # raw bulk
```

---

## Multi-Language Support

When the **Languages module** is enabled with 2+ languages, all entities automatically support multilang content. There is no per-entity toggle — languages are configured system-wide.

### Data Structure

**Flat (single language or multilang disabled):**
```json
{"name": "Acme", "category": "Tech"}
```

**Multilang (Languages module has 2+ languages):**
```json
{
  "_primary_language": "en-US",
  "en-US": {"name": "Acme", "category": "Tech", "desc": "A company"},
  "es-ES": {"name": "Acme España"}
}
```

- `_primary_language` signals the multilang structure (cannot collide with field keys — they must match `^[a-z][a-z0-9_]*$`)
- Primary language stores ALL fields
- Secondary languages store ONLY overrides (fields that differ from primary)
- Display merges: `Map.merge(primary_data, language_overrides)`
- `title` and `slug` DB columns remain primary-language-only; secondary title translations are stored as `_title` overrides in the JSONB `data` column alongside other fields
- Entity definition translations (display_name, etc.) are in `entity.settings["translations"]`

### Translation Storage Summary

| What | Primary language | Secondary languages |
|------|-----------------|---------------------|
| Entity data (custom fields) | `data["en-US"]` | `data["es-ES"]` (overrides only) |
| Record title | `title` column + `data[primary]["_title"]` | `data["es-ES"]["_title"]` (overrides) |
| Entity display_name | `display_name` column | `settings["translations"]["es-ES"]["display_name"]` |

### Enabling Multilang

```elixir
# 1. Enable Languages module
PhoenixKit.Modules.Languages.enable_system()

# 2. Add secondary languages
PhoenixKit.Modules.Languages.add_language("es-ES")
PhoenixKit.Modules.Languages.add_language("fr-FR")

# 3. Multilang is now active for all entities
PhoenixKitEntities.multilang_enabled?()
# => true
```

### Translation API (Programmatic)

```elixir
alias PhoenixKitEntities
alias PhoenixKitEntities.EntityData

# --- Entity definition translations ---
entity = Entities.get_entity_by_name("products")

Entities.set_entity_translation(entity, "es-ES", %{
  "display_name" => "Productos",
  "display_name_plural" => "Productos",
  "description" => "Catálogo de productos"
})

Entities.get_entity_translation(entity, "es-ES")
# => %{"display_name" => "Productos", "display_name_plural" => "Productos", ...}

Entities.get_entity_translations(entity)
# => %{"es-ES" => %{...}, "fr-FR" => %{...}}

# --- Entity data translations ---
record = EntityData.get(uuid)

EntityData.set_translation(record, "es-ES", %{"name" => "Acme España", "desc" => "Una empresa"})
EntityData.set_title_translation(record, "es-ES", "Mi Producto")

EntityData.get_translation(record, "es-ES")
# => %{"name" => "Acme España", "category" => "Tech", "desc" => "Una empresa"}

EntityData.get_all_translations(record)
# => %{"en-US" => %{...}, "es-ES" => %{...}}

EntityData.get_all_title_translations(record)
# => %{"en-US" => "My Product", "es-ES" => "Mi Producto"}

# Remove a language's translations
EntityData.remove_translation(record, "fr-FR")
Entities.remove_entity_translation(entity, "fr-FR")
```

### Primary Language Changes

When the global primary language changes (via Languages admin), existing records lazily re-key on edit:

1. User opens an existing record for editing
2. System detects embedded `_primary_language` differs from global primary
3. The new primary is promoted to have all fields (missing fields filled from old primary)
4. All secondary languages are recomputed against the new primary; `_title` is re-keyed with other fields
5. Changes persist when the user saves

Records that are never edited continue to work — read paths use the embedded primary for correct display.

### Admin UI

- **Entity form** (`/admin/entities/:id/edit`): Language tabs above translatable fields (display_name, display_name_plural, description). Non-translatable fields (slug, icon, status) in a separate card.
- **Data form** (`/admin/entities/:slug/data/:id/edit`): Language tabs for title and custom fields. Slug, status, and entity type in a separate card.
- **Data view**: Read-only language tabs for viewing translations.
- **Compact mode**: When >5 languages, tabs show short codes (EN, ES) instead of full names.

### Limitations

- **Search** queries primary language data only; secondary translations are not searched.
- **Public form builder** stores submissions flat (non-multilang): the form is *shown and answered* in the visitor's language (see "Languages of the public form"), but what a visitor types is saved as one flat value. Use the admin UI or API to add translations afterward.
- **Clearing a secondary field** makes it inherit the primary value (by design — override-only storage).
- See `DEEP_DIVE.md § Known Limitations` for the full table.

---

## Extending the system

1. **New field type** – update `FieldTypes` (definition + defaults), extend `FormBuilder`, and add validation handling to `EntityData` if needed.
2. **New settings** – add to `phoenix_kit_settings` (migration + defaults), expose in the settings LiveView, and document in `get_config/0`.
3. **API surface** – add helper functions in `Entities` or `EntityData` if they’re reused across LiveViews or future REST/GraphQL endpoints.
4. **LiveView changes** – keep locale and nav rules in mind, reuse existing slots/components for consistency, and add tests where possible.

---

## Public Form Builder

The Entities system includes a public form builder for creating embeddable forms on public-facing pages.

### Features

- **Embeddable Component**: Use `<EntityForm entity_slug="contact" />` in publishing pages
- **Field Selection**: Choose which entity fields appear on the public form
- **Languages**: Renders in the page's language, with per-language title, description, submit text, success message and field texts
- **Security Options**: Honeypot, time-based validation (3s minimum), rate limiting (5/min), Cloudflare Turnstile
- **Configurable Actions**: reject_silent, reject_error, save_suspicious, save_log
- **Statistics**: Track submissions, rejections, and security triggers
- **Debug Mode**: Detailed error messages for troubleshooting
- **Metadata Collection**: IP address, browser, device, referrer, timing data
- **HTML Sanitization**: Rich text fields automatically sanitized to prevent XSS

### Configuration (entity settings)

| Setting | Description |
|---------|-------------|
| `public_form_enabled` | Master toggle |
| `public_form_fields` | List of field keys to include |
| `public_form_title` | Form title |
| `public_form_description` | Form description |
| `public_form_submit_text` | Submit button text |
| `public_form_success_message` | Success message |
| `public_form_honeypot` | Enable honeypot protection |
| `public_form_time_check` | Enable time-based validation |
| `public_form_rate_limit` | Enable rate limiting |
| `public_form_turnstile` | Enable Cloudflare Turnstile (needs a connection, see below) |
| `public_form_turnstile_connection` | UUID of the verified Turnstile connection to use |
| `public_form_turnstile_action` | Action when the check fails (default `reject_error`) |
| `public_form_debug_mode` | Show detailed error messages |
| `public_form_collect_metadata` | Collect submission metadata |

### Languages of the public form

On a multilingual site (Languages module with two or more enabled languages)
the form renders, and answers after the submit, in the page's language. The
language is the page's own (`PhoenixKit.Utils.Multilang.current_locale/0`) or
the `locale` attribute (`<EntityForm entity_slug="contact" locale="de" />`);
it must be an enabled language, anything else is ignored.

Where each text comes from, in the language of the page (the primary language
always reads the flat value):

| Text | Per-language source | Falls back to |
|------|---------------------|---------------|
| Title, description, submit text, success message | `settings["translations"][lang]["public_form_title" / "public_form_description" / "public_form_submit_text" / "public_form_success_message"]`, edited on the language tabs of the builder's public-form section | the flat `public_form_*` setting |
| Field label, placeholder, help text, option texts | the field's own `"translations"[lang]` (`"label"`, `"placeholder"`, `"description"`, `"options"`) | the field's own text |
| The module's own strings (default submit text, flash messages, "unavailable" notice) | the `phoenix_kit_entities` Gettext catalogues (`en`, `et`, `ru`; `de` and `fr` for the visitor-facing strings) | English |

The form carries the language it was shown in as a hidden `_locale` field; the
controller accepts it only if it names an enabled language (the posted value is
never trusted further than that choice) and answers the submit - the success
message and the error flashes - in it, falling back to the request's own
language. Entities without translations render exactly as before. Field
translations are display-only: the stored value of a select or radio is
always the canonical option string.

Not covered: the field editor of the builder has no UI for the fields'
`"translations"` yet (set them in the field definitions, or by mirror import),
and a validation error shown to a visitor is generic and not field-specific.
### Cloudflare Turnstile

An optional captcha for the public form, built on core's website integrations
(`PhoenixKit.Integrations.Turnstile`, core 3.7.0+). It is independent of the
Authorization page's switch, which only protects core's own auth forms.

1. Add a Cloudflare Turnstile connection in the core Integrations settings
   (site key and secret key) and test it.
2. In the entity builder, switch on **Cloudflare Turnstile** under Security,
   pick the connection and the action for a failed check (same four actions
   as the other checks).

With the option on and a usable connection, the form carries core's Turnstile
widget and the controller verifies the token server-side with the client
address it already derives. Behaviour:

| Situation | Result |
|-----------|--------|
| Option off | Unchanged: no widget, no token is looked at |
| No token | The configured action applies, with a message telling the visitor to wait for the verification (or reload); stats count `turnstile_missing_triggers`. A steady count here means the widget is not starting (see below). A missing token is never silent: with `reject_silent` it is refused with that message like the no-verdict case, because it is overwhelmingly a real visitor whose widget did not start; `reject_silent` applies only to a token Cloudflare actually refused |
| A token Cloudflare refuses | The configured action applies; stats count `turnstile_triggers` |
| Cloudflare cannot be reached (no verdict) | Fails closed with a "try again in a few minutes" message and applies the configured action, except `reject_silent`, which becomes `reject_error` so a real visitor is not told a lost message was sent; stats count `turnstile_unavailable_triggers` |
| Option on, but no connection is selected, or the selected one was removed or no longer verifies | The widget is not drawn and submissions are **not checked**. This matches core's auth forms: refusing would lock the form for everyone with nothing on the page to fix. Unlike core's single switch, there is one such state per form, so it is made visible: an error is logged naming the entity, stats count `turnstile_unchecked_triggers` (shown in the builder), the stored submission carries a `turnstile_unchecked` entry (action `none`: nobody chose it) in `security_warnings`; a submission another check rejected never carries it, since Turnstile is skipped then, and the builder warns while the option is on |

The switch is `true` (or the string `"true"`); anything else is off. An action
nobody understands refuses with an error.

Order: Turnstile is the last check, and it is skipped when another check
already rejects the submission, so a request that is dropped anyway costs no
call to Cloudflare. A request with a garbage token that nothing else rejects
does cost one call to Cloudflare (blank, oversize and non-string tokens do
not); with rate limiting off there is nothing else to bound them, so keep it
on for a public form.

#### Where the widget works

The widget is core's (`phx-hook="Turnstile"`). Inside a LiveView, core's hook
starts it. On a controller-rendered page, including a form embedded in a
Publishing post, nothing would start it, so this module's own JS bundle
(`phoenix_kit_entities.js`, folded into the host's JavaScript by core like
every module bundle) starts it the way core's hook does, except that it does
not wait for a closed modal to open. It does nothing for a widget that core's
hook owns.

Publishing runs every post through an allow-list HTML sanitizer that keeps
`class`, `id`, `style`, `aria-*` and `input` `type`/`name`/`value` and drops
`data-*`, `phx-*`, `hidden` and `<noscript>`. The form therefore carries the
site key in a hidden `_turnstile_sitekey` field and the bundle finds the
widget box, the live region and its texts by class; nothing it needs is an
attribute that sanitizer removes (`public_form_turnstile_sanitized_test.exs`
runs the component's output through a copy of Publishing 0.20.0's allow-list).
If Publishing changes that list, re-check the selectors.

Either way the host's JS bundle must be on the page; without it no token is
sent and every submission is refused with the "wait for the verification"
message (and counted as above). There is no `<noscript>` note: the sanitizer
would turn it into visible markup, and a visitor without JavaScript gets the
same message from the server.

The same bundle stops a submit that has no token yet from leaving the page, so
a visitor who is too quick keeps what they typed and sees the same message in
a live region. Tokens are single-use; a refused submit redirects back, which
renders a fresh widget.

A host with a Content-Security-Policy must allow `https://challenges.cloudflare.com`
in `script-src` and `frame-src` (Turnstile loads its script from there and
renders in an iframe). When the script is blocked the widget box shows core's
"cannot be sent" notice.

### Embedding in pages

```heex
<EntityForm entity_slug="contact" />
```

The component checks if the form is enabled AND has fields selected before rendering. Submissions go to `/phoenix_kit/entities/{slug}/submit`.

### Real-Time Collaboration

The entity form editor supports real-time collaboration with FIFO locking:
- First user becomes the lock owner (can edit)
- Subsequent users become spectators (read-only)
- Live updates broadcast to all viewers
- Automatic promotion when owner leaves

---

## Related documentation

- `DEEP_DIVE.md` – long-form analysis, rationale, and implementation notes (in this directory)
- `lib/phoenix_kit/migrations/postgres/v17.ex` – initial entities database migration
- `lib/phoenix_kit/migrations/postgres/v81.ex` – adds `position` column for manual record ordering
- `lib/phoenix_kit/utils/routes.ex` – locale-aware path helpers
- `lib/phoenix_kit_web/components/layout_wrapper.ex` – navigation wrapper that consumes the assigns set by these LiveViews

---

With this overview you should have everything needed to work on the Entities system—whether that’s building new UI affordances, adding field types, or integrating entities into other PhoenixKit features. For deeper rationale and implementation notes, open `DEEP_DIVE.md` in the same directory.
