## 0.4.12 - 2026-09-07

### Fixed

- The Entities Settings page's breadcrumb linked its second segment to
  "Modules" → `/admin/modules` instead of "Settings" → `/admin/settings`,
  even though the page lives under the Settings sidebar group
  (`settings_tabs/0` registers it at `/admin/settings/entities`) — the
  wrong link, not just a mislabeled one. Page title also shortened from
  "Entities Settings" to "Entities" to match the sidebar label.

## 0.4.11 - 2026-09-07

### Fixed

- **Removed duplicate page headings** on the Entities Settings page and the
  entity edit form — each repeated the page title already shown in the top
  breadcrumb bar.

## 0.4.10 - 2026-09-05

### Added

- **A module-owned migration chain** (`PhoenixKitEntities.Migrations`),
  registered through `migration_module/0` and discovered by
  `mix phoenix_kit.status` / `mix phoenix_kit.update`. V1 is purely
  *adoptive*: `phoenix_kit_entities` and `phoenix_kit_entity_data` were
  created by core and still ship in its squashed baseline, so every
  statement is `IF NOT EXISTS`-guarded and name-identical to core's
  objects, and the only new object is the `pkn_schema:1` marker stamped
  as a `COMMENT ON TABLE`. Nothing about the schema changes; what changes
  is that this package now owns the two tables' future shape instead of
  waiting on a core release. `down/1` only unstamps the marker — it never
  drops a table or a row (#42).

### Fixed

- **A map-shaped `down/1` rolled back to the wrong version.** The target
  was read only from a keyword list, while the prefix was read from either
  a keyword list or a map (the shape core's own migrator threads through
  its chain), so `down(%{prefix: "public", version: 1})` validated its
  prefix, discarded its version and unstamped to `0` (#42).
- **`migrated_version_runtime/1` survives a dead connection pool.** It
  guarded against exceptions only, but an unreachable database *exits*
  rather than raising on a dead or unstarted pool, which reported this
  module as errored to `mix phoenix_kit.status` where every sibling module
  reports "not installed". An unusable prefix still raises, deliberately:
  "not installed" and "I cannot query that prefix" must not look alike to
  the update task (#42).

### Changed

- **The test suite now runs the migration chain it ships.** Schema setup
  applies core's versioned migrations and then this module's own chain
  through `PhoenixKitEntities.Test.Migration` — the checked-in equivalent
  of the migration `mix phoenix_kit.update` generates in a host app — so
  the suite exercises exactly the DDL an install gets rather than asserting
  on statement strings that no database has ever parsed (#42).
- **The adopted object inventory is pinned to core's own manifest.** A new
  test derives what V1 must contain from
  `PhoenixKit.Migrations.ExpectedSchema` (43 required objects across the
  two tables) instead of a hand-copied list, so an object core adds and
  this chain misses fails the suite (#42).

## 0.4.9 - 2026-08-30

### Added

- **Decimal fields accept a `"step"` prop** to override the stepping the
  declared `scale` implies — `"any"` turns stepping off entirely, which is
  the way to stop a 4-place money field's spinner arrows crawling
  0.0001 at a time while keeping every place typeable (#41).

### Fixed

- **An explicit decimal `"step"` can no longer block saving the record.**
  As merged, any `"step"` was passed through to the input, but `step` is a
  browser validation constraint, not just spinner granularity: a form's
  `submit` event fires only after native validation passes, so `"0.01"` on a
  4-place field left the browser refusing `12.3456` and the admin unable to
  save — the exact failure the scale-derived step exists to prevent. An
  override is now honoured only when it still admits every value the scale
  allows (`"any"`, or a step dividing `10^-scale`); a coarser one falls back
  to the scale (#41).
- **Junk, zero and negative decimal steps fall back to the scale.** The
  explicit-step branch only rejected `""`, so `"0"`, `"-0.5"`, `"abc"` and
  `"0,01"` reached the attribute — and a browser that cannot parse `step`
  uses `1`, rejecting every decimal the type exists for. The value is now
  parsed and must be finite and positive (#41).
- **A float `"step"` renders without exponent notation**, through `Decimal`
  rather than `to_string/1` (`to_string(0.00001)` is `"1.0e-5"`) — the rule
  `decimal_input_value/1` already followed (#41).

### Changed

- **README field types are current again** — the list and registry count said
  12, four types after `decimal`, `image`, `video` and `heading` were added;
  the Numeric row now documents `decimal`'s `scale` and `step`.

## 0.4.8 - 2026-08-29

### Fixed

- **Signed-in public form submissions were stored as anonymous** — the
  submission controller read `conn.assigns[:current_user]`, a key nothing
  assigns; core's `fetch_phoenix_kit_current_user` plug assigns
  `:phoenix_kit_current_user`. On a pre-V169 core, where the column is NOT
  NULL, the explicit nil turned every submission into a validation failure
  (#40).
- **Collaborative-editing presence no longer broadcasts user credentials** —
  the Presence meta carried the whole `%PhoenixKit.Users.Auth.User{}`,
  `hashed_password` included (`redact: true` suppresses `Inspect`, not term
  serialization), plus the email, in a `presence_diff` to every other
  collaborator. The meta is now `user_uuid` / `joined_at` / `pid`; read
  `user_uuid` and load what you need to display (#40).
- **The admin data form's save path allowlists what the client may write** —
  `EntityData.changeset/2` casts `created_by_uuid`, `date_created`,
  `metadata` and `position`, none of which the form renders, so a crafted
  `save` could forge authorship, back-date the audit timestamp, or rewrite
  the `ip_address` / `user_agent` / `security_warnings` metadata a flagged
  public submission was stored with. `status` is filtered to the three the
  select offers, so `"trashed"` can't be written directly and bypass
  `trash/2` (#40).
- **A record can no longer be moved between blueprints by editing it under
  the wrong URL.** The entity comes from the URL and the record from its
  uuid, and nothing checked they belong together; now that the server sets
  `entity_uuid` from the URL entity, a plain Save on a mismatched URL would
  have re-parented the row. The edit form redirects to the record's own
  blueprint instead.
- **Per-field validation errors are visible on save**, not just in the
  concatenated flash — the save path's changeset arrived with `action: nil`,
  which is what `<.input>` gates error display on (#40).
- **The slug mirrors the title live on single-language installs** — the
  hook attributes were only on the multilang branch of the form, so the
  default install fell back to a 300 ms round trip (#40).
- **Reorders are audited when they succeed**, not only when they fail — the
  activity table previously recorded reordering exclusively when it went
  wrong. `count` is rows written, not pairs submitted (#40).
- **`EntityData.search_by_title/3` escapes LIKE wildcards** — searching
  `50%` matched every record and `a_b` matched `axb`. The sibling
  `entity_uuids_matching_title/3` already escaped; the two had drifted (#40).
- **Unreachable-database guards now catch exits, not just raises** — a dead
  connection pool exits, so the `rescue` clauses in `entities_children/1`,
  `SitemapSource` and `UrlResolver` stopped one step short of the case they
  exist for. In `entities_children/1` that took out every admin page render,
  since core calls it as its `dynamic_children` callback (#40).
- **The Data Navigator subscribed to entity events twice** — the `on_mount`
  hook already subscribes, and `Phoenix.PubSub` uses a duplicate-key
  registry, so every entity event ran the ~4-query refresh twice (#40).

### Changed

- `list_entities_with_mirror_status/0` runs one grouped count and one
  directory listing instead of one count and one `File.exists?` per entity.
  The settings LiveView re-runs it on every entity and data broadcast, so
  autosave on a record drove 1+N counts and N filesystem stats per debounced
  keystroke (#40).
- Dependency bump: routine `mix.lock` refresh.

## 0.4.7 - 2026-08-28

### Added

- **Managed blueprints are now edited directly in the generic Entities
  admin** instead of being hidden from it — a "Managed by %{owner}" badge
  marks them, and their slug/status stay locked (disabled controls paired
  with hidden inputs so a save can't blank them) while everything else
  (fields, display name, description) is editable right there (#39).
- **A media picker (Choose/Clear) for `image`/`video` fields** in the admin
  data form, wired through a shared `MediaSelectorModal` (#39).
- **The slug field mirrors the title live, in the browser** — a new
  `SlugFromTitle` JS hook (shipped via `js_sources/0`) writes an ASCII/Latin
  slug preview as you type, with the server remaining the source of truth
  for anything it can't confidently romanize (Cyrillic, CJK, mixed
  scripts). Slug "ownership" (auto-derived vs. user-typed) is now tracked
  server-side from which field was actually edited, fixing a freeze-after-
  first-keystroke bug the old value-comparison approach had once the title
  field's debounce dropped to zero (#39).
- **`EntityData.list_by_entities/2`, `counts_by_entities/2`, and
  `entity_uuids_matching_title/3`** — batched, per-entity-set query helpers
  (one query instead of one-per-entity) for listings that filter or tally
  across many entities at once (#39).
- `EntityData.list_by_entity/2` accepts `:limit` (#39).

### Changed

- The Data Navigator page replaced its four always-shown stat cards with a
  row of clickable status chips on the filter card itself; the filter card
  now hides entirely for a brand-new, unfiltered entity instead of showing
  four zeros (#39).
- Dependency bump: `phoenix_kit` 2.13.12, plus routine bumps to `phoenix`,
  `phoenix_live_view`, `phoenix_pubsub`, `oban`, `req`, `swoosh`, `leaf`,
  and a new transitive `tz` dependency.

### Fixed

- **I067: a `PGDATABASE`-override test DB pointing at another package's
  database now refuses to boot** instead of silently corrupting or
  skipping that package's migration history — `SchemaOwnerGuard` stamps
  and checks a `schema_migrations` ownership marker (test infrastructure
  only; no runtime/`lib/` change) (#38).

## 0.4.6 - 2026-08-22

### Changed

- **The import-preview entity tabs use core's `<.nav_tabs variant={:border}>`**
  instead of hand-rolled `tabs-border` markup. The tab-switch payload key is
  now `tab` rather than `entity` (#34).
- Dependency bump: `phoenix_kit` 2.13.6 (the first core release that admits
  `variant={:border}`).

### Fixed

- **Clean checkouts failed to compile under `MDEX_NATIVE_BUILD=1`** — that
  env var forces `mdex_native` to build its NIF from source (no precompiled
  build for OTP 28), which requires `rustler` itself, not just
  `rustler_precompiled`. Optional deps of dependencies are never resolved, so
  this package now declares `{:rustler, ">= 0.0.0", optional: true}` the same
  way core does. Host applications still need to declare rustler themselves
  (#35).

## 0.4.5 - 2026-08-21

### Changed

- **The icon-picker category strip uses core's `<.nav_tabs>`** instead of
  hand-rolled `tabs-boxed` markup. The filter event payload key is now
  `tab` rather than `category` (#33).

## 0.4.4 - 2026-08-21

### Added

- **`decimal` field type** — exact numeric storage (backed by `Decimal`) for
  values `number`'s `Float.parse/1` cast would silently round, money being the
  first consumer. Cast accepts a string (with a comma or period decimal
  separator), an integer, a float (legacy data only), or an already-cast
  `Decimal`; storage is the canonical `Decimal` string so the JSONB round trip
  never touches a float. `min`/`max` are enforced (unlike on `number`, where
  they're advisory). Rendered via `<input type="number">` with a `step` derived
  from the field's declared `scale`, and via
  `PhoenixKitEntities.Components.FieldInput` for inline editors.

### Fixed

- **Decimal `min`/`max` bounds were silently skipped for integer and float
  input** — `FormBuilder.validate_type/2`'s integer/float clauses for `decimal`
  returned success without checking bounds, unlike the string and `Decimal`
  clauses; a raw numeric value (e.g. a JSON API body) could carry an
  out-of-range value straight through. Found and fixed in post-merge review of
  #32.
- **Two decimal-bounds error messages never reached the translation
  catalogues** — `"must be at least %{min}"` / `"must be at most %{max}"` were
  new gettext calls with no matching `.po` entry in any locale (`et`/`ru` would
  have shown raw English). Added with real translations. Found in the same
  review.

### Changed

- Dependency bumps: `bandit` 1.12.5, `phoenix` 1.8.12, `phoenix_kit` 2.13.4,
  `phoenix_live_view` 1.2.10, `tesla` 1.21.2.

## 0.4.3 - 2026-08-19

### Added

- **Managed blueprints** (`PhoenixKitEntities.Managed`) — write-path protection for
  entities owned by another module (the catalogue's attribute sets are the first
  consumer). Managed blueprints are hidden from the generic admin
  (`include_managed: false`) and protected against generic callers renaming
  identity/status, touching locked settings keys, or tampering with/acquiring the
  `managed_by`/`locked_keys` markers; owning modules bypass via `on_behalf_of`.
  Deletion consults an owner-registered guard held in `:persistent_term` and fails
  closed if the guard raises or exits.
- **`PhoenixKitEntities.Components.FieldInput`** — a control-only per-field renderer
  for hosts that own their own layout (table cells, chips, inline editors), covering
  every field type with correct firing discipline (typed inputs debounce on blur,
  discrete inputs fire immediately). `FormBuilder.cast_field/2` is the new public
  per-field cast for hosts with their own save events.
- **Real `image`/`video` field types** — the stored value is a storage-file UUID
  selected through the host's media picker, validated with `Ecto.UUID.cast/1` at the
  cast, changeset, and render layers.

### Fixed

- **Managed blueprints could reappear in the generic admin list** after a
  drag-and-drop reorder or any entity-lifecycle PubSub broadcast (create/update/
  delete anywhere in the app) — two of `web/entities.ex`'s five `list_entities/1`
  call sites feeding the admin list were missing `include_managed: false`. Found and
  fixed in post-merge review of #31, pinned with regression tests.
- **`EntityData.bulk_delete/2` crashed instead of returning
  `:referenced_by_external`** when the referencing FK used an explicit
  `ON DELETE RESTRICT` (SQLSTATE `23001`) rather than the default `NO ACTION`
  (`23503`) — `bulk_delete/2`'s FK-violation classifier only recognized the
  latter. Pre-existing (issue #12), unrelated to #31; caught by the release gate's
  `mix test` run.

## 0.4.2 - 2026-08-14

### Fixed

- **`priv/entities/` really stops shipping now.** 0.4.1 untracked and gitignored
  those 28 test droppings, but the published tarball still carried them — Hex
  resolves `files:` against the **working directory**, not against git, so an
  untracked-but-present file ships anyway. (0.4.1's tarball actually held *more*
  of them than 0.4.0's, since the release run's own tests wrote new ones.)
  `exclude_patterns: ["priv/entities/"]` is what actually keeps runtime export
  output out of the package; verified against the built tarball rather than
  assumed.

## 0.4.1 - 2026-08-14

### Fixed

- **Anonymous public submissions crashed with a `not_null_violation`.** The
  public entity form is deliberately unauthenticated, so it passed
  `created_by_uuid` as an explicit `nil` — but `create/2` decided "was a creator
  provided?" with `Map.has_key?/2`, which reads an explicit nil as *provided*.
  The auto-fill was skipped and the insert raised Postgrex 23502 out of an
  unauthenticated controller.

  An explicit `nil` now means "this submission has no author" and is stored as
  NULL (from core 2.4.0's V169, where the column became nullable); a key that is
  absent entirely still gets the documented auto-fill, so internal callers are
  unchanged. Against an older core whose chain predates V169 the column is still
  NOT NULL and a missing creator comes back as a changeset error rather than a
  raise, so the module stays correct on both sides of the pin (#30,
  BeamLabEU/phoenix_kit#706).

  Auto-filling the first administrator was implemented first and rejected: it
  puts a named person in front of every anonymous submission wherever a creator
  is rendered, and files those submissions in that person's audit trail.

- **The auto-fill could produce a map mixing atom and string keys**, which
  `Ecto.Changeset.cast/3` refuses. Both `EntityData` and
  `PhoenixKitEntities.maybe_add_created_by/1` now write the creator under the key
  form the caller is already using.

### Removed

- **`priv/entities/` untracked from the repo.** It held 28 committed JSON files,
  every one a test dropping (`imp_conflict_*`, `imp_sel_a_*`,
  `imp_via_storage_*`, `ctx_draft`, `ef_test`, `*_widget`), and because `mix.exs`
  ships `priv` they were published to Hex and landed in consumers'
  `priv/entities/` — the directory `Storage.default_path/0` reads back.
  `write_entity/2` creates the directory on demand, so nothing depended on it
  existing. **This did not stop them shipping** — see 0.4.2.

## 0.4.0 - 2026-08-12

### Added

- **Per-module Gettext i18n (en/ru/et)** (#28). This package now owns a
  `PhoenixKitEntities.Gettext` backend and its own catalogues under
  `priv/gettext/` (487 msgids per locale). Previously every `gettext` call here
  resolved against core's `PhoenixKitWeb.Gettext`, so strings extracted from
  this package would never land in any `.po` file it ships and the admin UI
  rendered in English whatever the locale.
- **`FieldTypes.label_for/1`** — translated display labels for field types.
  Each clause is a literal `gettext(...)` call, because `gettext(type.label)`
  over the raw `@field_types` map would feed a variable to the extractor and
  the labels would never be translated at all.
- **`PGDATABASE` / `PGPOOL` overrides for the test suite** (#29).
  `config/test.exs` reads both from the environment, falling back to the
  previous hardcoded database name and `System.schedulers_online() * 2`.
  Without them the only way to run the `:integration` half of the suite was a
  Postgres role holding `CREATEDB`, which shared and managed instances
  withhold. CI and local runs are unaffected.

### Fixed

- **The package shipped without its `priv/` directory.** `files:` in `mix.exs`
  listed only `lib`, so the new `priv/gettext/**` catalogues would not have
  reached a single Hex consumer — every install would have rendered raw msgids
  regardless of locale (#28).
- **`version/0` reported `0.2.10`.** `mix.exs` declared 0.3.2, so releases
  0.3.0, 0.3.1 and 0.3.2 all shipped reporting a version they were not. It is
  now derived from `Mix.Project.config()` at compile time rather than
  hardcoded, which makes the drift unrepresentable, and a test pins the
  derivation.
- **The field-type picker reordered itself per locale.** `for_picker/0` sorted
  by the *translated* category label, so the grouping changed with the active
  language — English puts "Date & Time" before "Choice", while Estonian's
  "Kuupäev ja aeg" sorts after "Valik". It now sorts by `category_list/0`
  order, which is locale-independent (#28).
- **Dialyzer failed on the new Gettext backend.** Gettext 1.0 + Expo 1.1
  generate a `Gettext.Plural.plural/2` call against Expo's opaque
  `PluralForms` struct inside `use Gettext.Backend`, reported as
  `call_without_opaque`. Added the narrowly-scoped `.dialyzer_ignore.exs` that
  the other `phoenix_kit_*` packages with their own backend already carry, and
  wired `ignore_warnings:` in `mix.exs`.

### Changed

- Dependency updates: `phoenix` 1.8.11, `beamlab_ex_aws_sqs` 5.0.1, `hackney`
  4.7.4 and the transitive set.

## 0.3.2 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.3.1 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Fixed

- **Restores the per-language slug behaviour PR #26 shipped, which 0.3.0 removed
  by mistake.** 0.3.0's release notes claimed core's `Slug.slugify/2` ignores a
  `:locale` option. That is true of core **1.7**, and the check behind the claim
  was run against core 1.7.232 before this repo's dependencies had been updated.
  Core **2.0.0** rewrote `PhoenixKit.Utils.Slug` to delegate to the `locale_slug`
  package, and `:locale` is fully supported there:
  `Slug.slugify("Größe Fußball", locale: "de")` is `"groesse-fussball"` while
  `locale: "et"` gives `"grosse-fussball"` — German expands `ö`/`ß`, Estonian
  folds them.

  `locale:` is restored at both call sites and the `lang` parameter is threaded
  back through `auto_generate_entity_slug/4`. Records created under 0.3.0 with a
  non-primary language keep whatever slug they were given — **stored slugs are
  not rewritten** — so only newly generated slugs change.

### Note

- `:transliterate` is accepted-and-ignored by core 2.0; romanization is always
  on. The `transliterate: true` in these calls is redundant, kept for
  consistency with the rest of the umbrella.

## 0.3.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Added

- **Data tab for the `phoenix_kit_projects` hub (PR #26).** Contributed through
  `phoenix_kit_project_extensions/0`, the duck-typed one-way discovery contract —
  no dependency on the projects package.

### Fixed

- **Non-ASCII titles slugged to an empty string (PR #26).** Three call sites
  invoked core's `Slug.slugify/1` without `transliterate: true`, which defaults
  to `false` — after which the `[^a-z0-9]+` pass deletes every non-ASCII
  character outright, so a Cyrillic or Greek title produced `""`. Now
  romanizes.
- Post-merge fix on `main`: PR #26 also passed a `locale:` option to
  `Slug.slugify/2` with a comment promising language-aware output ("a German
  entry wants oe"). Core's `slugify/2` reads only `:separator` and
  `:transliterate`, so `:locale` was silently discarded and German still
  produced `schon`, not `schoen`. The dead option, its misleading comment, and
  the now-unused `lang` parameter threaded through
  `auto_generate_entity_slug/4` were removed. Slug output is unchanged by this
  removal — the option never had any effect.

## 0.2.11 - 2026-08-06

### Fixed
- **Crafted `data` payloads could store a non-scalar value that then permanently broke rendering for a record.** `LiveDataForm.whitelist_known_fields/2` filtered submitted params by key only, and `FormBuilder.validate_type/2`'s catch-all accepts any term for the types it doesn't special-case, so a map (or a list of maps) could land under a `text`/`textarea`/`rich_text` key. Every surface that renders one stringifies it naively — `to_string/1` in the readonly view, bare `{@value}` inside `<textarea>` in the edit form — and both raise `Protocol.UndefinedError` on a map, crashing the page for every subsequent viewer with no fix short of a manual DB edit. Closed at two layers: a new per-field-type value-shape gate (`LiveDataForm.sanitize_values/2`) drops a mis-shaped value at the point data enters the component, leaving the previously-stored value intact, and `EntityData.changeset/2` — the final, caller-independent word on what lands in `data`, also reachable from the admin `DataForm` and the public form — now rejects a non-scalar for those types outright. (#25)
- **The `allow_other` escape hatch accepted any term as a "custom" answer.** `EntityData.validate_choice_field/3` and `validate_checkbox_field/3`, plus `FormBuilder.validate_type/2`'s checkbox clause, waved through any out-of-options value once `allow_other` was set — a map included. `allow_other` means one free-text custom entry, so an out-of-options value (or list element) must now also be a binary. This path is reachable from the public, unauthenticated form, where the changeset is the only gate. (#25)
- **A malformed `"autosave"`/`"submit"` payload crashed the whole LiveView process, not just the component.** `%{"phoenix_kit_entity_data" => data_params}` constrains only the outer payload, so a crafted `pushEventTo` with a non-map `data_params` reached `Map.get/3` and raised `BadMapError`; a present-but-non-map `"data"` value raised the same way inside `normalize_absent_checkboxes/2`. Both now fall through to the existing empty-autosave clause. (#25)
- **The error message that rejects a bad checkbox value crashed while being built.** `Enum.join(invalid_values, ", ")` in both `EntityData.validate_checkbox_field/3` and `FormBuilder.validate_type/2` called `to_string/1` on the very non-binary term the new guards route into that list — trading a stored bad value for an attacker-triggered `Protocol.UndefinedError`. Now `Enum.map_join/3` with an `inspect/1` fallback. (#25)
- **`file` fields were the one field type both new shape gates missed, and they are rendered.** Nothing in this library produces `file` data (the `build_field/3` clause is an upload placeholder), so every value under a `file` key arrives from outside — including the unauthenticated `/entities/:entity_slug/submit` POST when the field is listed in `public_form_fields`. A stored map reached `LiveDataForm`'s readonly catch-all (`to_string/1`), and a stored list of plain strings reached `file["filename"]` in the edit form, where the Access syntax raises `FunctionClauseError` on a binary — the same permanent, un-renderable record the rest of this release closes. `LiveDataForm` now drops values submitted under `file`/`image`/`relation` keys (none render a submittable input), and `FormBuilder.build_field/3`'s `file` clause skips non-map entries. (#25 follow-up)
- **`LiveDataForm`'s readonly view now degrades instead of raising on any already-stored value.** The write-side gates above only govern new writes — rows poisoned before them, rows written by a parent app calling `EntityData` directly, and anything under a `file` key still hold whatever they hold, and the readonly view is where those get rendered. `readonly_text/1`, `readonly_value/1`, `readonly_list/1`'s join and the `select`/`radio` clause (whose `translated_option_label/3` deliberately falls back to the raw stored value) all route through a total `safe_string/1` — `inspect/1` for anything without a `String.Chars` implementation. This is what makes an already-poisoned record viewable again. (#25 follow-up)
- **Four crafted-payload crashes in the public form controller, all reached before the changeset gate.** `EntityFormController.submit/2` is un-authed by design, so the whole body is attacker-shaped and nested params arrive as maps: `get_in(params, ["phoenix_kit_entity_data", "data"])` raised on a non-map `phoenix_kit_entity_data`, a non-map `"data"` hit `merge_other_params/2`'s `is_map/1` clause head, a map under `name`/`title`/`subject`/`email` reached `String.downcase/1` via `generate_slug/1`, and a non-string `_form_loaded_at` reached `DateTime.from_iso8601/1` inside the security-check phase. Each was an unauthenticated 500 before `EntityData.changeset/2` — the gate this path relies on — ever ran. All four now degrade to the ordinary empty/absent-value path. (#25 follow-up)
- Removed eight orphaned `mix.lock` entries (`igniter`, `sourceror`, `rewrite`, `spitfire`, `owl`, `glob_ex`, `ex_ast`, `text_diff`) left by the previous dependency bump, which had `mix deps.unlock --check-unused` — and therefore `mix precommit` — failing on `main`.
- `test/phoenix_kit_entities/html_sanitizer_test.exs` no longer pins the exact byte output of `PhoenixKit.Utils.HtmlSanitizer` (a dependency). The upgraded sanitizer adds `rel="noopener noreferrer"` to links and inserts the implied `<tbody>` in tables — both upstream hardening, not regressions — which had two tests failing on `main`. They now assert that the element and its safe attributes survive.

## 0.2.10 - 2026-07-29

### Fixed
- **The admin data form showed one language in every language tab, and deleted the rest on save.** `Web.DataForm.handle_params/3` loaded the record with `EntityData.get!(uuid, lang: locale)`, where `locale` is the admin's own UI locale. That option runs `resolve_language/2`, which replaces the multilang `data` JSONB with the single merged map for that locale — `_primary_language` and every other language are gone from the struct. Two consequences, both reported as "translations aren't in the admin, but they're in the DB":
  - Every language tab rendered the same text. `MultilangForm.get_lang_data/3` asks `Multilang.get_raw_language_data/2` for the tab's language; on a flattened map that returns the whole map regardless of which language was asked for, so all tabs showed whatever the admin's UI locale resolved to.
  - The next save wrote the collapsed map back. `merge_multilang_data/4` builds the new `data` from this changeset, so `put_language_data/3` saw non-multilang data, rebuilt the structure around a single language, and the row lost the others permanently. A four-language record edited once came back with one.

  The record is now loaded raw at all three sites (both `handle_params/3` edit clauses and the `:data_updated` refresh in `handle_info/2`). The *entity* is still loaded with `:lang` — that only localises `display_name`/`description` for the admin chrome and leaves `fields_definition` alone.
- `Web.DataForm` no longer merges submitted values under a `nil` language key when the Languages module is disabled but the row still carries multilang `data` (languages configured once, later switched off). `current_lang` is nil in that state; the new `merge_lang/2` falls back to the row's embedded `_primary_language`. Flat rows are unaffected — they have no embedded primary, so the merge keeps passing params straight through.
- **The single-language layout rendered every custom field blank over a multilang row, then saved the blanks over the primary language.** Same state as above (Languages module off, row still multilang), on the read side: that layout calls `FormBuilder.build_fields/3` with `lang_code: nil`, so each field reads `data["field_key"]` straight off the changeset — one level above where a multilang row keeps its values. The fields came up empty, and the following save merged those blanks under the embedded primary via `merge_lang/2`, replacing that language's real content. The new `primary_language_view/1` hands the layout a flattened primary-language view to read from; input names are unchanged, so params still round-trip back under the primary key. Flat rows pass through untouched.

### Changed
- `EntityData.resolve_language/2` is documented as lossy and display-only, with an explicit warning never to build an update changeset from its result. `list_tree/2`'s `:lang` option points at it.

## 0.2.9 - 2026-07-27

### Changed
- **Stop calling the deprecated `PhoenixKit.Users.Auth.Scope.admin?/1`.** All 16 call sites (13 in `Web.DataNavigator`, 3 in `Web.Entities`) now call `Scope.can_access_admin_area?/1`, the name core renamed it to in phoenix_kit 1.7.214. The old name is a pure `@deprecated` delegate to the new one, so **no behavior changes** — this only silences the deprecation warning host apps were eating on every compile of this library, with no way to fix it themselves. `test/support/live_case.ex` doc comments updated to match; note the predicate is true for any permission holder, not only the Admin role, which is why core renamed it.
- **Dependency floor raised to `phoenix_kit ~> 1.7.214`** (from `~> 1.7.189`) — `can_access_admin_area?/1` does not exist below it, so an older core would be an `UndefinedFunctionError` at call time rather than a warning. This mattered concretely here: the lockfile was resolving 1.7.210, below the new floor.
- Dependency lockfile bumps: `phoenix_kit` 1.7.210 → 1.7.216, `phoenix_live_view` 1.2.7 → 1.2.8, `bandit` 1.12.0 → 1.12.4, `igniter` 0.8.2 → 0.8.3, `leaf` 0.3.0 → 0.3.2.

### Fixed
- `test/test_helper.exs` no longer aborts the entire suite on a machine with no `psql` client on PATH. `System.cmd/3` *raises* `ErlangError` when the binary is absent rather than returning a non-zero tuple, so the existing `_ -> :try_connect` fallback — written for exactly this "couldn't determine the DB via psql" case — could never fire, and `mix test` died with `:enoent` before running a single test. Now rescued and routed to that same fallback.

## 0.2.8 - 2026-07-24

### Added
- `heading` field type — display-only section header for visually grouping fields in long forms. Carries no data, is skipped by every validation path (`EntityData.changeset/2`, both `FormBuilder.validate_data/3` branches), and renders as an `<h3>` in `FormBuilder.build_field/3` and `LiveDataForm`'s readonly view. (#24)
- `allow_other` option for `select`/`radio`/`checkbox` fields — renders an extra "Other" option with a companion free-text input. `FormBuilder.merge_other_params/2` resolves the UI sentinel (`"__other__"`) into the typed value before validation on every write path (admin `DataForm`, public entity form, and the new component); stored data stays flat and backward-compatible. `FieldTypes.allow_other?/1` tolerates both `true` and `"true"` (HTML checkbox params). (#24)
- `PhoenixKitEntities.Components.LiveDataForm` — embeddable stateful `LiveComponent` for viewing/editing one `EntityData` record's fields outside the admin: `:edit` mode with debounced autosave and an optional submit button, `:readonly` mode with static output. The host LiveView owns loading, PubSub, and status semantics; the component reports `{:live_data_form, :saved | :submitted, record}` messages. Renders DB-free when `record.entity` is preloaded. (#24)
- `EntityData.update/3` gains two opt-in options, both defaulting to current behavior: `activity_log: false` (skip the per-save activity row for high-frequency callers like `LiveDataForm` autosave) and `require_status: [statuses]` (re-reads the record under `SELECT ... FOR UPDATE` inside the update transaction and refuses the write unless the fresh status is in the list — closes a cross-session race where a stale `:edit` view could write into a record another session had just transitioned). (#24)
- `FormBuilder.build_fields/3` accepts an opt-in `id_prefix`, giving per-record DOM id scoping when several forms of the same entity render on one page (e.g. `LiveDataForm` used once per record in a list). Default output is unchanged. (#24)
- Display-only field-definition translations: a field definition may carry an optional `"translations"` key (per-language `label`/option overrides). `FormBuilder.translated_label/2` and `FormBuilder.translated_option_label/3` resolve them for display only — validation and stored values always use the canonical strings. Resolved by `build_field/3` (labels + choice-option text) and by `LiveDataForm` in both modes. Not yet resolved by the admin `DataForm` or the public entity form (documented scope boundary). (#24)

### Fixed
- `EntityData.changeset/2` now validates `radio` and `checkbox` values against the field's `options` (previously only `select` was checked), rejects the `__other__` sentinel unconditionally, rejects a scalar where a checkbox list is expected, and treats `[]` as a missing value for required checkbox fields. (#24)
- `EntityData.update/3`'s `activity_log: false` option was only wired into the success path — a failed save (e.g. `LiveDataForm` autosaving against an entity with an unfilled required field, which re-validates on every debounced keystroke) still inserted a `db_pending: true` activity row every time, reopening the exact "one row per keystroke" flood the option exists to prevent. The error path now respects the same opt. (#24 follow-up)
- The entity changeset's field-type whitelist is now derived from `FieldTypes.list_types/0` instead of a hand-maintained list, which had already drifted from the real type registry. (#24)
- Removed a stale duplicate `mix.lock` entry (`beamlab_ex_aws_sqs` 4.0.0, orphaned by the `phoenix_kit` bump below, which re-aliases the same package under the `ex_aws_sqs` app name at 5.0.0) that broke `mix deps.unlock --check-unused` (i.e. `mix precommit`) on `main`.

### Changed
- Dependency lockfile bumps: `phoenix_kit` 1.7.189 → 1.7.210, `phoenix_live_view` 1.2.6 → 1.2.7, `etcher` 0.7.2 → 0.9.0, `fresco` 0.8.0 → 0.10.0, `mdex` 0.13.3 → 0.13.4, `mdex_native` 0.2.5 → 0.2.6, `ex_ast` 0.12.9 → 0.13.1, `hackney` 4.5.2 → 4.6.0, `beamlab_countries` 1.0.8 → 1.1.0, `mint` 1.9.1 → 1.9.3, `req` 0.6.2 → 0.6.3, `tessera` 0.3.2 → 0.3.4, `plug_crypto` 2.1.1 → 2.2.0, `lazy_html` 0.1.11 → 0.1.12, `earmark_parser` 1.4.45 → 1.4.46, `elixir_make` 0.9.0 → 0.10.0, `quic` 1.7.0 → 1.7.1, `glob_ex` 0.1.11 → 0.1.12; added `ex_aws_sqs` (via `beamlab_ex_aws_sqs` 5.0.0).

## 0.2.7 - 2026-07-06

### Added
- `PhoenixKitEntities.SitemapSource.sitemap_settings_schema/0` — optional `Source` behaviour callback that declares the entities source's fixed global sitemap settings (`sitemap_entities_include_index`, `sitemap_entities_auto_pattern`, `sitemap_entities_pattern`) so the core Sitemap admin screen can render editors for them instead of requiring console/`PhoenixKit.Settings` edits. Per-entity, name-keyed overrides (`sitemap_entity_{name}_pattern`, `sitemap_entity_{name}_index_path`) stay console-only by design. Core gates the call behind `function_exported?/3`, so it is inert on phoenix_kit releases that predate the schema-rendering UI. (#21)

### Fixed
- `sitemap_settings_schema/0` is now annotated `@impl true`. The pinned `phoenix_kit` (1.7.x) declares it as an optional `Source` callback, so the missing annotation tripped the compiler's `@impl` consistency check and broke `mix compile --warnings-as-errors` (i.e. `mix precommit`). (#21 follow-up)
- `UrlResolver.get_global_pattern/1` now treats a blank `sitemap_entities_pattern` as unset, mirroring the per-entity `sitemap_url_pattern` guard. The new settings schema declares `""` as this setting's default, so a blank admin value can be persisted; without the guard an empty global pattern resolved to `""` and collapsed every eligible entity record URL to the site root. (#21 follow-up)

### Changed
- Corrected the `SitemapSource` moduledoc: `sitemap_entities_auto_pattern` defaults to `false` (it was documented as enabled-by-default, contradicting the code and the new schema). The wrong default is security-relevant — auto-pattern makes every published entity, including internal/form entities, sitemap-eligible via the `/:entity_name/:slug` fallback. Also removed a customer-specific domain from the admin help text. (#21 follow-up)
- Dependency lockfile bumps: `phoenix_kit` 1.7.165 → 1.7.175, `phoenix_live_view` 1.2.3 → 1.2.5, `plug` 1.20.1 → 1.20.2, `swoosh` 1.26.1 → 1.26.3, `etcher` 0.6.6 → 0.7.1, `mdex` 0.13.1 → 0.13.3, `mdex_native` 0.2.2 → 0.2.4, `mint` 1.9.0 → 1.9.1, `db_connection` 2.10.1 → 2.10.2, `hpax` 1.0.3 → 1.0.4, `makeup` 1.2.1 → 1.2.2, `ex_ast` 0.12.0 → 0.12.7.

## 0.2.6 - 2026-06-24

### Added
- Entities sitemap source is now auto-registered with core via the `PhoenixKit.Module` `sitemap_sources/0` callback (`PhoenixKitEntities.sitemap_sources/0` returns `[PhoenixKitEntities.SitemapSource]`), so host apps pick it up with zero config. (#20)
- Per-language sitemap output: `SitemapSource.collect/1` and `sub_sitemaps/1` no longer short-circuit on the default language. They run once per enabled language and emit a localized URL for a record only when that record actually carries a translation for the locale, avoiding 404 entries. Gated on the core `sitemap_include_entities` admin toggle. (#20)
- Per-entity sitemap opt-out: set `entity.settings["sitemap_exclude"] = true` to keep an entire entity out of the sitemap regardless of routes or `sitemap_entities_auto_pattern` (mirrors the existing per-record `metadata["sitemap_exclude"]` flag). The authoritative defense for internal/form entities whose records default to status `"published"`. (#20)

### Fixed
- Sitemap per-locale translation guard no longer mistakes a flat record's field key for a locale code. Only multilang records are locale-keyed; a flat record's `data` is keyed by field names, so a field named like a base locale (e.g. `"id"` → Indonesian, `"no"` → Norwegian) was falsely counted as a translation and emitted a localized URL that 404s. `record_has_translation?/2` now gates on `Multilang.multilang_data?/1`. (#20 follow-up)

### Changed
- Dependency lockfile bumps: `phoenix_kit` 1.7.133 → 1.7.165, `phoenix` 1.8.7 → 1.8.8, `phoenix_live_view` 1.1.31 → 1.2.3, `plug` 1.19.2 → 1.20.1, `req` 0.6.1 → 0.6.2, `finch` 0.22.0 → 0.23.0, `igniter` 0.8.1 → 0.8.2, `sourceror` 1.12.0 → 1.12.2, `tessera` 0.2.1 → 0.3.1, `leaf` 0.2.21 → 0.3.0 (now backed by `mdex` instead of `earmark`). Removed the resulting orphaned top-level `earmark` lock entry.

## 0.2.5 - 2026-06-08

### Added
- Env-gated path override for `phoenix_kit*` deps: `pk_dep/3` in `mix.exs` swaps the Hex pin for a local `path:` + `override: true` checkout when `<APP>_PATH` is set (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`), for cross-repo development. A blank/unset value falls back to the published pin, so `mix hex.publish` and CI resolve exactly as before. Documented under "Local cross-repo development" in `AGENTS.md`. (#19)

### Changed
- Dependency lockfile bumps: `phoenix_kit` 1.7.120 → 1.7.133, `etcher` 0.5.1 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `oban` 2.22.1 → 2.23.0, `bandit` 1.11.1 → 1.12.0, `swoosh` 1.25.2 → 1.26.1, `tesla` 1.18.2 → 1.20.0, `req` 0.5.18 → 0.6.1, `igniter` 0.8.0 → 0.8.1, `phoenix_live_view` 1.1.30 → 1.1.31.

## 0.2.4 - 2026-05-25

### Fixed
- `PhoenixKitEntities.Web.Hooks.extract_ip/1` crashed with `Protocol.UndefinedError: protocol String.Chars not implemented for Tuple` on any non-4-tuple peer address — most commonly the IPv4-mapped IPv6 form `::ffff:a.b.c.d` that Docker bridge networks behind a reverse proxy emit. Because `extract_ip/1` runs inside `on_mount`, every entity LiveView entered a mount → crash → reconnect loop, leaving the admin Entities pages reconnecting forever. The address formatter now routes all tuples through `:inet.ntoa/1`, which handles both IPv4 4-tuples and IPv6 8-tuples and maps bad input to `"unknown"` instead of raising. (#17, #18)

### Changed
- Dependency lockfile bumps: `phoenix_kit` 1.7.116 → 1.7.120, `etcher` 0.4.6 → 0.5.1, `fresco` 0.5.4 → 0.6.3, `ex_doc` 0.40.2 → 0.40.3 (`ex_doc` is docs/dev-only).

## 0.2.3 - 2026-05-21

### Added
- `PhoenixKitEntities.UrlResolver.locale_prefix/2` — resolves the constant locale path-prefix (`"/en"`, `""`, …) for a `(language, is_default)` pair. Built for batch callers like sitemap generation: resolve once and prepend to many paths instead of re-reading the site-wide locale settings per URL.

### Changed
- `UrlResolver` now delegates to the framework-shared `phoenix_kit` core helpers instead of maintaining parallel copies: `build_path_with_language/3`'s prefix decision goes through `PhoenixKit.Modules.Sitemap.LocalePath.emit_prefix?/2` (the same policy core's own sitemap sources use), and the boot-safe primary-language check uses `PhoenixKit.Modules.Languages.prefixless_primary_safe?/0` (which also handles the mix-task context the previous local rescue missed). Behaviour-preserving.
- `SitemapSource` resolves the locale prefix once per generation in `do_collect/1` and `sub_sitemaps/1` and threads it through the entry builders, replacing the per-URL `(language, is_default)` arguments. The previous code called `build_path_with_language/3` per generated URL, each re-reading the site-wide locale settings via `PhoenixKit.Cache` (several serialized `GenServer.call`s) — roughly `4·N·L` lookups returning the same constant. The hot path is now a plain string prepend; per-generation settings lookups drop from O(N·L) to O(1).

### Fixed
- `EntityData.public_path/3` and `public_alternates/3` docstrings documented the pre-`default_language_no_prefix` behaviour ("primary language → no prefix") and shipped example URLs that were wrong under the default (setting OFF) — the primary language now gets the prefix (`/en/products/my-item`) unless the site-wide setting is ON. Prose and examples corrected. (These were illustrative, non-executed examples, so the suite was unaffected.)

## 0.2.2 - 2026-05-12

### Added
- `PhoenixKitEntities.EntityData.tree_from_rows/1` and `descendant_uuids_from_rows/2` — list-accepting variants of `list_tree/2` and `descendant_uuids/3`. Callers that need both shapes from one entity load (e.g. the parent picker) can now fetch rows once and feed both helpers instead of paying for the same `list_by_entity/2` call twice.
- Pinning test for the bulk-restore default-status contract — a row trashed via `bulk_trash/2` (no per-row metadata stash) restores to `"draft"`, not `"published"`. Guards against a future refactor accidentally re-publishing archived rows through the bulk path.

### Fixed
- `entity_form_controller.ex` `safe_referer_path/2` now explicitly rejects protocol-relative paths (`//evil.com/foo`). The same-host check already kept it from being an open redirect, but the raw `path` would bubble up to `Phoenix.Controller.redirect(to: …)` and trip its own `ArgumentError` guard with a 500. The fallback to `"/"` is now graceful. Same pass deduplicated the double `URI.parse(referer)` call by binding `query` in the URI match.
- `web/entity_form.ex` `internal_admin_path?/1` now requires `/admin/` (with trailing slash) and explicitly rejects `//`-prefixed paths. Previously `String.contains?(path, "/admin")` would also accept lookalikes like `/admin-tools/foo` and `/x/admin.json` as valid "and Return" targets.
- `web/data_form.ex` parent picker no longer loads the entity's row set twice — the previous call sequence to `EntityData.list_tree/2` followed by `EntityData.descendant_uuids/3` issued two full `list_by_entity/2` queries per mount. Now loads once and feeds both helpers.

### Changed
- `web/data_navigator.ex` `maybe_tree_order/4` delegates to `EntityData.tree_from_rows/1` instead of a near-duplicate local `tree_order/1` + `walk_for_navigator/3` implementation. Same defensive root-promotion behaviour, just from the shared source.
- Inline comment on `EntityData.validate_parent_not_descendant/1` documenting the validation-time race window (two concurrent edits on the same chain in opposite directions can each pass their own validator pass and then both commit, producing a cycle the DB will accept). Two fix paths sketched for a future PR — `pg_advisory_xact_lock` + per-row `FOR UPDATE` in the same txn, or a Postgres `BEFORE INSERT/UPDATE` trigger with a recursive-CTE acyclicity check (lives in the companion migration repo).

### Spec corrections
- `PhoenixKitEntities.get_mirror_settings/1` — spec claimed `%{definitions: boolean(), data: boolean()}` but the impl returns `%{mirror_definitions: …, mirror_data: …}`. Spec aligned with impl + docstring example.
- `PhoenixKitEntities.{enable,disable}_all_{definitions,data}_mirror/0` — four specs claimed `{non_neg_integer(), nil}` but the impl returns `{:ok, non_neg_integer()}`. Every caller already pattern-matches `{:ok, count}`. Specs corrected.

## 0.2.1 - 2026-05-05

### Changed
- Bump `phoenix_kit` lockfile from 1.7.103 → 1.7.105. The new release ships `PhoenixKit.Migration.ensure_current/2`, which `test/test_helper.exs` adopted in PR #14 as the re-runnable replacement for `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`. No production code path changed — test-suite-only impact.
- `test/test_helper.exs` — replaced a broken `dev_docs/migration_cleanup.md` doc pointer with a reference to the upstream `PhoenixKit.Migration.ensure_current/2` docstring (PR #14 review nit N1).

## 0.2.0 - 2026-05-04

### Added
- Soft-delete for `EntityData` (issue #12) — keeps rows alive when parent apps hold FK references (e.g. `orders.status_uuid` → `phoenix_kit_entity_data.uuid`). New status sentinel `"trashed"` joins the existing `{draft, published, archived}` set; no migration required.
- New public API on `PhoenixKitEntities.EntityData`: `trash/2`, `restore_from_trash/2`, `bulk_trash/2`, `bulk_restore_from_trash/2`, `list_trashed_by_entity/2`, `trashed_count/1`.
- `count_external_references/1` and `count_external_references/2` — reads `Application.get_env(:phoenix_kit_entities, :reverse_references, [])` (a list of `{entity_name, count_fn}` tuples) so parent apps can surface "used by N rows" hints. The 2-arity form takes a pre-loaded entity to skip the per-call preload when rendering many records. Informational only — not a delete-blocker.
- Three new error atoms in `PhoenixKitEntities.Errors`: `:already_trashed`, `:not_trashed`, `:referenced_by_external` with localized messages.
- DataNavigator admin UX: Trash filter view with count badge, per-row Restore-from-trash + Delete-forever buttons on trashed records, bulk-action bar branches by view (Archive/Restore/Trash on default views; Restore/Delete-forever on the Trash view).
- 130 net new tests — `entity_data_trash_test.exs` (49 tests) builds transient `_trash_test_parent` tables that mirror issue #12's exact `NOT NULL REFERENCES … ON DELETE RESTRICT` shape, exercising FK-violation paths against a real parent FK. New describe block in `data_navigator_live_test.exs` (18 tests) covers all event handlers + authorization + bulk-bar branching.
- AGENTS.md gained a "Soft-delete (trash) for EntityData" section documenting the parent-app FK motivation, public API, default-list filtering rules, slug uniqueness rationale, and the `:reverse_references` config hook.

### Changed
- `delete/2` and `bulk_delete/2` now catch `Ecto.ConstraintError` (foreign-key) and `Postgrex.Error` (SQLSTATE `23503` / `23502`) and return `{:error, :referenced_by_external}` instead of raising. The admin UI flashes a friendly message rather than a 500. **Soft return-shape change** — callers exhaustively pattern-matching `{:ok, _} | {:error, %Ecto.Changeset{}}` should add a clause for the new atom.
- Default-list queries (`list_all/1`, `list_by_entity/2`, `search_by_title/3`, `count_by_entity/2`) exclude trashed records by default. Pass `include_trashed: true` to opt in (admin trash views, reverse-reference checks). Mirror exporter inherits this exclusion — trashed records won't resurrect on re-export.
- `get_data_stats/1` now returns `trashed_records` separately; `total_records` reflects the visible (non-trashed) count.
- `get_by_slug/2` deliberately surfaces trashed rows so slug uniqueness is preserved across the trash bin.
- DataNavigator bulk Delete repurposed → soft-trash; permanent delete is a separate action available only from the Trash filter view.
- `toggle_status` cycle skips trashed (Restore is the only escape).
- `phx-disable-with` added to all 8 bulk-action buttons (3 from soft-delete additions + 5 pre-existing oversights).
- `entity_form_controller.ex` `private_or_local_ip?/1` swapped from `String.to_integer + rescue _` to `Integer.parse/1` with explicit `with`/`else` chain — pins `{int, ""}` so `"123abc"` no longer slips through as `123`.
- `sitemap_source.ex` `sub_sitemaps/1` `rescue _ -> nil` now logs the error inspect, matching the canonical pattern at the other two rescues in the file.
- `sitemap_source.ex` `enabled?/0` gained `catch :exit, _ -> false` to match the boot-resilience shape from `phoenix_kit_entities.ex` (sandbox-shutdown signals).
- `@spec` backfill on `list_trashed_by_entity/2` and `trashed_count/1`.

## 0.1.7 - 2026-05-02

### Changed
- `Web.Entities` reorder/archive/restore handlers now gate on `Scope.admin?` before any DB access — closes the missing-auth gap surfaced in PR #11 review.
- Card-view duplication in `Web.DataNavigator` collapsed via the `:draggable` attr on `<.draggable_list>` — ~80 lines removed.
- `position_update_query/2` raises `ArgumentError` on non-binary scope values (was silently fall-through).
- `ensure_manual_sort/1` logs at `Logger.error` and surfaces a warning flash when the sort-mode flip fails — admins now see the silent setting-flip outcome instead of the failure being swallowed.

### Added
- Audit row shape table in AGENTS.md documenting `actor_uuid` / `resource_uuid` / `metadata` conventions across entity and entity_data activity rows.
- Race-tolerance comment on `maybe_add_entity_position/1` documenting the concurrent-position-conflict resolution strategy.

## 0.1.6 - 2026-04-29

### Removed
- `PhoenixKitEntities.Migrations.V1` — dead code with zero callers in `lib/`, `test/`, or the host app. Entity tables are owned entirely by core PhoenixKit (`V17` creates them; `V40` / `V58` / `V67` / `V74` / `V81` evolve them). Host apps that were calling `Migrations.V1.up/1` directly should switch to `PhoenixKit.Migrations.up()`. **Note:** technically a breaking change for any standalone host that imported the V1 module, but in practice no known callers exist.
- `test/support/postgres/migrations/` — 210 lines of hand-rolled DDL deleted. Test schema now built by running core's versioned migrations directly via `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` — same call the host app makes in production. Schema drift between test and prod is now impossible by construction.

### Changed
- `Web.DataForm`, `Web.EntityForm`, `Web.EntitiesSettings` now defer DB queries from `mount/3` to `handle_params/3` — closes the still-open Phoenix iron-law follow-up from PR #9 across the remaining three admin LVs. All five admin LVs now compliant.
- `mount_data_form` / `mount_entity_form` / `mount_data_presence` / `mount_entity_presence` helpers renamed to `hydrate_*` to reflect that they fill data assigns rather than couple to the `mount/3` callback. `connected?(socket)` gating preserved exactly so presence still only initializes on the WebSocket pass.
- `entities_settings.ex`: 8-key settings map consolidated through a private `load_settings/0` helper, deduplicating the inline copy in `handle_event("save", ...)`.

### Fixed
- Test fixtures in `mirror/importer_test.exs` and `mix_tasks/import_test.exs` updated to match the real `phoenix_kit_users` schema: `account_type = 'person'` (was `'personal'`, which the production CHECK constraint rejects), `hashed_password` non-null, `inserted_at` / `updated_at` non-null. The previous hand-rolled test migration had been more permissive than production and was masking these latent bugs.

## 0.1.5 - 2026-04-28

### Fixed
- `entity_form_controller.ex`: replace `entity.id` with `entity.uuid` (lines 243 + 342) — primary key is `:uuid`, the previous reference would have crashed every public-form submission with `KeyError`
- `entity_form_controller.ex`: replace runtime-bound `logger.warning(...)` with `Logger.warning(...)` macro call — variable-bound macro dispatch raised `UndefinedFunctionError` on every `save_log` security flag

### Added
- `PhoenixKitEntities.Errors` module — central atom→message dispatcher for the 10 user-facing error categories surfaced by the admin LVs and public form
- Activity logging on every entity + entity_data CRUD path (create / update / delete / bulk operations / module toggle), with `actor_uuid` threaded from caller opts
- Public-form security hardening — X-Forwarded-For RFC1918 rejection (loopback / link-local / multicast / private-network octets), metadata size cap (`@metadata_string_cap 255`), browser/OS/device parsing
- `Mirror.Storage` filesystem path containment via `Path.expand` + boundary-prefix check
- Test infrastructure — `LiveCase`, `DataCase`, `Hooks`, test endpoint / router / layouts; supports the full LV admin smoke test suite
- 32 LiveView smoke tests across `Web.Entities`, `Web.EntityForm`, `Web.DataNavigator`, `Web.DataForm`, `Web.EntitiesSettings`
- Coverage push from 31.39% baseline to 75.14% across 5 quality batches (684 tests, 0 failures, 5/5 stable)

### Changed
- `Web.Entities` and `Web.DataNavigator` now defer DB queries from `mount/3` to `handle_params/3` — avoids the duplicate-query-on-mount Phoenix iron-law violation
- `ActivityLog` rescue shape canonicalised: `Postgrex.Error -> :ok`, `DBConnection.OwnershipError -> :ok`, fallback `error -> Logger.warning(...)`, `catch :exit, _ -> :ok`
- `Mirror.Storage` rescues narrowed from bare `rescue _` to `[ArgumentError, RuntimeError, FunctionClauseError]` for path operations
- `UrlResolver` rescues narrowed to a six-class DB-scoped list (no bare `_` catches)
- `FieldTypes.description_for/1` literal-clause helper introduced so gettext extraction works on all 12 type descriptions
- `handle_info` catch-alls promoted from silent ignore to `Logger.debug` across all 5 admin LVs
- `@spec` backfill on `routes.ex` (3 functions) and `sitemap_source.ex` (5 callbacks)
- `mix.exs` `test_coverage: [ignore_modules: [...]]` filter so coverage tracks production code, not test-support boilerplate

### Removed
- `PhoenixKitEntities.Web.DataView` — unrouted module with no callers anywhere in the workspace; verified via grep + ast-grep across `phoenix_kit_entities`, `phoenix_kit` core, and `phoenix_kit_parent`. Recoverable from git history if a public-display feature materialises later

## 0.1.4 - 2026-04-24

### Added
- `PhoenixKitEntities.UrlResolver` module — extracted URL pattern resolution and locale prefixing from `SitemapSource` into a shared helper
- `EntityData.public_path/3` and `public_url/3` — locale-aware public URL helpers with translated-slug support (`data[locale]["_slug"]`)
- `PhoenixKitEntities.list_entity_summaries/1` — lightweight sidebar query with `:lang` option
- `entities_children/2` arity on the sidebar callback for future phoenix_kit core releases that pass locale explicitly
- `PhoenixKitEntities.ActivityLog` — internal helper that logs entity and entity_data mutations through the optional `PhoenixKit.Activity` context
- README sections documenting multi-language support and public URL resolution
- Unit tests for `UrlResolver`, `public_path/3` / `public_url/3`, multilang field resolution, and per-locale sidebar cache invalidation

### Changed
- Admin LiveViews (`Web.Entities`, `Web.DataNavigator`, `Web.DataForm`) now thread the current locale through entity lookups so translated `display_name` / `display_name_plural` / `description` render in the admin UI
- Sidebar `entities_children` caches per-locale ETS entries; `invalidate_entities_cache/0` now match-deletes every locale variant instead of the single atom key
- `SitemapSource` delegates URL construction to `UrlResolver` while keeping its "prefix every language" policy
- `resolve_language/2` and `resolve_languages/2` are nil-safe so callers can pass an optional locale without a pre-check

## 0.1.3 - 2026-04-11

### Fixed
- Remove misleading Data View route override example (anti-pattern)
- Add routing anti-pattern warning to AGENTS.md
- Fix version mismatch between mix.exs and module function

## 0.1.2 - 2026-04-02

### Fixed
- Migrate select elements to daisyUI 5 label wrapper pattern
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility

## 0.1.1 - 2026-04-01

### Fixed
- Fix compilation error: replace undefined `content_status_badge` with `status_badge` from PhoenixKit core components

## 0.1.0 - 2026-03-24

### Added
- Extract Entities module from PhoenixKit into standalone `phoenix_kit_entities` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `PhoenixKitEntities` schema for dynamic entity definitions with JSONB field schemas
- Add `PhoenixKitEntities.EntityData` schema for data records with JSONB field values
- Add `PhoenixKitEntities.FieldTypes` registry with 12 supported field types
- Add `PhoenixKitEntities.FormBuilder` for dynamic form generation and validation
- Add `PhoenixKitEntities.Events` PubSub helpers for entity/data lifecycle events
- Add `PhoenixKitEntities.Presence` and `PresenceHelpers` for collaborative editing with FIFO locking
- Add admin LiveViews: Entities, EntityForm, DataNavigator, DataForm, EntitiesSettings
- Add route module with `admin_routes/0`, `admin_locale_routes/0`, and public form routes
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (v1) with `IF NOT EXISTS` for both tables (run by parent app)
- Add public form component with honeypot, time-based validation, and rate limiting
- Add sitemap integration for published entity data
- Add filesystem mirroring (export/import) with mix tasks
- Add multi-language support (auto-enabled with 2+ languages)
- Add behaviour compliance test suite
- Add unit tests for changesets, field types, events, form validation, HTML sanitization, multilang
