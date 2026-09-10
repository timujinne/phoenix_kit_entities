# AGENTS.md

Guidance for AI agents working on `phoenix_kit_entities`.

## Overview

PhoenixKit Entities is the dynamic-content-types layer: an admin defines an
*entity* (a blueprint) with a JSONB `fields_definition`, and records of that
entity are stored as *entity data* rows sharing one JSONB shape. It implements
the `PhoenixKit.Module` behaviour, so a host app gets the admin UI, settings,
permissions, migrations and routes by adding the dependency — no wiring.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_live_view` `~> 1.0`,
  `gettext` `~> 1.0`. `lazy_html` is test-only (`Phoenix.LiveViewTest`'s HTML
  parser). No sibling `phoenix_kit_*` deps.
- **Consumed by:** `phoenix_kit_catalogue` (attribute sets are MANAGED
  blueprints) and `phoenix_kit_projects` (the "Data" project extension). Both
  wrap this module in their own `pk_dep/3`, so `PHOENIX_KIT_ENTITIES_PATH`
  points them at a local checkout.
- **Admin surface:** tab `:admin_entities` at `/admin/entities` (group
  `:admin_modules`), whose dynamic children are one subtab per entity at
  `/admin/entities/<name>/data`; settings subtab `:admin_settings_entities` at
  `/admin/settings/entities`. One public route: `POST
  /entities/:entity_slug/submit`.
- **Module key** `"entities"`; settings prefix `entities_` (plus the
  `sitemap_entit*` keys the sitemap source reads).

## What this module does NOT do

- **Per-entity DB tables** — every entity type lives in the same
  `phoenix_kit_entity_data` JSONB row shape. Schema flexibility comes
  from the `fields_definition` JSONB column on `phoenix_kit_entities`,
  not from running new migrations per entity.
- **Frontend rendering of records** — the parent Phoenix app owns the
  public LiveView/controller that displays a record at
  `/products/my-item`. This module only provides the URL helpers
  (`EntityData.public_path/3`, `public_url/3`, `public_alternates/3`)
  and the route-resolution logic.
- **Authentication on public form submissions** — the public POST
  endpoint at `/entities/:entity_slug/submit` accepts un-authed
  submissions on purpose (it is the public-form contract). Defense is
  honeypot + minimum submission time + rate limiting, not auth.
- **Per-entity push-notification or webhook delivery** — `Events`
  broadcasts to PubSub for in-app reactivity. External webhook
  delivery is out of scope.
- **Visual schema editor for fields** — fields are added one at a time
  via the entity form. No drag-to-canvas builder.
- **Blocking deletes on parent-app references** —
  `count_external_references/1` is informational; soft-delete is what keeps
  a host's foreign keys resolving.

## Commands

```bash
mix deps.get
createdb phoenix_kit_entities_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

The override is gated on the env var, not on the repo: `mix.exs` ships in the
package and `pk_dep/3` reads the var wherever this lib is resolved, so an
exported `PHOENIX_KIT_PATH` also redirects `phoenix_kit` for any downstream
project that consumes `phoenix_kit_entities` while the var is set. Keep it
scoped to the shell doing cross-repo work.

`mix precommit` here runs more than the shared four: `deps.unlock
--check-unused`, `mix hex.audit` (retired-dep scan, via `cmd` so Hex bootstraps
in a fresh process) and `mix test.js` (`node --test` over
`test/js/*.test.cjs`; skipped when node is absent — the Elixir suite is the
gate).

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- **Module key** is `"entities"` in every callback; tab ids are prefixed
  `:admin_` (`:admin_entities`, `:admin_settings_entities`); URL segments use
  hyphens, never underscores.
- **Navigation paths** always go through `PhoenixKit.Utils.Routes.path/1` —
  never a relative or hardcoded path.
- **Routing uses the route-module pattern.** `route_module/0` returns
  `PhoenixKitEntities.Routes`, which declares `admin_locale_routes/0`
  (localized, `:locale` prefix) and `admin_routes/0` (non-localized). The two
  must mirror each other with distinct `:as` aliases. `admin_tabs/0` carries no
  `live_view:` field — the route module owns all routing.
- **Those two quoted blocks may contain only `live` declarations.** They splice
  directly inside Phoenix's `live_session :phoenix_kit_admin do … end`, which
  rejects `get`/`post`, `forward`, nested `scope` and `pipe_through` at compile
  time. Public-facing controllers go in `generate/1`.
- **Never hand-register plugin routes in the host router.** PhoenixKit injects
  module routes into its own `live_session :phoenix_kit_admin`. A hand-written
  route sits outside that session, loses the admin layout, and crashes the
  socket on cross-page navigation ("redirecting across live_sessions").
- **LiveViews use `use PhoenixKitWeb, :live_view`** (and `use PhoenixKitWeb,
  :controller`), which this module gets from its `phoenix_kit` dependency.
  `Web.ProjectDataLive` is the exception: it renders inside the projects host
  and uses plain `use Phoenix.LiveView`.
- **Re-declare the Gettext backend after the PhoenixKitWeb macro.** Every LV
  follows `use PhoenixKitWeb, :live_view` with `use Gettext, backend:
  PhoenixKitEntities.Gettext`; the order matters, because the core macro wires
  core's backend by default and the later `use` overrides it.
- **Never wrap admin LiveViews in `LayoutWrapper`** — PhoenixKit applies the
  admin layout via an on_mount hook; wrapping renders double sidebars.
- Admin LV assigns available from that hook: `@phoenix_kit_current_scope`,
  `@current_locale`, `@url_path`.
- **All LiveView templates are inline `~H` sigils** (no separate `.heex`
  files), so Tailwind's scanner sees every class.
- **Gettext:** own backend `PhoenixKitEntities.Gettext` over `priv/gettext`
  (`en`, `et`, `ru`). The catalogues are **hand-maintained** — there is no
  `mix gettext.extract` step in this repo's workflow; add msgids by hand.
  `gettext_noop/1` anchors extraction at definition sites (permission label,
  tab labels) so they survive rewording elsewhere. Three invariants are pinned
  by `gettext_catalogue_test.exs`: no `fuzzy` entry may ship (the compiler
  keeps serving the stale translation with no runtime signal), no empty
  `msgstr`, and no `msgstr` may interpolate a `%{binding}` the msgid does not
  declare.
- **JS hooks ship as a prebuilt bundle** declared by `js_sources/0`
  (`priv/static/assets/phoenix_kit_entities.js`, global
  `window.PhoenixKitEntitiesHooks`). Never register a hook from an inline
  `<script>`: morphdom does not execute inserted script tags, so the hook
  disappears on LiveView navigation. Pure helpers in the bundle are exported
  under `module.exports` so `mix test.js` can unit-test them.
- **`css_sources/0`** returns `[:phoenix_kit_entities]`; `mix
  phoenix_kit.install` turns that into Tailwind `@source` directives in the
  host's `app.css`. Without it Tailwind purges this module's classes.
- **`enabled?/0` rescues exceptions AND catches `:exit`** and returns `false`
  (a sandbox shutdown exits rather than raising, and the DB may be absent).
  `safe_count/1` behind `get_config/0` uses the same pattern, and so does
  `entities_children/1,2` — that one is core's `dynamic_children` callback, so
  an uncaught exit there takes out every admin page render.
- **`enable_system/1` and `disable_system/1`** use `module_key()` rather than a
  literal, and both log a `module.entities.{enabled,disabled}` activity row.
- **Activity logging** goes through `PhoenixKitEntities.ActivityLog.log/1`,
  which stamps `module: "entities"`, guards `PhoenixKit.Activity` with
  `Code.ensure_loaded?/1` and rescues, so a logging failure never crashes the
  mutation. Notification-side wiring lives in `notify_entity_event/2` and
  `notify_data_event/2`, piped after every CRUD repo call so logging only fires
  on `:ok` and an `:error` tuple flows through unchanged. Actions are
  `entity.{verb}` / `entity_data.{verb}` where verb is one of `created`,
  `updated`, `deleted`, `trashed`, `restored`, `reordered`,
  `bulk_status_changed`, `bulk_deleted`, `bulk_trashed`, `bulk_restored`,
  `translation_set`; module toggles use `module.entities.{enabled,disabled}`.
  `entity_data.deleted` is hard-delete and `entity_data.trashed` is
  soft-delete — keep them distinct so audit consumers can tell which ran.
  LV call sites thread `actor_opts(socket)` so rows pin `actor_uuid`.
- **PII guardrail at the source:** never log `email`, `phone`, free-text
  `description` fields, raw `data` JSONB blobs, or any user-typed field. Safe
  metadata: `name`, `display_name`, `slug`, `status`, derived counts, FK uuids.
- **Soft-delete sentinel is `status == "trashed"`.** The row stays in the DB so
  a parent app's FK to `phoenix_kit_entity_data(uuid)` keeps resolving; a hard
  delete would fire the host's FK action and surface as an opaque 500. Default
  `list_*` / count queries hide trashed rows; `include_trashed: true` surfaces
  them.
- **`get_by_slug/3` is deliberately NOT status-filtered** — slug uniqueness has
  to survive trashing, or a restored row collides with a freshly created
  replacement.
- **Hard delete rescues `Ecto.ConstraintError` / `Postgrex.Error`** on FK and
  NOT NULL violations and returns `{:error, :referenced_by_external}` for a
  friendly flash; any other constraint error is re-raised so real bugs surface.
  A live child returns the more precise `{:error, :has_children}`, checked
  inside the delete transaction so a concurrent insert cannot slip past it.
- **Reorder is capped at 1000 uuids** (`{:error, :too_many_uuids}`, audit-logged
  as a rejection), and `EntityData.reorder/3` AND-filters every per-uuid
  `update_all` on `entity_uuid` so a stray cross-entity uuid cannot rewrite
  positions in another scope.
- **Reverse-reference hook** — a host declares count callbacks in global
  application env; `count_external_references/1` sums every callback matching
  the record's entity name. Informational only, never a delete-blocker:

  ```elixir
  config :phoenix_kit_entities,
    reverse_references: [
      {"order_status", &MyApp.Orders.count_orders_with_status/1},
      {"sub_order_status", &MyApp.Orders.count_sub_orders_with_status/1}
    ]
  ```

  Multiple callbacks per entity name all contribute. The key is global OTP env,
  so in an umbrella two apps registering the same entity name both fire and the
  totals add. Prefer the 2-arity form with a pre-loaded entity in loops; the
  1-arity form preloads `:entity` per call.
- **MANAGED blueprints** (`PhoenixKitEntities.Managed`) are entities owned by
  another module, marked by `settings["managed_by"]` plus `locked_keys`.
  `validate_mutation/3` and `validate_delete/1` sit on the **write path**, not
  only the UI: a non-owner cannot rename the slug, change status, tamper with
  the markers, or touch locked settings keys, and cannot turn an unmanaged
  blueprint into a managed one by a create-then-update masquerade. Owners pass
  `on_behalf_of: "<owner>"`. Deletion requires the owner's registered guard;
  a managed blueprint with no guard refuses deletion (fail closed). The guard
  callback MUST be an external capture (`&Mod.fun/1`) — a local capture stored
  in `:persistent_term` goes stale on code reload and every delete then fails
  with `{:error, :delete_guard_error}`. `reorder_entities/2` is deliberately
  outside the interception (`position` is in no owner contract).
- **Entity names** are snake_case, start with a letter, 2–50 chars:
  `^[a-z][a-z0-9_]*$`. **Field definitions** require string keys:
  `%{"type" => "text", "key" => "name", "label" => "Name"}`.
- **Multilang entity metadata** — `display_name`, `display_name_plural` and
  `description` are translatable via `entity.settings["translations"]`. Every
  entity query function (`list_entities`, `get_entity_by_name`,
  `list_entity_summaries`, …) takes an optional `lang:` keyword returning the
  struct with those fields resolved. Key lookup is normalised through
  `DialectMapper.extract_base/1` so `"es"` still resolves `"es-ES"` rows. Admin
  LVs thread `lang: @current_locale`; `Web.EntityForm` and
  `Web.EntitiesSettings` intentionally read the raw primary language because
  they manage canonical identity.
- **Sidebar locale propagation** — `entities_children/1` has no locale from the
  dashboard registry, so it reads `Gettext.get_locale(PhoenixKitEntities.Gettext)`
  at render time; `entities_children/2` takes an explicit locale from core
  releases that pass one. The ETS cache is keyed by `{cache_key, locale}` and
  `invalidate_entities_cache/0` uses `:ets.match_delete/2` to clear every
  locale variant on mutation.
- **Public URL helpers** — `EntityData.public_path/3` and `public_url/3` build
  locale-aware URLs through `UrlResolver`, matching
  `PhoenixKit.Utils.Routes.path/2`'s policy: `nil` locale, single-language, or
  primary language gets no prefix; other locales get `/<base>/…`.
  `public_alternates/3` returns `%{canonical, alternates: [%{locale, href}, …,
  %{locale: "x-default", href}]}` for hreflang/canonical tags.
- **Public form controller defense** — the POST at
  `/entities/:entity_slug/submit` is intentionally un-authed. Protection is a
  honeypot field, a minimum submission time and a Hammer per-IP-per-entity rate
  limit. The rate-limit key's IP is validated against an IPv4 regex with
  RFC1918/loopback rejection so `X-Forwarded-For` spoofing cannot multiply
  buckets. Stored metadata (user-agent, referer) is capped at 255 chars to
  prevent JSONB bloat.
- **Mirror path containment** — `mirror/storage.ex` reads its base directory
  from the `entities_mirror_path` setting, resolves it through `Path.expand/1`
  and validates it against the host's `priv/entities` root, so an admin-edited
  setting cannot write exports to an arbitrary filesystem location.
- **Errors are atoms, not strings.** Public API returns
  `:cannot_remove_primary`, `:not_multilang`, `:entity_not_found`,
  `:referenced_by_external`, … and tagged tuples (`{:invalid_field_type,
  type}`, `{:user_entity_limit_reached, max}`) so callers pattern-match
  locale-agnostically; LV call sites pipe the reason through
  `Errors.message/1` for the user-facing string.
- **Rich-text field values are sanitized on the write path** through
  `PhoenixKit.Utils.HtmlSanitizer.sanitize_rich_text_fields/2` (per language
  too) — never store raw user HTML in the `data` JSONB.
- **PubSub topic strings live in `Events` as named functions** — never
  hardcode a topic in a caller. Broadcasts go through
  `PhoenixKit.PubSub.Manager` (the host's PubSub), not a module-local server.

### Landmines

- Admin LVs crash at mount with "the table identifier does not refer to an
  existing ETS table" → `PhoenixKitEntities.Presence` is not running. It is
  returned by `children/0` for hosts; test boots must supervise it themselves.
- Pointing `PGDATABASE` at a database another package's `Ecto.Migrator` owns
  makes same-numbered migrations silently count as applied.
  `Test.SchemaOwnerGuard` stamps `COMMENT ON TABLE schema_migrations` and
  raises `OwnerMismatch` instead — do not "fix" that by clearing the marker.
  Never combine `PGDATABASE` with `PHOENIX_KIT_PATH`: `ensure_current/2`
  migrates whatever it is pointed at and would move the shared DB's schema.
- A reworded msgid re-merged into a catalogue lands `fuzzy` and keeps serving
  the OLD translation with no runtime error. The catalogues here are edited by
  hand for that reason; `gettext_catalogue_test.exs` fails the build on any
  fuzzy entry.
- Narrowing the core pin to a three-segment `~> 2.0.x` breaks CONSUMERS only
  (`~> 2.0.x` excludes every 2.1+ core, so a host wanting both this module and
  a newer core gets an unsolvable dep set). `core_pin_conformance_test.exs`
  guards it; nothing else in this repo would notice.
- `Web.DataNavigator` auto-flips an entity's `sort_mode` to `"manual"` on the
  first drag and only logs a `Logger.warning` — a setting changed by a gesture,
  so don't treat a "manual" mode nobody set as corruption.

## Architecture

```
lib/phoenix_kit_entities.ex                       # Entity schema + PhoenixKit.Module callbacks
lib/phoenix_kit_entities/
├── activity_log.ex                              # ActivityLog.log/1 wrapper
├── entity_data.ex                               # Data-record schema, CRUD, trash, public URL helpers
├── errors.ex                                    # Atom/tagged-tuple -> gettext dispatcher
├── events.ex                                    # PubSub topics + broadcast helpers
├── field_types.ex / field_type.ex               # Field-type registry + struct
├── form_builder.ex                              # Dynamic form generation + data validation
├── gettext.ex                                   # Module Gettext backend
├── managed.ex                                   # Managed-blueprint guards + delete-guard registry
├── migrations.ex                                # Module-owned migration chain
├── presence.ex / presence_helpers.ex            # FIFO collaborative editing locks
├── routes.ex                                    # Admin + public route declarations
├── sitemap_source.ex                            # PhoenixKit Sitemap source
├── url_resolver.ex                              # Shared URL-pattern resolution
├── components/                                  # Function components (entity form, field input, live data form)
├── controllers/entity_form_controller.ex        # Public form submission endpoint
├── mirror/{exporter,importer,storage}.ex        # Filesystem mirror subsystem
├── mix_tasks/{export,import}.ex                 # mix phoenix_kit_entities.{export,import}
└── web/                                         # Admin LiveViews
    ├── entities.ex                              # Entity list
    ├── entity_form.ex                           # Entity create/edit
    ├── data_navigator.ex                        # Data record browser (filters, bulk actions, trash view)
    ├── data_form.ex                             # Data record create/edit
    ├── entities_settings.ex                     # Module settings + import/export modal
    ├── project_data_live.ex                     # Read-only records tab for the projects hub
    └── hooks.ex                                 # on_mount: Events subscription + presence tracking
```

- **`PhoenixKitEntities`** is both the Ecto schema for entity definitions and
  the module entry point (behaviour callbacks, sort-mode and mirror settings,
  sidebar children).
- **`UrlResolver`** resolves a record's URL pattern in order: entity settings →
  router introspection → per-entity settings → global pattern → fallback. Its
  Settings lookups rescue only DB-availability shapes
  (`DBConnection.ConnectionError`, `Postgrex.Error`, `Ecto.QueryError`,
  `RuntimeError`, `ArgumentError`) so URL generation degrades gracefully while
  real bugs (`KeyError`, `FunctionClauseError`) still surface.
- **`SitemapSource`** implements `PhoenixKit.Modules.Sitemap.Sources.Source`,
  delegating pattern resolution to `UrlResolver` and keeping a "prefix every
  language" policy so entries are hreflang-correct.
- **`phoenix_kit_project_extensions/0`** is a duck-typed contract for the
  projects hub (its `Extensions.Registry` discovers the function on every
  loaded module; no dependency, no `@impl`). It offers one `entities_data`
  extension whose Data tab config-links ONE entity per project and lists its
  records read-only — mutations stay in the entities admin.

Core APIs relied on: `PhoenixKit.Settings`, `RepoHelper`, `Dashboard.Tab` +
`Dashboard.Registry`, `Users.Auth.Scope`, `Modules.Languages` and its
`DialectMapper`, `Utils.Multilang`, `Utils.HtmlSanitizer`, `Utils.Routes`,
`Modules.Sitemap.*`, `PubSub.Manager`, `PhoenixKitWeb.*` components and layout,
and `PhoenixKit.Activity` — the last is optional and degrades gracefully when
absent.

### Data model

| Table | Holds |
|---|---|
| `phoenix_kit_entities` | Entity definitions (blueprints): `fields_definition` and `settings` JSONB, `position` |
| `phoenix_kit_entity_data` | Data records: `data` and `metadata` JSONB, `status`, `slug`, `position`, self-referencing `parent_uuid` |

UUIDv7 primary keys on both. Both schemas `use PhoenixKit.SchemaPrefix`.

### PubSub topics

All defined in `Events`, broadcast via `PhoenixKit.PubSub.Manager`.

| Topic | Messages |
|---|---|
| `phoenix_kit:entities:definitions` | `{:entity_created \| :entity_updated \| :entity_deleted, uuid}` |
| `phoenix_kit:entities:data` | data lifecycle messages for all entities |
| `phoenix_kit:entities:data:<entity_uuid>` | data lifecycle messages for one entity |
| `phoenix_kit:entities:entity_forms:<form_key>` | collaborative editing on an entity form |
| `phoenix_kit:entities:data_forms:<entity_uuid>:<record_key>` | collaborative editing on a data record |

### Settings keys

| Key | Type | Meaning |
|---|---|---|
| `entities_enabled` | boolean | Global on/off for the module |
| `entities_max_per_user` | integer | Entities one user may create (default 100) |
| `entities_allow_relations` | boolean | Relation field types enabled (default true) |
| `entities_file_upload` | boolean | File/image field uploads enabled (default false) |
| `entities_mirror_path` | string | Base directory for filesystem mirroring (default `priv/entities` under the host) |
| `sitemap_entities_pattern` | string | Global URL pattern when no per-entity one is set, e.g. `/:entity_name/:slug` |
| `sitemap_entity_<name>_pattern` | string | Per-entity URL pattern override |
| `sitemap_entity_<name>_index_path` | string | Per-entity index page URL |
| `sitemap_entities_auto_pattern` | boolean | Fall back to `/<entity_name>` as the index path |

### Permissions

One permission key, `"entities"` (no sub-permissions), declared by
`permission_metadata/0` and carried by every tab; checked with
`Scope.has_module_access?/2`. Its label renders translated in the permissions
matrix via `gettext_backend: PhoenixKitEntities.Gettext`.

## Database & migrations

Owns a versioned chain: `PhoenixKitEntities.Migrations` via `migration_module/0`,
marker `pkn_schema:<N>` as a `COMMENT ON TABLE phoenix_kit_entities`, currently
V1. `mix phoenix_kit.update` applies it in hosts (and `mix phoenix_kit.status`
reports it); the test suite runs it through `Test.Migration` in
`test_helper.exs`.

Both tables ship in core's V135 baseline, so on every install they exist before
this chain first runs. **V1 is purely adoptive**: every statement is
`IF NOT EXISTS`-guarded and name-identical to core's objects, so it changes no
shape — it only stamps the marker. From then on this package owns the tables'
future shape. `down/1` only unstamps the marker; it never drops a table or a
row.

Consequences, from the protocol in the `phoenix_kit_hello_world` README
("Adopting a table core already creates (extraction)"):

- **Never edit V1.** A host that ran it never runs it again; the first shape
  change is a V2 step.
- **The first V2 shape change is when core has to move** — core's
  `ExpectedSchema` manifest still audits these tables, so the altered objects
  must land in core's `@excluded_exact` and the core floor must be raised
  before that release, or `mix phoenix_kit.repair` restores the old shape after
  every run.
- V1's statements are pinned in `test/phoenix_kit_entities/migrations_test.exs`,
  including a drift guard that derives the expected object inventory from
  core's `ExpectedSchema` manifest rather than a hand-copied list.
- `migrated_version_runtime/1` reports `0` for a marker-less table but RAISES
  on an unusable prefix — "not installed" and "you gave me a prefix I cannot
  query" must not look the same to the update task. It rescues and catches
  `:exit` (a dead pool exits rather than raising).

A host runs `PhoenixKit.Migrations.up()` plus `mix phoenix_kit.update` and gets
the full schema. UUIDv7 primary keys throughout; the `uuid_generate_v7()`
Postgres function comes from core.

## Testing

Test DB `phoenix_kit_entities_test`; `createdb` it once. Unit tests always run;
DB-backed tests are tagged `:integration` (auto-applied by `DataCase` and
`LiveCase`) and auto-exclude when the database is unreachable —
`test_helper.exs` probes with `psql -lqt` and falls back to a connect attempt
when `psql` is missing.

`database:` / `pool_size:` in `config/test.exs` read `PGDATABASE` / `PGPOOL`,
falling back to the name above and `System.schedulers_online() * 2` — the same
mechanism core uses, for pointing the suite at a shared instance:

```bash
PGDATABASE=migration_test_db PGPOOL=6 mix test
```

The critical wiring is `config :phoenix_kit, repo: PhoenixKitEntities.Test.Repo`
in `config/test.exs`; without it every call through `PhoenixKit.RepoHelper`
crashes with "No repository configured".

Schema setup runs core's chain via `PhoenixKit.Migration.ensure_current/2`, then
this module's own chain via `Ecto.Migrator.up(TestRepo, <wall clock>,
PhoenixKitEntities.Test.Migration, …)` — the same two steps a host performs,
with a wall-clock version so a stale `schema_migrations` row cannot
short-circuit a re-run. `test_helper.exs` also starts
`PhoenixKit.PubSub.Manager`, `ModuleRegistry`, `Admin.SimplePresence`, a
`Task.Supervisor` named `PhoenixKit.TaskSupervisor` (mirror writes run as
supervised tasks), `PhoenixKitEntities.Presence` under a small supervisor, the
rate-limiter backend (fixtures register users through it) and, when the repo is
available, `Test.Endpoint`.

Support modules under `test/support/`:

- `Test.Repo` — the test Ecto repo.
- `DataCase` — sandbox setup, auto-tags `:integration`.
- `LiveCase` — `Phoenix.LiveViewTest` wrapper with router/endpoint wiring, plus
  `put_test_scope/2` and `fake_scope/1`.
- `Test.Endpoint` / `Test.Router` / `Test.Layouts` — minimal Phoenix plumbing.
  `Test.Layouts.app/1` renders flashes, which is what makes flash assertions
  after click events possible.
- `ActivityLogAssertions` — `assert_activity_logged/2` and
  `refute_activity_logged/2`, querying `phoenix_kit_activities` directly with
  action / actor_uuid / resource_uuid / metadata-subset matching.
- `Test.Migration` — the checked-in equivalent of the migration
  `mix phoenix_kit.update` generates in a host.
- `Test.Hooks` — on_mount hook injecting `phoenix_kit_current_scope` via
  session.
- `Test.SchemaOwnerGuard` — stamps and checks the `schema_migrations` owner
  marker (see Landmines).

Excluded tags: `:integration` without a DB, `:requires_phoenix_kit_i18n_api`
when core lacks `PhoenixKit.Dashboard.Tab.localized_label/1`, and
`:needs_unreleased_core` always (see TODOs).

```bash
mix test test/phoenix_kit_entities_test.exs   # behaviour callbacks, incl. version/0 vs mix.exs
mix test test/phoenix_kit_entities/web        # LiveView smoke tests
for i in $(seq 1 10); do mix test; done       # stability check
```

## Feature notes

| Feature | Constraint | Guide |
|---|---|---|
| Reorder + trash lifecycle | Reorder is capped at 1000 uuids and scoped by `entity_uuid` in the DB layer; trashed rows stay in the table so host FKs keep resolving, and every reorder path emits exactly one audit row (success, DB error, or rejection). | [dev_docs/guides/entity-data-lifecycle.md](dev_docs/guides/entity-data-lifecycle.md) |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- The `:needs_unreleased_core` tag on
  `test/phoenix_kit_entities/entity_data_created_by_test.exs` gates the
  anonymous-creator behaviour on core making
  `phoenix_kit_entity_data.created_by_uuid` nullable. The pinned core now
  ships that migration, so run
  `PGDATABASE=phoenix_kit_entities_v169_test mix test --include needs_unreleased_core`
  against a SEPARATE database (the suite migrates whatever it is pointed at,
  and `anonymous_creator_supported?/0` caches in `:persistent_term`); when it
  is green, drop the moduletag, the gate it tests, and the exclusion in
  `test_helper.exs`.
- `entities_children/1` exists only for core releases that dispatch the 1-arity
  `dynamic_children` callback. Once the floor is past releases that pass the
  locale explicitly, delete it and keep `entities_children/2`.
