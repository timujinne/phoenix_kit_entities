defmodule PhoenixKitEntities.Web.EntitiesSettings do
  @moduledoc """
  LiveView for managing entities system settings and configuration.
  Provides interface for enabling/disabling entities module and viewing statistics.

  Gated on `entities.settings` (`PhoenixKitEntities.settings_permission/0`),
  not the everyday `entities` key: import overwrites definitions and data,
  and export and the mirror switches write files. A viewer without it is
  sent to the entities list at mount, and every event re-checks the live
  scope, because a hidden page does not stop a crafted event. The check is
  `PhoenixKitEntities.can_manage_settings?/1` (held, not `Scope.can?/2`), so
  the Enable switch keeps working on a page that was open when the system
  was switched off. A fresh visit to a disabled module's page is refused by
  core's admin gate before `mount/3`; re-enabling then goes through core's
  Modules page.
  """

  use PhoenixKitWeb, :live_view
  # Override the backend `use PhoenixKitWeb, :live_view` wires by default
  # (PhoenixKitWeb.Gettext, core's own — unreachable from this package's
  # `mix gettext.extract`). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext
  on_mount(PhoenixKitEntities.Web.Hooks)

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Errors
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.Mirror.{Exporter, Importer, Storage}
  alias PhoenixKitWeb.Actor

  @impl true
  def mount(_params, _session, socket) do
    if can_manage_settings?(socket) do
      mount_settings(socket)
    else
      {:ok, refuse(socket)}
    end
  end

  defp mount_settings(socket) do
    # Defer DB queries (settings reads, entities list, stats) to handle_params/3
    # — mount runs twice (HTTP + WebSocket), handle_params runs once. See
    # Phoenix iron law.
    if connected?(socket) do
      Events.subscribe_to_all_data()
    end

    socket =
      socket
      |> assign(:page_title, gettext("Entities"))
      |> assign(:page_subtitle, gettext("Configure the entities system behavior and preferences"))
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, nil)
      |> assign(:settings, %{})
      |> assign(:entities_stats, %{})
      |> assign(:entities_list, [])
      |> assign(:mirror_path, nil)
      |> assign(:export_stats, %{})
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:import_active_tab, nil)
      |> assign(:show_import_modal, false)
      |> assign(:importing, false)
      |> assign(:exporting, false)

    {:ok, socket}
  end

  # Canonical "load admin dashboard" path. Runs once on initial connected
  # mount; would also re-run on any future `push_patch/2` to this LV. Keep
  # cheap-looking work out of here — every read below multiplies on patch.
  @impl true
  def handle_params(_params, _uri, socket) do
    project_title = Settings.get_project_title()

    settings = load_settings()

    socket =
      socket
      |> assign(:project_title, project_title)
      |> assign(:settings, settings)
      |> assign(:entities_stats, get_entities_stats())
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> assign(:mirror_path, Storage.root_path())
      |> assign(:export_stats, Storage.get_stats())

    {:noreply, socket}
  end

  # The page renders the system switch and the mirror tools only.
  defp load_settings do
    %{entities_enabled: Entities.enabled?()}
  end

  # Every event — the system switch, mirror toggles, export and import — is
  # re-checked against the live scope, not a mount decision.
  @impl true
  def handle_event(event, params, socket) do
    if can_manage_settings?(socket) do
      settings_event(event, params, socket)
    else
      {:noreply, refuse(socket)}
    end
  end

  # Held, not `can?/2`: the page holds the module's on/off switch, and
  # `can?/2` refuses every sub-key while the module is off.
  defp can_manage_settings?(socket) do
    Entities.can_manage_settings?(socket.assigns[:phoenix_kit_current_scope])
  end

  defp refuse(socket) do
    socket
    |> put_flash(:error, gettext("You do not have permission to change Entities settings."))
    |> push_navigate(to: Routes.path("/admin/entities"))
  end

  defp settings_event("enable_entities", _params, socket) do
    case Entities.enable_system(Actor.opts(socket)) do
      {:ok, _setting} ->
        settings = Map.put(socket.assigns.settings, :entities_enabled, true)

        socket =
          socket
          |> assign(:settings, settings)
          |> assign(:entities_stats, get_entities_stats())
          |> put_flash(:info, gettext("Entities system enabled successfully"))

        {:noreply, socket}

      {:error, reason} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Failed to enable entities: %{reason}", reason: reason)
          )

        {:noreply, socket}
    end
  end

  defp settings_event("disable_entities", _params, socket) do
    case Entities.disable_system(Actor.opts(socket)) do
      {:ok, _setting} ->
        settings = Map.put(socket.assigns.settings, :entities_enabled, false)

        socket =
          socket
          |> assign(:settings, settings)
          |> assign(:entities_stats, get_entities_stats())
          |> put_flash(:info, gettext("Entities system disabled successfully"))

        {:noreply, socket}

      {:error, reason} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Failed to disable entities: %{reason}", reason: reason)
          )

        {:noreply, socket}
    end
  end

  ## Per-Entity Mirror Events

  defp settings_event("toggle_entity_definitions", %{"uuid" => entity_uuid}, socket) do
    with {:ok, entity} <- fetch_entity(entity_uuid),
         {:ok, updated_entity} <- toggle_definitions_setting(entity, Actor.opts(socket)) do
      maybe_export_entity(updated_entity, Entities.mirror_definitions_enabled?(updated_entity))
      {:noreply, refresh_entities_list(socket)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Entity not found"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update mirror settings"))}
    end
  end

  defp settings_event("toggle_entity_data", %{"uuid" => entity_uuid}, socket) do
    with {:ok, entity} <- fetch_entity(entity_uuid),
         {:ok, updated_entity} <- toggle_data_setting(entity, Actor.opts(socket)) do
      maybe_export_entity(updated_entity, Entities.mirror_data_enabled?(updated_entity))
      {:noreply, refresh_entities_list(socket)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Entity not found"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update mirror settings"))}
    end
  end

  defp settings_event("export_entity_now", %{"uuid" => entity_uuid}, socket) do
    case Entities.get_entity(entity_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Entity not found"))}

      entity ->
        {:noreply, do_export_entity(socket, entity)}
    end
  end

  ## Bulk Mirror Actions

  defp settings_event("enable_all_definitions", _params, socket) do
    {:ok, count} = Entities.enable_all_definitions_mirror(Actor.opts(socket))

    # Export all entities
    socket = assign(socket, :exporting, true)
    send(self(), :do_full_export)

    socket =
      socket
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> put_flash(:info, gettext("Enabled definition sync for %{count} entities", count: count))

    {:noreply, socket}
  end

  defp settings_event("disable_all_definitions", _params, socket) do
    # Disabling definitions also disables data
    {:ok, _} = Entities.disable_all_data_mirror(Actor.opts(socket))
    {:ok, count} = Entities.disable_all_definitions_mirror(Actor.opts(socket))

    socket =
      socket
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> put_flash(:info, gettext("Disabled definition sync for %{count} entities", count: count))

    {:noreply, socket}
  end

  defp settings_event("enable_all_data", _params, socket) do
    # Enabling data also requires definitions to be enabled
    {:ok, _} = Entities.enable_all_definitions_mirror(Actor.opts(socket))
    {:ok, count} = Entities.enable_all_data_mirror(Actor.opts(socket))

    # Export all entities with data
    socket = assign(socket, :exporting, true)
    send(self(), :do_full_export)

    socket =
      socket
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> put_flash(:info, gettext("Enabled data sync for %{count} entities", count: count))

    {:noreply, socket}
  end

  defp settings_event("disable_all_data", _params, socket) do
    {:ok, count} = Entities.disable_all_data_mirror(Actor.opts(socket))

    socket =
      socket
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> put_flash(:info, gettext("Disabled data sync for %{count} entities", count: count))

    {:noreply, socket}
  end

  defp settings_event("export_now", _params, socket) do
    socket = assign(socket, :exporting, true)
    send(self(), :do_full_export)
    {:noreply, socket}
  end

  defp settings_event("show_import_modal", _params, socket) do
    preview = Importer.preview_import()

    # Initialize selections based on preview - default to appropriate action
    selections = build_default_selections(preview)
    first_entity = List.first(preview.entities)

    socket =
      socket
      |> assign(:import_preview, preview)
      |> assign(:import_selections, selections)
      |> assign(:import_active_tab, first_entity && first_entity.name)
      |> assign(:show_import_modal, true)

    {:noreply, socket}
  end

  defp settings_event("hide_import_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_import_modal, false)
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:import_active_tab, nil)

    {:noreply, socket}
  end

  defp settings_event("set_import_tab", %{"tab" => entity_name}, socket) do
    {:noreply, assign(socket, :import_active_tab, entity_name)}
  end

  defp settings_event(
         "set_definition_action",
         %{"entity" => entity_name, "action" => action},
         socket
       ) do
    action_atom = String.to_existing_atom(action)
    selections = put_in(socket.assigns.import_selections, [entity_name, :definition], action_atom)
    {:noreply, assign(socket, :import_selections, selections)}
  end

  defp settings_event(
         "set_record_action",
         %{"entity" => entity_name, "slug" => slug, "action" => action},
         socket
       ) do
    action_atom = String.to_existing_atom(action)
    selections = put_in(socket.assigns.import_selections, [entity_name, :data, slug], action_atom)
    {:noreply, assign(socket, :import_selections, selections)}
  end

  defp settings_event(
         "set_all_records_action",
         %{"entity" => entity_name, "action" => action},
         socket
       ) do
    action_atom = String.to_existing_atom(action)

    # Find the entity in preview to get all slugs
    entity = Enum.find(socket.assigns.import_preview.entities, &(&1.name == entity_name))

    if entity do
      new_data_selections =
        entity.data
        |> Enum.map(fn record -> {record.slug, action_atom} end)
        |> Map.new()

      selections =
        put_in(socket.assigns.import_selections, [entity_name, :data], new_data_selections)

      {:noreply, assign(socket, :import_selections, selections)}
    else
      {:noreply, socket}
    end
  end

  defp settings_event("do_import_entity", %{"entity" => entity_name}, socket) do
    # Only import selections for the specified entity
    entity_selections = Map.get(socket.assigns.import_selections, entity_name, %{})
    filtered_selections = %{entity_name => entity_selections}

    socket =
      socket
      |> assign(:importing, true)
      |> assign(:show_import_modal, false)

    send(self(), {:do_import, filtered_selections})
    {:noreply, socket}
  end

  defp settings_event("do_import", _params, socket) do
    socket =
      socket
      |> assign(:importing, true)
      |> assign(:show_import_modal, false)

    send(self(), {:do_import, socket.assigns.import_selections})
    {:noreply, socket}
  end

  defp settings_event("refresh_export_stats", _params, socket) do
    socket =
      socket
      |> assign(:export_stats, Storage.get_stats())

    {:noreply, socket}
  end

  ## Per-entity mirror helpers

  defp do_export_entity(socket, entity) do
    message =
      case Exporter.export_entity(entity) do
        {:ok, _path, :with_data} ->
          gettext("Exported %{name} (definition + records)", name: entity.display_name)

        {:ok, _path, :definition_only} ->
          gettext("Exported %{name} (definition only)", name: entity.display_name)

        {:error, _reason} ->
          nil
      end

    socket = assign(socket, :export_stats, Storage.get_stats())

    if message,
      do: put_flash(socket, :info, message),
      else: put_flash(socket, :error, gettext("Export failed"))
  end

  defp fetch_entity(entity_uuid) do
    case Entities.get_entity(entity_uuid) do
      nil -> {:error, :not_found}
      entity -> {:ok, entity}
    end
  end

  defp toggle_definitions_setting(entity, opts) do
    new_value = !Entities.mirror_definitions_enabled?(entity)

    new_settings =
      if new_value,
        do: %{"mirror_definitions" => true},
        else: %{"mirror_definitions" => false, "mirror_data" => false}

    Entities.update_mirror_settings(entity, new_settings, opts)
  end

  defp toggle_data_setting(entity, opts) do
    new_value = !Entities.mirror_data_enabled?(entity)
    Entities.update_mirror_settings(entity, %{"mirror_data" => new_value}, opts)
  end

  defp maybe_export_entity(entity, true) do
    Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
      Exporter.export_entity(entity)
    end)
  end

  defp maybe_export_entity(_entity, false), do: :ok

  defp refresh_entities_list(socket) do
    socket
    |> assign(:entities_list, Entities.list_entities_with_mirror_status())
    |> assign(:export_stats, Storage.get_stats())
  end

  ## Live updates

  @impl true
  def handle_info({event, _entity_uuid}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    socket =
      socket
      |> assign(:entities_stats, get_entities_stats())
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> assign(:export_stats, Storage.get_stats())

    {:noreply, socket}
  end

  def handle_info({event, _entity_uuid, _data_uuid}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    # A bulk delete queues one event per row; one reload covers them all.
    Events.flush_data_events()

    socket =
      socket
      |> assign(:entities_stats, get_entities_stats())
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> assign(:export_stats, Storage.get_stats())

    {:noreply, socket}
  end

  ## Mirror background operations

  def handle_info(:do_full_export, socket) do
    {:ok, %{definitions: def_count, data: data_count}} = Exporter.export_all()

    socket =
      socket
      |> assign(:exporting, false)
      |> assign(:export_stats, Storage.get_stats())
      |> assign(:entities_list, Entities.list_entities_with_mirror_status())
      |> put_flash(
        :info,
        gettext("Export complete. %{defs} definitions, %{data} records.",
          defs: def_count,
          data: data_count
        )
      )

    {:noreply, socket}
  end

  def handle_info({:do_import, selections}, socket) do
    {:ok, %{definitions: def_results, data: data_results} = result} =
      Importer.import_selected(selections)

    socket =
      socket
      |> assign(:importing, false)
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:export_stats, Storage.get_stats())
      |> assign(:entities_stats, get_entities_stats())
      |> put_import_flash(def_results, data_results)
      |> put_unresolved_links_flash(Map.get(result, :unresolved_links, []))

    {:noreply, socket}
  end

  # Catch-all — log at :debug rather than crashing the socket so unexpected
  # messages stay visible during development without producing noise in prod.
  def handle_info(message, socket) do
    Logger.debug(fn ->
      "EntitiesSettings: unhandled handle_info — #{inspect(message)}"
    end)

    {:noreply, socket}
  end

  # Private Functions

  # An import is one transaction per run: when a write fails, every result
  # comes back `{:rolled_back, _}` and nothing was saved — that must not
  # read as "complete, 0 created".
  defp put_import_flash(socket, def_results, data_results) do
    errors = for {:error, reason} <- def_results ++ data_results, do: reason

    case {errors, Enum.find(errors, &match?({:rolled_back, _}, &1))} do
      {[], _} ->
        put_flash(socket, :info, import_counts_text(def_results, data_results))

      {_, {:rolled_back, _} = rolled_back} ->
        put_flash(
          socket,
          :error,
          gettext("Import failed. %{reason}", reason: Errors.message(rolled_back))
        )

      {[first | _], nil} ->
        socket
        |> put_flash(:info, import_counts_text(def_results, data_results))
        |> put_flash(
          :error,
          gettext("Import finished with %{count} error(s), the first: %{reason}",
            count: length(errors),
            reason: Errors.message(first)
          )
        )
    end
  end

  defp import_counts_text(def_results, data_results) do
    count = fn results, status -> Enum.count(results, &match?({:ok, ^status, _}, &1)) end

    gettext(
      "Import complete. Definitions: %{dc} created, %{du} updated, %{ds} skipped. Data: %{rc} created, %{ru} updated, %{rs} skipped.",
      dc: count.(def_results, :created),
      du: count.(def_results, :updated),
      ds: count.(def_results, :skipped),
      rc: count.(data_results, :created),
      ru: count.(data_results, :updated),
      rs: count.(data_results, :skipped)
    )
  end

  # Links to records that are neither in the import nor in the database
  # were left out of the records that carried them.
  @unresolved_links_shown 5

  defp put_unresolved_links_flash(socket, []), do: socket

  defp put_unresolved_links_flash(socket, unresolved) do
    records =
      unresolved
      |> Enum.take(@unresolved_links_shown)
      |> Enum.map_join(", ", &"#{&1.entity}/#{&1.slug} (#{&1.field})")

    put_flash(
      socket,
      :warning,
      gettext(
        "%{count} relation field(s) pointed at records that could not be found and were left without them: %{records}",
        count: length(unresolved),
        records: records
      )
    )
  end

  defp get_entities_stats do
    if Entities.enabled?() do
      entities_stats = Entities.get_system_stats()
      data_stats = EntityData.get_data_stats()

      Map.merge(entities_stats, data_stats)
    else
      %{
        total_entities: 0,
        active_entities: 0,
        total_data_records: 0,
        published_records: 0,
        draft_records: 0,
        archived_records: 0
      }
    end
  end

  # Helper functions for templates

  def setting_status_class(enabled) do
    if enabled, do: "badge-success", else: "badge-error"
  end

  def setting_status_text(enabled) do
    if enabled, do: gettext("Enabled"), else: gettext("Disabled")
  end

  # Build default import selections based on preview
  # - NEW items default to :overwrite (will create)
  # - IDENTICAL items default to :skip (nothing to do)
  # - CHANGED items default to :skip (safe default)
  defp build_default_selections(%{entities: entities}) do
    entities
    |> Enum.map(fn entity ->
      def_action = default_action_for(entity.definition.action)

      data_selections =
        entity.data
        |> Enum.map(fn record ->
          {record.slug, default_action_for(record.action)}
        end)
        |> Map.new()

      {entity.name, %{definition: def_action, data: data_selections}}
    end)
    |> Map.new()
  end

  defp default_action_for(:create), do: :overwrite
  defp default_action_for(:identical), do: :skip
  defp default_action_for(:conflict), do: :skip
  defp default_action_for(_), do: :skip

  # Helper to get current action for a record from selections
  def get_record_action(selections, entity_name, slug) do
    get_in(selections, [entity_name, :data, slug]) || :skip
  end

  def get_definition_action(selections, entity_name) do
    get_in(selections, [entity_name, :definition]) || :skip
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- System Status Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-2xl mb-4">
              <.icon name="hero-cog-6-tooth" class="w-6 h-6" /> {gettext("System Status")}
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <%!-- System Toggle --%>
              <div>
                <div class="flex items-center justify-between mb-4">
                  <div>
                    <h3 class="text-lg font-semibold">{gettext("Entities System")}</h3>
                    <p class="text-sm text-base-content/70">
                      {gettext("Enable or disable the entire entities module")}
                    </p>
                  </div>
                  <span class={"badge #{setting_status_class(@settings.entities_enabled)}"}>
                    {setting_status_text(@settings.entities_enabled)}
                  </span>
                </div>

                <div class="flex gap-2">
                  <%= if @settings.entities_enabled do %>
                    <button
                      class="btn btn-error btn-sm"
                      phx-click="disable_entities"
                      phx-disable-with={gettext("Disabling…")}
                      data-confirm={
                        gettext(
                          "Are you sure you want to disable the entities system? This will make all entities and data inaccessible."
                        )
                      }
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4 mr-1" /> {gettext("Disable System")}
                    </button>
                  <% else %>
                    <button
                      class="btn btn-success btn-sm"
                      phx-click="enable_entities"
                      phx-disable-with={gettext("Enabling…")}
                    >
                      <.icon name="hero-check" class="w-4 h-4 mr-1" /> {gettext("Enable System")}
                    </button>
                  <% end %>
                </div>
              </div>

              <%!-- Quick Stats --%>
              <div>
                <h3 class="text-lg font-semibold mb-4">{gettext("Quick Stats")}</h3>
                <div class="grid grid-cols-2 gap-4">
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Entities")}</div>
                    <div class="stat-value text-lg">{@entities_stats.total_entities}</div>
                  </div>
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Data Records")}</div>
                    <div class="stat-value text-lg">{@entities_stats.total_data_records}</div>
                  </div>
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Published")}</div>
                    <div class="stat-value text-lg">{@entities_stats.published_records}</div>
                  </div>
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Drafts")}</div>
                    <div class="stat-value text-lg">{@entities_stats.draft_records}</div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Mirror & Export Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-2xl mb-4">
              <.icon name="hero-arrow-path" class="w-6 h-6" /> {gettext("Mirror & Export")}
            </h2>
            <p class="text-base-content/70 mb-4">
              {gettext(
                "Sync entity definitions and data to filesystem for version control and backup."
              )}
            </p>

            <%!-- Bulk Actions --%>
            <div class="flex flex-wrap gap-2 mb-4">
              <div class="dropdown dropdown-hover">
                <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                  <.icon name="hero-document-text" class="w-4 h-4" />
                  {gettext("Definitions")}
                  <.icon name="hero-chevron-down" class="w-3 h-3" />
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                >
                  <li>
                    <button
                      phx-click="enable_all_definitions"
                      phx-disable-with={gettext("…")}
                      class="text-success"
                    >
                      <.icon name="hero-check" class="w-4 h-4" />
                      {gettext("Enable All")}
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="disable_all_definitions"
                      phx-disable-with={gettext("…")}
                      class="text-error"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                      {gettext("Disable All")}
                    </button>
                  </li>
                </ul>
              </div>

              <div class="dropdown dropdown-hover">
                <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                  <.icon name="hero-circle-stack" class="w-4 h-4" />
                  {gettext("Records")}
                  <.icon name="hero-chevron-down" class="w-3 h-3" />
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                >
                  <li>
                    <button
                      phx-click="enable_all_data"
                      phx-disable-with={gettext("…")}
                      class="text-success"
                    >
                      <.icon name="hero-check" class="w-4 h-4" />
                      {gettext("Enable All")}
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="disable_all_data"
                      phx-disable-with={gettext("…")}
                      class="text-error"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                      {gettext("Disable All")}
                    </button>
                  </li>
                </ul>
              </div>

              <button
                class="btn btn-sm btn-primary"
                phx-click="export_now"
                phx-disable-with={gettext("Exporting…")}
                disabled={@exporting}
              >
                <%= if @exporting do %>
                  <span class="loading loading-spinner loading-xs"></span>
                  {gettext("Exporting...")}
                <% else %>
                  <.icon name="hero-arrow-up-tray" class="w-4 h-4" />
                  {gettext("Export All")}
                <% end %>
              </button>

              <button
                class="btn btn-sm btn-outline btn-secondary"
                phx-click="show_import_modal"
                disabled={@importing}
              >
                <%= if @importing do %>
                  <span class="loading loading-spinner loading-xs"></span>
                  {gettext("Importing...")}
                <% else %>
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                  {gettext("Import")}
                <% end %>
              </button>
            </div>

            <%!-- Entities Table --%>
            <%= if length(@entities_list) > 0 do %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>{gettext("Entity")}</th>
                      <th class="text-center">{gettext("Records")}</th>
                      <th class="text-center">{gettext("Live Sync")}</th>
                      <th class="text-center">{gettext("Actions")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for entity <- @entities_list do %>
                      <tr>
                        <td>
                          <div class="flex items-center gap-2">
                            <span class="font-medium">{entity.display_name}</span>
                            <span class="text-xs text-base-content/50">({entity.name})</span>
                            <%= if entity.file_exists do %>
                              <span
                                class="badge badge-ghost badge-xs h-auto"
                                title={gettext("File exists")}
                              >
                                <.icon name="hero-document-check" class="w-3 h-3" />
                              </span>
                            <% end %>
                          </div>
                        </td>
                        <td class="text-center">
                          <span class="badge badge-ghost">{entity.data_count}</span>
                        </td>
                        <td class="text-center">
                          <div class="flex flex-col items-center gap-1">
                            <%!-- Definition toggle --%>
                            <div class="flex items-center gap-2">
                              <span class="text-xs text-base-content/70 w-14 text-right">
                                {gettext("Definition")}
                              </span>
                              <%= if entity.mirror_definitions do %>
                                <button
                                  class="btn btn-outline btn-success btn-xs tooltip tooltip-bottom"
                                  phx-click="toggle_entity_definitions"
                                  phx-value-uuid={entity.uuid}
                                  phx-disable-with={gettext("…")}
                                  data-tip={gettext("Disable Definition sync")}
                                >
                                  <.icon name="hero-check" class="w-3 h-3 hidden sm:inline" />
                                  <span class="sm:hidden whitespace-nowrap">
                                    {gettext("Disable")}
                                  </span>
                                </button>
                              <% else %>
                                <button
                                  class="btn btn-outline btn-xs tooltip tooltip-bottom"
                                  phx-click="toggle_entity_definitions"
                                  phx-value-uuid={entity.uuid}
                                  phx-disable-with={gettext("…")}
                                  data-tip={gettext("Enable Definition sync")}
                                >
                                  <.icon name="hero-x-mark" class="w-3 h-3 hidden sm:inline" />
                                  <span class="sm:hidden whitespace-nowrap">{gettext("Enable")}</span>
                                </button>
                              <% end %>
                            </div>

                            <%!-- Records toggle (label greyed out when definition sync is disabled) --%>
                            <div class="flex items-center gap-2">
                              <span class={"text-xs text-base-content/70 w-14 text-right #{unless entity.mirror_definitions, do: "opacity-50"}"}>
                                {gettext("Records")}
                              </span>
                              <%= if entity.mirror_definitions do %>
                                <%= if entity.mirror_data do %>
                                  <button
                                    class="btn btn-outline btn-success btn-xs tooltip tooltip-bottom"
                                    phx-click="toggle_entity_data"
                                    phx-value-uuid={entity.uuid}
                                    phx-disable-with={gettext("…")}
                                    data-tip={gettext("Disable Records sync")}
                                  >
                                    <.icon name="hero-check" class="w-3 h-3 hidden sm:inline" />
                                    <span class="sm:hidden whitespace-nowrap">
                                      {gettext("Disable")}
                                    </span>
                                  </button>
                                <% else %>
                                  <button
                                    class="btn btn-outline btn-xs tooltip tooltip-bottom"
                                    phx-click="toggle_entity_data"
                                    phx-value-uuid={entity.uuid}
                                    phx-disable-with={gettext("…")}
                                    data-tip={gettext("Enable Records sync")}
                                  >
                                    <.icon name="hero-x-mark" class="w-3 h-3 hidden sm:inline" />
                                    <span class="sm:hidden whitespace-nowrap">
                                      {gettext("Enable")}
                                    </span>
                                  </button>
                                <% end %>
                              <% else %>
                                <button
                                  class="btn btn-outline btn-xs"
                                  disabled
                                  title={gettext("Enable definition sync first")}
                                >
                                  <.icon name="hero-x-mark" class="w-3 h-3" />
                                </button>
                              <% end %>
                            </div>
                          </div>
                        </td>
                        <td class="text-center">
                          <button
                            class="btn btn-ghost btn-xs tooltip tooltip-bottom"
                            phx-click="export_entity_now"
                            phx-value-uuid={entity.uuid}
                            phx-disable-with={gettext("…")}
                            data-tip={gettext("Export now")}
                          >
                            <.icon name="hero-arrow-up-tray" class="w-4 h-4 hidden sm:inline" />
                            <span class="sm:hidden whitespace-nowrap">{gettext("Export now")}</span>
                          </button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% else %>
              <div class="text-center py-8 text-base-content/50">
                <.icon name="hero-inbox" class="w-12 h-12 mx-auto mb-2" />
                <p>{gettext("No entities defined yet")}</p>
              </div>
            <% end %>

            <%!-- Export Info Footer --%>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mt-6 pt-4 border-t border-base-300">
              <%!-- Export Path --%>
              <div class="p-3 bg-base-200 rounded-lg">
                <p class="font-medium text-sm mb-1">{gettext("Export Path")}</p>
                <code class="text-xs text-base-content/70 break-all">{@mirror_path}</code>
              </div>

              <%!-- Export Stats --%>
              <div class="p-3 bg-base-200 rounded-lg">
                <p class="font-medium text-sm mb-1">{gettext("Exported Files")}</p>
                <p class="text-sm text-base-content/70">
                  {gettext("%{defs} definitions, %{data} data records",
                    defs: @export_stats.definitions_count,
                    data: @export_stats.data_count
                  )}
                </p>
              </div>

              <%!-- Last Export --%>
              <div class="p-3 bg-base-200 rounded-lg">
                <p class="font-medium text-sm mb-1">{gettext("Last Export")}</p>
                <p class="text-sm text-base-content/70">
                  <%= if @export_stats.last_export do %>
                    {@export_stats.last_export}
                  <% else %>
                    {gettext("Never")}
                  <% end %>
                </p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Import Modal --%>
        <%= if @show_import_modal do %>
          <div class="modal modal-open">
            <div class="modal-box max-w-4xl max-h-[90vh]">
              <h3 class="font-bold text-lg mb-4">
                <.icon name="hero-arrow-down-tray" class="w-5 h-5 mr-2 inline" />
                {gettext("Import Entities")}
              </h3>

              <%= if @import_preview do %>
                <%!-- Summary Stats --%>
                <div class="grid grid-cols-2 gap-4 mb-4">
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Definitions")}</div>
                    <div class="stat-value text-lg">{@import_preview.summary.definitions.total}</div>
                    <div class="stat-desc">
                      {gettext("%{new} new, %{identical} identical, %{conflicts} changed",
                        new: @import_preview.summary.definitions.new,
                        identical: @import_preview.summary.definitions.identical,
                        conflicts: @import_preview.summary.definitions.conflicts
                      )}
                    </div>
                  </div>
                  <div class="stat bg-base-200 rounded p-3">
                    <div class="stat-title text-xs">{gettext("Data Records")}</div>
                    <div class="stat-value text-lg">{@import_preview.summary.data.total}</div>
                    <div class="stat-desc">
                      {gettext("%{new} new, %{identical} identical, %{conflicts} changed",
                        new: @import_preview.summary.data.new,
                        identical: @import_preview.summary.data.identical,
                        conflicts: @import_preview.summary.data.conflicts
                      )}
                    </div>
                  </div>
                </div>

                <%!-- Entity Tabs --%>
                <%= if length(@import_preview.entities) > 0 do %>
                  <%!-- Core's <.nav_tabs>: the payload key moves from
                       `entity` to the component's standard `tab`. --%>
                  <.nav_tabs
                    variant={:border}
                    class="mb-4"
                    active_tab={@import_active_tab}
                    on_change="set_import_tab"
                    tabs={
                      Enum.map(@import_preview.entities, fn entity ->
                        %{id: entity.name, label: entity.name, badge: length(entity.data)}
                      end)
                    }
                  />

                  <%!-- Active Entity Content --%>
                  <%= for entity <- @import_preview.entities do %>
                    <div class={if @import_active_tab == entity.name, do: "", else: "hidden"}>
                      <%!-- Definition Section --%>
                      <div class="bg-base-200 rounded-lg p-4 mb-4">
                        <div class="flex items-center justify-between">
                          <div class="flex items-center gap-2">
                            <span class="font-semibold">{gettext("Definition")}</span>
                            <%= case entity.definition.action do %>
                              <% :create -> %>
                                <span class="badge badge-success badge-sm h-auto">
                                  {gettext("NEW")}
                                </span>
                              <% :identical -> %>
                                <span class="badge badge-ghost badge-sm h-auto">
                                  {gettext("IDENTICAL")}
                                </span>
                              <% :conflict -> %>
                                <span class="badge badge-warning badge-sm h-auto">
                                  {gettext("CHANGED")}
                                </span>
                              <% _ -> %>
                                <span class="badge badge-error badge-sm h-auto">
                                  {gettext("ERROR")}
                                </span>
                            <% end %>
                          </div>
                          <label class="select select-sm">
                            <select
                              phx-change="set_definition_action"
                              phx-value-entity={entity.name}
                              name="action"
                            >
                              <option
                                value="skip"
                                selected={
                                  get_definition_action(@import_selections, entity.name) == :skip
                                }
                              >
                                {gettext("Skip")}
                              </option>
                              <option
                                value="overwrite"
                                selected={
                                  get_definition_action(@import_selections, entity.name) ==
                                    :overwrite
                                }
                              >
                                {gettext("Import/Overwrite")}
                              </option>
                              <option
                                value="merge"
                                selected={
                                  get_definition_action(@import_selections, entity.name) == :merge
                                }
                              >
                                {gettext("Merge")}
                              </option>
                            </select>
                          </label>
                        </div>
                      </div>

                      <%!-- Data Records Section --%>
                      <%= if length(entity.data) > 0 do %>
                        <div class="flex items-center justify-between mb-2">
                          <span class="font-semibold">
                            {gettext("Data Records")} ({length(entity.data)})
                          </span>
                          <div class="flex gap-2">
                            <button
                              class="btn btn-xs btn-ghost"
                              phx-click="set_all_records_action"
                              phx-value-entity={entity.name}
                              phx-value-action="skip"
                            >
                              {gettext("Skip All")}
                            </button>
                            <button
                              class="btn btn-xs btn-ghost"
                              phx-click="set_all_records_action"
                              phx-value-entity={entity.name}
                              phx-value-action="overwrite"
                            >
                              {gettext("Import All")}
                            </button>
                          </div>
                        </div>

                        <div class="overflow-y-auto max-h-64 border border-base-300 rounded-lg">
                          <table class="table table-sm table-zebra">
                            <thead class="sticky top-0 bg-base-200">
                              <tr>
                                <th>{gettext("Status")}</th>
                                <th>{gettext("Slug")}</th>
                                <th>{gettext("Title")}</th>
                                <th class="text-right">{gettext("Action")}</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for record <- entity.data do %>
                                <tr>
                                  <td>
                                    <%= case record.action do %>
                                      <% :create -> %>
                                        <span class="badge badge-success badge-xs h-auto">
                                          {gettext("NEW")}
                                        </span>
                                      <% :identical -> %>
                                        <span class="badge badge-ghost badge-xs h-auto">
                                          {gettext("IDENTICAL")}
                                        </span>
                                      <% :conflict -> %>
                                        <span class="badge badge-warning badge-xs h-auto">
                                          {gettext("CHANGED")}
                                        </span>
                                      <% _ -> %>
                                        <span class="badge badge-error badge-xs h-auto">
                                          {gettext("ERROR")}
                                        </span>
                                    <% end %>
                                  </td>
                                  <td class="font-mono text-xs">
                                    <%= if record[:is_new_record] do %>
                                      <span class="text-base-content/50">
                                        {record[:display_slug]}
                                      </span>
                                      <span class="text-success text-xs block">
                                        → {record[:generated_slug]}
                                      </span>
                                    <% else %>
                                      {record.slug}
                                      <%= if record[:generated_slug] do %>
                                        <span class="text-warning text-xs block">
                                          → {record[:generated_slug]}
                                        </span>
                                      <% end %>
                                    <% end %>
                                  </td>
                                  <td class="truncate max-w-32">{record[:title] || "-"}</td>
                                  <td class="text-right">
                                    <label class="select select-xs">
                                      <select
                                        phx-change="set_record_action"
                                        phx-value-entity={entity.name}
                                        phx-value-slug={record.slug}
                                        name="action"
                                      >
                                        <option
                                          value="skip"
                                          selected={
                                            get_record_action(
                                              @import_selections,
                                              entity.name,
                                              record.slug
                                            ) == :skip
                                          }
                                        >
                                          {gettext("Skip")}
                                        </option>
                                        <option
                                          value="overwrite"
                                          selected={
                                            get_record_action(
                                              @import_selections,
                                              entity.name,
                                              record.slug
                                            ) == :overwrite
                                          }
                                        >
                                          {gettext("Import")}
                                        </option>
                                        <option
                                          value="merge"
                                          selected={
                                            get_record_action(
                                              @import_selections,
                                              entity.name,
                                              record.slug
                                            ) == :merge
                                          }
                                        >
                                          {gettext("Merge")}
                                        </option>
                                      </select>
                                    </label>
                                  </td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        </div>
                      <% else %>
                        <div class="text-center py-4 text-base-content/50">
                          {gettext("No data records")}
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% else %>
                  <div class="text-center py-8 text-base-content/50">
                    {gettext("No entities found to import")}
                  </div>
                <% end %>
              <% else %>
                <div class="flex justify-center py-8">
                  <span class="loading loading-spinner loading-lg"></span>
                </div>
              <% end %>

              <div class="modal-action">
                <button class="btn btn-ghost" phx-click="hide_import_modal">
                  {gettext("Cancel")}
                </button>
                <button
                  class="btn btn-secondary btn-outline"
                  phx-click="do_import_entity"
                  phx-value-entity={@import_active_tab}
                  phx-disable-with={gettext("Importing…")}
                  disabled={@import_preview == nil or @import_active_tab == nil}
                >
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" />
                  {gettext("Import This Entity")}
                </button>
                <button
                  class="btn btn-primary"
                  phx-click="do_import"
                  phx-disable-with={gettext("Importing…")}
                  disabled={@import_preview == nil or length(@import_preview.entities) == 0}
                >
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" />
                  {gettext("Import All Entities")}
                </button>
              </div>
            </div>
            <div class="modal-backdrop" phx-click="hide_import_modal"></div>
          </div>
        <% end %>
      </div>
    """
  end
end
