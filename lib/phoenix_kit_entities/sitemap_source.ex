defmodule PhoenixKitEntities.SitemapSource do
  @moduledoc """
  Entities source for sitemap generation.

  Collects published entity records from the PhoenixKit Entities system.
  Each entity can define its own URL pattern in settings, and individual
  records can be excluded via metadata.

  ## Universal Entity Support

  This source can collect ALL published entities regardless of their name.
  Auto-pattern generation is **off** by default
  (`sitemap_entities_auto_pattern: false`): only entities with a genuinely
  public route or a configured URL pattern are included. Enable
  `sitemap_entities_auto_pattern` to also emit a `/:entity_name/:slug` fallback
  for every published entity — read the warning under "Configuration" first.

  ## URL Pattern Resolution

  URL patterns are resolved using fallback chain:
  1. Entity-specific override: `entity.settings["sitemap_url_pattern"]`
  2. Router Introspection: automatic detection from parent app router
  3. Per-entity Settings: `sitemap_entity_{name}_pattern`
  4. Global Settings: `sitemap_entities_pattern`
  5. Auto-generated fallback: `/:entity_name/:slug` (if `sitemap_entities_auto_pattern` is true)

  Pattern variables:
  - `:slug` - Record slug
  - `:id` - Record ID
  - `:entity_name` - Entity name (for global pattern)

  ## Examples

      # Entity settings override (highest priority):
      # entity.settings = %{"sitemap_url_pattern" => "/blog/:slug"}
      # Generates: /blog/my-article

      # Router auto-detection (if parent app has route):
      # live "/pages/:slug", PagesLive, :show
      # Entity "page" generates: /pages/my-article

      # Settings override:
      # sitemap_entity_page_pattern = "/content/:slug"
      # Entity "page" generates: /content/my-article

      # Auto-generated fallback (opt-in; off by default):
      # Entity "hydraulic_cylinder" generates: /hydraulic_cylinder/my-product
      # Entity "contact_request" generates: /contact_request/request-123

  ## Index Pages

  By default, index/list pages are included for each entity (e.g., `/page`, `/products`).
  This can be controlled via the `sitemap_entities_include_index` setting (default: true).

  Index path resolution:
  1. Entity settings: `entity.settings["sitemap_index_path"]`
  2. Router Introspection: automatic detection (e.g., `/page` or `/pages`)
  3. Per-entity Settings: `sitemap_entity_{name}_index_path`
  4. Auto-generated fallback: `/:entity_name` (if `sitemap_entities_auto_pattern` is true)

  ## Configuration

  Settings marked *(Admin UI)* are exposed to the core Sitemap admin screen
  via `sitemap_settings_schema/0` — on phoenix_kit releases that render
  source-provided settings schemas, they can be edited there instead of only
  through `PhoenixKit.Settings`. On older phoenix_kit releases (or if this
  package predates the schema being added), every setting below still works
  exactly as before: console/Settings only.

  - `sitemap_entities_auto_pattern` - Enable auto URL pattern generation (default: false) *(Admin UI)*
  - `sitemap_entities_include_index` - Include entity index pages (default: true) *(Admin UI)*
  - `sitemap_entities_pattern` - Global pattern template (e.g., "/:entity_name/:slug") (default: none) *(Admin UI)*
  - `sitemap_entity_{name}_pattern` - Per-entity URL pattern override (console/Settings only)
  - `sitemap_entity_{name}_index_path` - Per-entity index page path override (console/Settings only)

  ## Exclusion

  Two levels of opt-out:

  - **Per entity**: set `entity.settings["sitemap_exclude"] = true` to keep an
    entire entity out of the sitemap regardless of its routes or the
    `sitemap_entities_auto_pattern` flag. Use this for internal / form entities
    (e.g. `contact_request`) whose records default to status `"published"` and
    are not meant for public indexing.
  - **Per record**: set `record.metadata["sitemap_exclude"] = true`.

  Note: only an entity with a genuinely public route or configured URL pattern
  is eligible in the first place — internal entities with no public URL are
  excluded automatically. The per-entity flag is the explicit, defensive opt-out.

  ## Sitemap Properties

  **Records:**
  - Priority: 0.8 (high priority for entity content)
  - Change frequency: weekly
  - Category: Entity display name
  - Last modified: Record's date_updated timestamp

  **Index pages:**
  - Priority: 0.7
  - Change frequency: daily
  - Category: Entity display name
  - Last modified: Entity's updated_at timestamp
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.RouteResolver
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.UrlResolver

  @impl true
  @spec source_name() :: :entities
  def source_name, do: :entities

  @impl true
  @spec sitemap_filename() :: String.t()
  def sitemap_filename, do: "sitemap-entities"

  @doc """
  Returns the admin-UI settings schema for this source, so entities-specific
  sitemap settings can be edited from the core Sitemap admin screen instead
  of only via `PhoenixKit.Settings` from the console/IEx.

  Optional callback: the core Sitemap admin only calls this when
  `function_exported?(__MODULE__, :sitemap_settings_schema, 0)` is true, so
  this ships safely against phoenix_kit releases that predate schema-based
  settings rendering — they simply never call it, and every setting below
  keeps working exactly as it does today (console/Settings only).

  Per-entity overrides (`sitemap_entity_{name}_pattern`,
  `sitemap_entity_{name}_index_path`) are intentionally NOT included here:
  they're keyed by entity name rather than being a fixed set, so they remain
  console/Settings-only regardless of admin-UI schema support.

  `@impl true` is safe: `sitemap_settings_schema/0` is declared as an
  `@optional_callbacks` entry on the `Source` behaviour in the pinned
  `phoenix_kit`, and the core admin still gates the call behind
  `function_exported?/3`, so nothing invokes it on releases that predate the
  schema-rendering UI.
  """
  @impl true
  @spec sitemap_settings_schema() :: [
          %{
            key: String.t(),
            type: :boolean | :string | :integer,
            label: String.t(),
            help: String.t() | nil,
            default: term()
          }
        ]
  def sitemap_settings_schema do
    [
      %{
        key: "sitemap_entities_include_index",
        type: :boolean,
        label: "Include entity index pages",
        help:
          "Emit index/list pages (e.g. /page, /products) alongside individual entity " <>
            "records. On by default; turn it off to keep only individual record URLs in " <>
            "the sitemap.",
        default: true
      },
      %{
        key: "sitemap_entities_auto_pattern",
        type: :boolean,
        label: "Auto-generate URLs for unrouted entities",
        help:
          "When an entity has no router match, no entity-settings override, and no " <>
            "per-entity pattern, fall back to \"/:entity_name/:slug\" for records and " <>
            "\"/:entity_name\" for its index page. This applies to every published " <>
            "entity, including internal/form entities never meant to be public -- use the " <>
            "per-entity `sitemap_exclude` setting to keep those out. Off by default; only " <>
            "enable once you've confirmed the fallback URL is actually routable.",
        default: false
      },
      %{
        key: "sitemap_entities_pattern",
        type: :string,
        label: "Global URL pattern",
        help:
          "Template applied to entities with no router match and no per-entity " <>
            "override, e.g. \"/:entity_name/:slug\". Leave blank to rely on router " <>
            "introspection or per-entity overrides instead. Per-entity overrides " <>
            "(`sitemap_entity_{name}_pattern`) take precedence over this and remain " <>
            "console/Settings-only.",
        default: ""
      }
    ]
  end

  @doc """
  Returns per-entity-type sub-sitemaps.
  Each entity type gets its own sitemap file.
  """
  @impl true
  @spec sub_sitemaps(keyword()) :: [{String.t(), [PhoenixKit.Modules.Sitemap.UrlEntry.t()]}] | nil
  def sub_sitemaps(opts) do
    is_default = Keyword.get(opts, :is_default_language, true)

    # Runs once per enabled language (the Generator iterates languages and
    # calls this with `language` + `is_default_language`). Localized URLs are
    # emitted only for records that actually have a translation in that locale
    # (see `record_has_translation?/2`), so non-default languages no longer
    # short-circuit here. Honors the `sitemap_include_entities` admin toggle.
    if enabled?() and include_entities?() do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)
      include_index = Settings.get_boolean_setting("sitemap_entities_include_index", true)
      routes_cache = UrlResolver.build_routes_cache()
      # Constant for the whole run — resolve the site-wide locale settings
      # once instead of per generated URL.
      locale_prefix = UrlResolver.locale_prefix(language, is_default)

      sub_maps =
        PhoenixKitEntities.list_active_entities()
        |> Enum.filter(&entity_sitemap_eligible?(&1, routes_cache))
        |> Enum.map(fn entity ->
          entries =
            collect_entity_entries(
              entity,
              base_url,
              include_index,
              locale_prefix,
              routes_cache,
              language,
              is_default
            )

          {entity.name, entries}
        end)
        |> Enum.reject(fn {_name, entries} -> entries == [] end)

      if sub_maps == [], do: nil, else: sub_maps
    else
      nil
    end
  rescue
    error ->
      Logger.warning("Sitemap: failed to build sub_sitemaps for entities: #{inspect(error)}")
      nil
  catch
    # `enabled?/0` in this same file already has this, with the reasoning:
    # a dead pool EXITS rather than raising, and a dead pool is the most
    # likely production cause of a sitemap failure. Without it the guard
    # missed exactly the case it exists for.
    :exit, _ -> nil
  end

  # Defensive boot resilience — `enabled?/0` runs from sitemap generation
  # paths that may execute before the DB is fully up (e.g. host-app boot
  # scripts or cold cache scenarios). The rescue covers DB-availability
  # exceptions; the `catch :exit, _` matches the canonical shape in
  # `phoenix_kit_entities.ex:enabled?/0` for sandbox-shutdown signals
  # that don't surface as exceptions.
  @impl true
  @spec enabled?() :: boolean()
  def enabled? do
    PhoenixKitEntities.enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl true
  @spec collect(keyword()) :: [PhoenixKit.Modules.Sitemap.UrlEntry.t()]
  def collect(opts \\ []) do
    # Runs once per enabled language. Localized entity URLs are emitted only
    # when the record has a translation for that locale (avoiding 404s), so we
    # no longer gate on the default language. Honors the admin toggle.
    if enabled?() and include_entities?() do
      do_collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning("Entities sitemap source failed to collect: #{inspect(error)}")
      []
  catch
    :exit, _ -> []
  end

  defp do_collect(opts) do
    base_url = Keyword.get(opts, :base_url)
    language = Keyword.get(opts, :language)
    is_default = Keyword.get(opts, :is_default_language, true)
    include_index = Settings.get_boolean_setting("sitemap_entities_include_index", true)

    # Optimization: Get all routes ONCE and build lookup map
    routes_cache = UrlResolver.build_routes_cache()
    # Constant for the whole run — resolve the site-wide locale settings
    # once instead of per generated URL.
    locale_prefix = UrlResolver.locale_prefix(language, is_default)

    # Early exit if no public entity routes exist
    if map_size(routes_cache.entity_patterns) == 0 and
         not Settings.get_boolean_setting("sitemap_entities_auto_pattern", false) do
      Logger.debug("Sitemap: No public entity routes found, skipping entities source")
      []
    else
      PhoenixKitEntities.list_active_entities()
      |> Enum.filter(&entity_sitemap_eligible?(&1, routes_cache))
      |> Enum.flat_map(
        &collect_entity_entries(
          &1,
          base_url,
          include_index,
          locale_prefix,
          routes_cache,
          language,
          is_default
        )
      )
    end
  end

  # An entity is eligible for the sitemap only when it is NOT explicitly
  # excluded AND has a genuinely public route/pattern. The exclude check is the
  # authoritative opt-out for internal/form entities (e.g. `contact_request`):
  # records there default to status "published", so the status filter alone does
  # NOT keep them out — and if `sitemap_entities_auto_pattern` is ever enabled,
  # every entity would otherwise become eligible via the fallback pattern. Set
  # `entity.settings["sitemap_exclude"] = true` to guarantee an entity is never
  # indexed regardless of routes or the auto-pattern flag.
  defp entity_sitemap_eligible?(entity, routes_cache) do
    not entity_excluded?(entity) and entity_has_public_route?(entity, routes_cache)
  end

  # Per-entity opt-out (mirrors the per-record `sitemap_exclude` metadata flag).
  defp entity_excluded?(entity) do
    case entity.settings do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      _ -> false
    end
  end

  # Check if entity has a public route (either in router or auto-pattern enabled)
  defp entity_has_public_route?(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    # Check if entity has explicit route in router
    has_explicit_route =
      Map.has_key?(routes_cache.entity_patterns, entity_lower) or
        Map.has_key?(routes_cache.entity_patterns, entity.name)

    # Check if catchall route exists (like /:entity_name/:slug)
    has_catchall_route = routes_cache.entity_patterns[:catchall] != nil

    # Check if entity has settings override
    has_settings_pattern =
      case entity.settings do
        %{"sitemap_url_pattern" => pattern} when is_binary(pattern) and pattern != "" -> true
        _ -> Settings.get_setting("sitemap_entity_#{entity.name}_pattern") != nil
      end

    # Check if auto-pattern is enabled (fallback for all entities)
    auto_pattern_enabled = Settings.get_boolean_setting("sitemap_entities_auto_pattern", false)

    has_explicit_route or has_catchall_route or has_settings_pattern or auto_pattern_enabled
  end

  defp collect_entity_entries(
         entity,
         base_url,
         include_index,
         locale_prefix,
         routes_cache,
         language,
         is_default
       ) do
    records =
      collect_entity_records(entity, base_url, locale_prefix, routes_cache, language, is_default)

    if include_index do
      prepend_index_entry(
        records,
        entity,
        base_url,
        locale_prefix,
        routes_cache,
        is_default
      )
    else
      records
    end
  end

  # For the default language, always consider the index page. For a non-default
  # language, only emit the localized index when the entity has at least one
  # record resolvable in that locale — `records` is already filtered by
  # translation presence, so a non-empty list means the localized listing
  # has content and should resolve.
  defp prepend_index_entry(records, entity, base_url, locale_prefix, routes_cache, is_default) do
    if not is_default and records == [] do
      records
    else
      case collect_entity_index(entity, base_url, locale_prefix, routes_cache) do
        nil -> records
        index_entry -> [index_entry | records]
      end
    end
  end

  defp collect_entity_records(entity, base_url, locale_prefix, routes_cache, language, is_default) do
    if entity_requires_auth_cached?(entity, routes_cache) do
      Logger.debug("Sitemap: Entity '#{entity.name}' skipped - routes require authentication")
      []
    else
      do_collect_entity_records(
        entity,
        base_url,
        locale_prefix,
        routes_cache,
        language,
        is_default
      )
    end
  rescue
    error ->
      Logger.warning("Failed to collect records for entity #{entity.name}: #{inspect(error)}")
      []
  catch
    :exit, _ -> []
  end

  defp do_collect_entity_records(
         entity,
         base_url,
         locale_prefix,
         routes_cache,
         language,
         is_default
       ) do
    url_pattern = UrlResolver.get_url_pattern_cached(entity, routes_cache)
    effective_pattern = url_pattern || get_fallback_pattern(entity)

    if effective_pattern do
      records = EntityData.published_records(entity.uuid)
      log_pattern_usage(entity, url_pattern, effective_pattern, length(records))

      records
      |> Enum.reject(&excluded?/1)
      # Per-record translation guard: for a non-default language, keep only
      # records that actually have a translation in that locale, so we never
      # emit a localized URL that 404s. The default language always emits.
      |> Enum.filter(fn record -> is_default or record_has_translation?(record, language) end)
      |> Enum.map(fn record ->
        build_entry(record, entity, effective_pattern, base_url, locale_prefix)
      end)
    else
      Logger.warning(
        "Sitemap: Entity '#{entity.name}' skipped - no URL pattern configured and fallback disabled"
      )

      []
    end
  end

  defp log_pattern_usage(entity, url_pattern, effective_pattern, count) do
    if url_pattern do
      Logger.debug(
        "Sitemap: Entity '#{entity.name}' using URL pattern: #{url_pattern} (#{count} published records)"
      )
    else
      Logger.info(
        "Sitemap: Entity '#{entity.name}' using fallback pattern: #{effective_pattern} (#{count} published records)"
      )
    end
  end

  # Fallback pattern using entity name - disabled by default
  # Enable via Settings: sitemap_entities_auto_pattern = true
  # WARNING: Only enable if you're sure routes exist for all entities
  defp get_fallback_pattern(entity) do
    if Settings.get_boolean_setting("sitemap_entities_auto_pattern", false) do
      "/#{entity.name}/:slug"
    else
      nil
    end
  end

  # Collect index page entry for entity (e.g., /page, /products) - cached version
  defp collect_entity_index(entity, base_url, locale_prefix, routes_cache) do
    index_path = UrlResolver.get_index_path_cached(entity, routes_cache)

    if index_path do
      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = index_path
      # Trust the locale prefix (site policy via emit_prefix?/2), consistent
      # with the per-record entries and every other sitemap source.
      path = locale_prefix <> index_path
      url = UrlResolver.build_url(path, base_url)

      UrlEntry.new(%{
        loc: url,
        lastmod: entity.date_updated || entity.date_created,
        changefreq: "daily",
        priority: 0.7,
        title: "#{entity.display_name || entity.display_name_plural || entity.name} - Index",
        category: entity.display_name || entity.name,
        source: :entities,
        canonical_path: canonical_path
      })
    else
      nil
    end
  rescue
    error ->
      Logger.warning("Failed to collect index for entity #{entity.name}: #{inspect(error)}")
      nil
  catch
    :exit, _ -> nil
  end

  # Check if entity requires auth using cached routes
  defp entity_requires_auth_cached?(entity, routes_cache) do
    entity_lower = String.downcase(entity.name)

    # Find the route for this entity in cached routes
    route =
      Enum.find(routes_cache.content_routes, fn route ->
        path_lower = String.downcase(route.path)

        String.contains?(path_lower, "/#{entity_lower}/") or
          String.contains?(path_lower, "/#{entity_lower}s/") or
          String.starts_with?(path_lower, "/#{entity_lower}/") or
          String.starts_with?(path_lower, "/#{entity_lower}s/")
      end)

    cond do
      # Found explicit route for this entity
      route != nil ->
        RouteResolver.route_requires_auth?(route)

      # Check catchall route
      routes_cache.entity_patterns[:catchall] != nil ->
        RouteResolver.route_requires_auth?(routes_cache.entity_patterns[:catchall])

      # No route found
      true ->
        false
    end
  end

  defp excluded?(record) do
    case record.metadata do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      _ -> false
    end
  end

  defp build_entry(record, entity, url_pattern, base_url, locale_prefix) do
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = UrlResolver.build_path(url_pattern, record)
    # The locale prefix already encodes the site's policy via
    # `UrlResolver.locale_prefix/2` -> `LocalePath.emit_prefix?/2` (e.g. empty
    # for the default language when `default_language_no_prefix?` is set). Trust
    # it, consistent with every other sitemap source — do not special-case the
    # default language here.
    path = locale_prefix <> canonical_path
    url = UrlResolver.build_url(path, base_url)

    UrlEntry.new(%{
      loc: url,
      lastmod: record.date_updated,
      changefreq: "weekly",
      priority: 0.8,
      title: record.title,
      category: entity.display_name || entity.name,
      source: :entities,
      canonical_path: canonical_path
    })
  end

  # Honors the core `sitemap_include_entities` admin toggle (default true).
  # Falls open so a settings/DB hiccup doesn't silently drop entity URLs.
  defp include_entities? do
    Sitemap.include_entities?()
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # True when `record` is a multilang record carrying an explicit translation
  # for `language` (the base locale code the Generator passes, e.g. "fr").
  #
  # Only a *multilang* record is keyed by locale at the top level
  # (`%{"_primary_language" => ..., "en-US" => %{...}, "fr-FR" => %{...}}`). A
  # *flat* record's `data` is keyed by FIELD names, so we must NOT read its keys
  # as locale codes: a field literally named like a base locale (e.g. "id" ->
  # Indonesian, "no" -> Norwegian, "it" -> Italian) would otherwise masquerade
  # as a translation and emit a localized URL that 404s — the very thing this
  # guard exists to prevent. Flat records exist only in the primary language, so
  # they never have a secondary-language translation. Gating on
  # `Multilang.multilang_data?/1` (presence of the `_primary_language` sentinel)
  # cleanly separates the two shapes. Both the requested language and the stored
  # locale keys are normalized to their base code before comparing.
  defp record_has_translation?(_record, nil), do: true

  defp record_has_translation?(record, language) when is_binary(language) do
    data = record.data

    if Multilang.multilang_data?(data) do
      base = Languages.DialectMapper.extract_base(language)

      data
      |> Map.keys()
      |> Enum.any?(fn key ->
        key != "_primary_language" and is_binary(key) and
          Languages.DialectMapper.extract_base(key) == base
      end)
    else
      # Flat record (`data` is nil or field-keyed) — no secondary-language
      # translation. `Multilang.multilang_data?/1` already returns false for nil.
      false
    end
  end
end
