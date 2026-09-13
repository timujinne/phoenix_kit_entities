defmodule PhoenixKitEntities.Web.DataNavigator do
  @moduledoc """
  LiveView for browsing and managing entity data records.
  Provides table view with pagination, search, filtering, and bulk operations.
  """

  use PhoenixKitWeb, :live_view
  # Override the backend `use PhoenixKitWeb, :live_view` wires by default
  # (PhoenixKitWeb.Gettext, core's own — unreachable from this package's
  # `mix gettext.extract`). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext
  on_mount(PhoenixKitEntities.Web.Hooks)

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events

  @impl true
  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    project_title = Settings.get_project_title()

    # Only the data topic here. `on_mount(PhoenixKitEntities.Web.Hooks)` above
    # already calls `subscribe_to_entities/0`, and Phoenix.PubSub registers in
    # a `keys: :duplicate` registry — so subscribing twice from the same
    # process delivers every entity event twice, and each one runs
    # `refresh_entities_and_data/1` (list + stats + filters, ~4 queries).
    if connected?(socket) do
      Events.subscribe_to_all_data()
    end

    # Set defaults only — entity list, entity resolution, and data loading
    # deferred to handle_params. Mount runs twice (HTTP + WebSocket); handle_params
    # runs once. See Phoenix iron law.
    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Data Navigator"))
      |> assign(:page_section, gettext("Entities"))
      |> assign(:page_section_path, Routes.path("/admin/entities"))
      |> assign(:project_title, project_title)
      |> assign(:entities, [])
      |> assign(:total_records, 0)
      |> assign(:published_records, 0)
      |> assign(:draft_records, 0)
      |> assign(:archived_records, 0)
      |> assign(:trashed_records, 0)
      |> assign(:selected_entity, nil)
      |> assign(:selected_entity_uuid, nil)
      |> assign(:selected_status, "all")
      |> assign(:search_term, "")
      |> assign(:view_mode, "table")
      |> assign(:entity_data_records, [])
      |> assign(:record_depths, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Load entity definitions list once per page load (see mount comment).
    socket =
      assign(socket, :entities, Entities.list_entities(lang: socket.assigns.current_locale))

    # Resolve entity from slug in params
    {entity, entity_uuid} = resolve_entity_from_params(params, socket)

    # Update stats if entity changed
    socket = maybe_update_entity_stats(socket, entity_uuid)

    # Set page title based on entity
    page_title =
      if entity,
        do: entity.display_name_plural || entity.display_name,
        else: gettext("Data Navigator")

    # Extract filter params with defaults
    status = params["status"] || "all"
    search_term = params["search"] || ""
    view_mode = params["view"] || "table"

    socket =
      socket
      |> assign(:page_title, page_title)
      |> assign(:selected_entity, entity)
      |> assign(:selected_entity_uuid, entity_uuid)
      |> assign(:selected_status, status)
      |> assign(:search_term, search_term)
      |> assign(:view_mode, view_mode)
      |> apply_filters()

    {:noreply, socket}
  end

  # Threads the current user UUID through to context functions that
  # accept `actor_uuid:` opts. Returns `[]` for logged-out / system
  # contexts so the activity row simply has `actor_uuid: nil`.
  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # Resolve entity and entity_uuid from URL params
  defp resolve_entity_from_params(params, socket) do
    case params["entity_slug"] || params["entity_id"] do
      nil ->
        {socket.assigns.selected_entity, socket.assigns.selected_entity_uuid}

      "" ->
        {nil, nil}

      slug when is_binary(slug) ->
        resolve_entity_by_slug(slug, socket.assigns[:current_locale])
    end
  end

  # Look up entity by slug/name
  defp resolve_entity_by_slug(slug, locale) do
    case Entities.get_entity_by_name(slug, lang: locale) do
      nil -> {nil, nil}
      entity -> {entity, entity.uuid}
    end
  end

  # Update entity stats if entity changed
  defp maybe_update_entity_stats(socket, new_entity_uuid) do
    if new_entity_uuid != socket.assigns.selected_entity_uuid do
      update_entity_stats(socket, new_entity_uuid)
    else
      socket
    end
  end

  # Update socket with fresh entity statistics
  defp update_entity_stats(socket, entity_uuid) do
    stats = EntityData.get_data_stats(entity_uuid)

    socket
    |> assign(:total_records, stats.total_records)
    |> assign(:published_records, stats.published_records)
    |> assign(:draft_records, stats.draft_records)
    |> assign(:archived_records, stats.archived_records)
    |> assign(:trashed_records, stats.trashed_records)
  end

  @impl true
  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_uuid,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        mode
      )

    path = build_base_path(socket.assigns.selected_entity_uuid)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> assign(:view_mode, mode)
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_entity", %{"entity_uuid" => ""}, socket) do
    # No entity selected - redirect to entities list since global data view no longer exists
    socket =
      socket
      |> put_flash(:info, gettext("Please select an entity to view its data"))
      |> redirect(to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_entity", %{"entity_uuid" => entity_uuid}, socket) do
    params =
      build_url_params(
        entity_uuid,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        socket.assigns.view_mode
      )

    path = build_base_path(entity_uuid)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_status", %{"status" => status}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_uuid,
        status,
        socket.assigns.search_term,
        socket.assigns.view_mode
      )

    path = build_base_path(socket.assigns.selected_entity_uuid)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"term" => term}}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_uuid,
        socket.assigns.selected_status,
        term,
        socket.assigns.view_mode
      )

    path = build_base_path(socket.assigns.selected_entity_uuid)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_uuid,
        "all",
        "",
        socket.assigns.view_mode
      )

    path = build_base_path(socket.assigns.selected_entity_uuid)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("archive_data", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      case EntityData.update_data(data_record, %{status: "archived"}, actor_opts(socket)) do
        {:ok, _data} ->
          socket =
            socket
            |> apply_filters()
            |> put_flash(:info, gettext("Data record archived successfully"))

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, gettext("Failed to archive data record"))
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("restore_data", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      case EntityData.update_data(data_record, %{status: "published"}, actor_opts(socket)) do
        {:ok, _data} ->
          socket =
            socket
            |> apply_filters()
            |> put_flash(:info, gettext("Data record restored successfully"))

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, gettext("Failed to restore data record"))
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("trash_data", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      case EntityData.trash(data_record, actor_opts(socket)) do
        {:ok, _data} ->
          {:noreply,
           socket
           |> refresh_data_stats()
           |> apply_filters()
           |> put_flash(:info, gettext("Record moved to trash. Restore from the trash view."))}

        {:error, :already_trashed} ->
          {:noreply, put_flash(socket, :info, gettext("Record is already in the trash"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to trash record"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("restore_from_trash", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      case EntityData.restore_from_trash(data_record, actor_opts(socket)) do
        {:ok, _data} ->
          {:noreply,
           socket
           |> refresh_data_stats()
           |> apply_filters()
           |> put_flash(:info, gettext("Record restored from trash"))}

        {:error, :not_trashed} ->
          {:noreply, put_flash(socket, :info, gettext("Record is not in the trash"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to restore record"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("permanent_delete", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      case EntityData.delete(data_record, actor_opts(socket)) do
        {:ok, _data} ->
          {:noreply,
           socket
           |> refresh_data_stats()
           |> apply_filters()
           |> put_flash(:info, gettext("Record permanently deleted"))}

        {:error, :referenced_by_external} ->
          # No `refresh_data_stats` / `apply_filters` here — nothing
          # changed in the DB. The single-select stays unchanged so
          # the user can adjust references in the parent app and retry.
          {:noreply,
           put_flash(socket, :error, PhoenixKitEntities.Errors.message(:referenced_by_external))}

        {:error, :has_children} ->
          {:noreply, put_flash(socket, :error, PhoenixKitEntities.Errors.message(:has_children))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete record"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("toggle_status", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      data_record = EntityData.get!(uuid)

      # Trashed records are excluded from the cycle — restore them
      # explicitly via the dedicated Restore button instead. The UI
      # hides the toggle button for trashed rows so this case clause
      # is unreachable in practice; the catch-all keeps the function
      # total so an out-of-band call (stale browser tab, custom client)
      # is a silent no-op rather than a `CaseClauseError`.
      new_status =
        case data_record.status do
          "draft" -> "published"
          "published" -> "archived"
          "archived" -> "draft"
          _ -> data_record.status
        end

      case EntityData.update_data(data_record, %{status: new_status}, actor_opts(socket)) do
        {:ok, _updated_data} ->
          socket =
            socket
            |> refresh_data_stats()
            |> apply_filters()
            |> put_flash(
              :info,
              gettext("Status updated to %{status}", status: status_label(new_status))
            )

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, gettext("Failed to update status"))
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("reorder_records", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    # `moved_id` rides along on the JS side — push it back as a
    # `sortable:flash` so the SortableGrid hook flashes the dropped
    # row green on success / red on failure.
    moved_id = params["moved_id"]

    cond do
      not Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not authorized"))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})}

      is_nil(socket.assigns.selected_entity) or is_nil(socket.assigns.selected_entity_uuid) ->
        {:noreply, socket}

      true ->
        apply_record_reorder(socket, ordered_ids, moved_id)
    end
  end

  # Catch-all for malformed reorder_records payloads (missing
  # ordered_ids key, wrong type). Defensive — the SortableGrid hook
  # always produces a list under the right key, but a stale browser
  # tab or a custom client could trip this. Flash + no-op rather than
  # crash the LV socket.
  def handle_event("reorder_records", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to save the new order"))}
  end

  # Bulk actions — selection lives client-side in the BulkSelectScope hook.
  # Each of these events is fired by a distinct `data-bulk-action` button and
  # carries the hook's currently-selected UUIDs (a plain list of strings, not
  # a MapSet) in the payload. None of the downstream `EntityData.bulk_*`
  # functions require Set semantics — they already normalize to a list
  # internally — so we pass `uuids` straight through.
  def handle_event("bulk_archive", %{"uuids" => uuids}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      if uuids == [] do
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}
      else
        {count, _} = EntityData.bulk_update_status(uuids, "archived", actor_opts(socket))

        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records archived", count: count))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("bulk_restore", %{"uuids" => uuids}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      if uuids == [] do
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}
      else
        {count, _} = EntityData.bulk_update_status(uuids, "published", actor_opts(socket))

        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records restored", count: count))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  # Bulk "delete" is a soft-delete (trash) — keeps rows alive so parent-app
  # FK references stay valid. Use "bulk_permanent_delete" below from the
  # Trash filter view to actually remove rows. The template still labels the
  # button "Delete"/"Trash" depending on context, so both event names route
  # to the same handler body.
  def handle_event("bulk_delete", params, socket) do
    handle_event("bulk_trash", params, socket)
  end

  def handle_event("bulk_trash", %{"uuids" => uuids}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      if uuids == [] do
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}
      else
        {count, _} = EntityData.bulk_trash(uuids, actor_opts(socket))

        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records moved to trash", count: count))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("bulk_restore_from_trash", %{"uuids" => uuids}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      if uuids == [] do
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}
      else
        {count, _} = EntityData.bulk_restore_from_trash(uuids, actor_opts(socket))

        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records restored from trash", count: count))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("bulk_permanent_delete", %{"uuids" => uuids}, socket) do
    cond do
      not Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      uuids == [] ->
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}

      true ->
        do_bulk_permanent_delete(socket, uuids)
    end
  end

  # "Change Status" is a small fixed set of options (Published / Draft /
  # Archived) rendered directly as toolbar dropdown entries rather than a
  # separate form — so unlike the modal-based capture-then-act pattern used
  # by sibling modules for open-ended status pickers, each option gets its
  # own `data-bulk-action` and reads `uuids` straight from the event payload
  # like the other direct bulk actions above. No `@bulk_uuids` capture step
  # is needed since there's no extra param to gather after the click.
  def handle_event("bulk_set_status_published", %{"uuids" => uuids}, socket) do
    bulk_change_status(socket, uuids, "published")
  end

  def handle_event("bulk_set_status_draft", %{"uuids" => uuids}, socket) do
    bulk_change_status(socket, uuids, "draft")
  end

  def handle_event("bulk_set_status_archived", %{"uuids" => uuids}, socket) do
    bulk_change_status(socket, uuids, "archived")
  end

  defp bulk_change_status(socket, uuids, status) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      if uuids == [] do
        {:noreply, put_flash(socket, :error, gettext("No records selected"))}
      else
        {count, _} = EntityData.bulk_update_status(uuids, status, actor_opts(socket))

        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records updated", count: count))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  defp do_bulk_permanent_delete(socket, uuids) do
    case EntityData.bulk_delete(uuids, actor_opts(socket)) do
      {count, _} when is_integer(count) ->
        {:noreply,
         socket
         |> refresh_data_stats()
         |> apply_filters()
         |> put_flash(:info, gettext("%{count} records permanently deleted", count: count))}

      {:error, :referenced_by_external} ->
        # No selection to reset here — selection lives client-side in the
        # BulkSelectScope hook and the bulk delete rolled back, so the
        # user's checkboxes are untouched, letting them remove the
        # FK-referenced rows from the multi-select and retry.
        {:noreply,
         put_flash(socket, :error, PhoenixKitEntities.Errors.message(:referenced_by_external))}

      {:error, :has_children} ->
        {:noreply, put_flash(socket, :error, PhoenixKitEntities.Errors.message(:has_children))}
    end
  end

  defp apply_record_reorder(socket, ordered_ids, moved_id) do
    {entity, sort_flipped?} = ensure_manual_sort(socket.assigns.selected_entity)
    entity_uuid = socket.assigns.selected_entity_uuid

    case EntityData.reorder(entity_uuid, ordered_ids, actor_opts(socket)) do
      :ok ->
        socket =
          socket
          |> assign(:selected_entity, entity)
          |> apply_filters()
          |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})

        socket =
          if sort_flipped? == :failed do
            put_flash(
              socket,
              :warning,
              gettext(
                "Positions saved, but sort mode could not be switched to manual — order may not survive a refresh."
              )
            )
          else
            socket
          end

        {:noreply, socket}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to save the new order"))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})}
    end
  end

  # First drag implicitly switches the entity to manual sort — otherwise
  # the visible order would snap back to date-created on the next refresh
  # and the user would see their drag undone. Logs a warning so admins
  # can see the silent setting flip in the application log; the flip
  # itself also lands as an `entity.updated` activity row via the
  # context's notify hook.
  defp ensure_manual_sort(entity) do
    if Entities.manual_sort?(entity) do
      {entity, :already_manual}
    else
      case Entities.update_sort_mode(entity, "manual") do
        {:ok, updated} ->
          Logger.warning(
            "DataNavigator: entity #{entity.uuid} (#{entity.name}) auto-switched sort_mode to \"manual\" on first drag"
          )

          {updated, :flipped}

        {:error, changeset} ->
          Logger.error(
            "DataNavigator: failed to auto-switch sort_mode to \"manual\" for " <>
              "entity #{entity.uuid} (#{entity.name}): #{inspect(changeset.errors)}"
          )

          {entity, :failed}
      end
    end
  end

  ## Live updates

  @impl true
  def handle_info({:entity_created, _entity_uuid}, socket) do
    {:noreply, refresh_entities_and_data(socket)}
  end

  def handle_info({:entity_updated, entity_uuid}, socket) do
    # If the currently viewed entity was updated, check if it was archived
    if socket.assigns.selected_entity_uuid && entity_uuid == socket.assigns.selected_entity_uuid do
      locale = socket.assigns[:current_locale]
      entity = Entities.get_entity!(entity_uuid, lang: locale)

      # If entity was archived or unpublished, redirect to entities list
      if entity.status != "published" do
        {:noreply,
         socket
         |> put_flash(
           :warning,
           gettext("Entity '%{name}' was %{status} in another session.",
             name: entity.display_name,
             status: entity.status
           )
         )
         |> redirect(
           to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
         )}
      else
        # Update the selected entity and page title with fresh data
        socket =
          socket
          |> assign(:selected_entity, entity)
          |> assign(:page_title, entity.display_name_plural || entity.display_name)
          |> refresh_entities_and_data()

        {:noreply, socket}
      end
    else
      {:noreply, refresh_entities_and_data(socket)}
    end
  end

  def handle_info({:entity_deleted, entity_uuid}, socket) do
    # If the currently viewed entity was deleted, redirect to entities list
    if socket.assigns.selected_entity_uuid && entity_uuid == socket.assigns.selected_entity_uuid do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Entity was deleted in another session."))
       |> redirect(to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base))}
    else
      {:noreply, refresh_entities_and_data(socket)}
    end
  end

  def handle_info({event, _entity_uuid, _data_uuid}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    socket =
      socket
      |> refresh_data_stats()
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_info({:data_reordered, _entity_uuid}, socket) do
    {:noreply, apply_filters(socket)}
  end

  # Catch-all — log at :debug rather than crashing the socket so unexpected
  # messages stay visible during development without producing noise in prod.
  def handle_info(message, socket) do
    Logger.debug(fn ->
      "DataNavigator: unhandled handle_info — #{inspect(message)}"
    end)

    {:noreply, socket}
  end

  # Helper Functions

  defp build_base_path(nil), do: "/admin/entities"

  defp build_base_path(entity_uuid) when is_binary(entity_uuid) do
    case Entities.get_entity(entity_uuid) do
      nil -> "/admin/entities"
      entity -> "/admin/entities/#{entity.name}/data"
    end
  end

  defp build_url_params(_entity_uuid, status, search_term, view_mode) do
    params = []

    # Don't include entity_uuid in query params since it's in the path

    params =
      if status && status != "all" do
        [{"status", status} | params]
      else
        params
      end

    params =
      if search_term && String.trim(search_term) != "" do
        [{"search", search_term} | params]
      else
        params
      end

    params =
      if view_mode && view_mode != "table" do
        [{"view", view_mode} | params]
      else
        params
      end

    URI.encode_query(params)
  end

  defp apply_filters(socket) do
    entity = socket.assigns[:selected_entity]
    entity_uuid = socket.assigns[:selected_entity_uuid]
    status = socket.assigns[:selected_status] || "all"
    search_term = socket.assigns[:search_term] || ""

    # Pass sort_mode from the already-loaded entity to avoid redundant DB lookups
    sort_opts =
      if entity,
        do: [sort_mode: Entities.get_sort_mode(entity), lang: socket.assigns[:current_locale]],
        else: [lang: socket.assigns[:current_locale]]

    raw_records =
      fetch_records(entity_uuid, status, sort_opts)
      |> filter_by_search(search_term)

    {records, depths} = maybe_tree_order(raw_records, entity_uuid, status, search_term)

    socket
    |> assign(:entity_data_records, records)
    |> assign(:record_depths, depths)
  end

  # Tree-order rows only when the view is showing a coherent slice of
  # one entity. A status filter or a search term carves the set in
  # half, leaving parents pointing at rows that aren't in the result —
  # in that case fall back to flat sibling order and zero depths so
  # the template renders without indentation.
  defp maybe_tree_order(records, entity_uuid, "all", "")
       when is_binary(entity_uuid) and records != [] do
    flat = EntityData.tree_from_rows(records)
    depths = Map.new(flat, fn %{record: r, depth: d} -> {r.uuid, d} end)
    {Enum.map(flat, & &1.record), depths}
  end

  defp maybe_tree_order(records, _entity_uuid, _status, _search) do
    {records, %{}}
  end

  # When an entity is selected, use sort-mode-aware queries
  defp fetch_records(nil, "all", _opts), do: EntityData.list_all_data()
  defp fetch_records(nil, "trashed", _opts), do: EntityData.list_data_by_status("trashed")
  defp fetch_records(nil, status, _opts), do: EntityData.list_data_by_status(status)

  defp fetch_records(entity_uuid, "all", opts),
    do: EntityData.list_by_entity(entity_uuid, opts)

  defp fetch_records(entity_uuid, "trashed", opts),
    do: EntityData.list_trashed_by_entity(entity_uuid, opts)

  defp fetch_records(entity_uuid, status, opts),
    do: EntityData.list_by_entity_and_status(entity_uuid, status, opts)

  defp filter_by_search(records, ""), do: records

  defp filter_by_search(records, search_term) do
    search_term_lower = String.downcase(String.trim(search_term))

    Enum.filter(records, fn record ->
      title_match = String.contains?(String.downcase(record.title || ""), search_term_lower)
      slug_match = String.contains?(String.downcase(record.slug || ""), search_term_lower)

      title_match || slug_match
    end)
  end

  defp refresh_data_stats(socket) do
    stats = EntityData.get_data_stats(socket.assigns.selected_entity_uuid)

    socket
    |> assign(:total_records, stats.total_records)
    |> assign(:published_records, stats.published_records)
    |> assign(:draft_records, stats.draft_records)
    |> assign(:archived_records, stats.archived_records)
    |> assign(:trashed_records, stats.trashed_records)
  end

  defp refresh_entities_and_data(socket) do
    locale = socket.assigns[:current_locale]

    socket
    |> assign(:entities, Entities.list_entities(lang: locale))
    |> refresh_data_stats()
    |> apply_filters()
  end

  def status_badge_class(status) do
    case status do
      "published" -> "badge-success"
      "draft" -> "badge-warning"
      "archived" -> "badge-neutral"
      "trashed" -> "badge-error"
      _ -> "badge-outline"
    end
  end

  def status_label(status) do
    case status do
      "published" -> gettext("Published")
      "draft" -> gettext("Draft")
      "archived" -> gettext("Archived")
      "trashed" -> gettext("Trashed")
      _ -> gettext("Unknown")
    end
  end

  def status_icon(status) do
    case status do
      "published" -> "hero-check-circle"
      "draft" -> "hero-pencil"
      "archived" -> "hero-archive-box"
      "trashed" -> "hero-trash"
      _ -> "hero-question-mark-circle"
    end
  end

  def get_entity_name(entities, entity_uuid) do
    case Enum.find(entities, &(&1.uuid == entity_uuid)) do
      nil -> gettext("Unknown")
      entity -> entity.display_name
    end
  end

  def get_entity_slug(entities, entity_uuid) do
    case Enum.find(entities, &(&1.uuid == entity_uuid)) do
      nil -> ""
      entity -> entity.name
    end
  end

  def truncate_text(text, length \\ 100)

  def truncate_text(text, length) when is_binary(text) do
    if String.length(text) > length do
      String.slice(text, 0, length) <> "..."
    else
      text
    end
  end

  def truncate_text(_, _), do: ""

  def format_data_preview(data) when is_map(data) do
    # For multilang data, show primary language fields
    display_data =
      if Multilang.multilang_data?(data) do
        Multilang.flatten_to_primary(data)
      else
        data
      end

    display_data
    |> Enum.take(3)
    |> Enum.map_join(" • ", fn {key, value} ->
      "#{key}: #{truncate_text(to_string(value), 30)}"
    end)
  end

  def format_data_preview(_), do: ""

  # Nothing to filter on a brand-new entity: no records, no trash, no
  # query, default status. The page is then just its title, Add, and the
  # empty state — the case that used to render four giant zeros.
  defp show_filters?(assigns) do
    assigns.total_records > 0 or assigns.trashed_records > 0 or
      assigns.search_term != "" or assigns.selected_status != "all"
  end

  attr(:status, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:selected, :string, required: true)

  # One status, its count, and the filtering it always should have done.
  defp status_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter_by_status"
      phx-value-status={@status}
      aria-pressed={to_string(@selected == @status)}
      class={["btn btn-sm gap-2", if(@selected == @status, do: "btn-primary", else: "btn-ghost")]}
    >
      {@label}
      <span class={[
        "badge badge-sm",
        if(@selected == @status, do: "badge-neutral", else: "badge-ghost")
      ]}>
        {@count}
      </span>
    </button>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <%!-- One row: back arrow left, actions right. The page title and
             the "Browse and manage your …" line are gone — the admin
             header above already names the entity, and repeating it cost
             a whole band above the fold (Max, 2026-08-28). --%>
        <%!-- back_label names the destination: an unlabeled arrow makes the
             reader guess, and this page is going in front of clients. The
             control's shape and size are core's job again as of the
             2026-08-28 header change. --%>
        <%!-- No back chip: the breadcrumb bar's "Entities" section crumb is
        the way back, as on every other page of this module. --%>
        <.admin_page_header>
          <:actions>
          <%!-- View Mode Toggle --%>
          <div class="join">
            <button
              type="button"
              phx-click="toggle_view_mode"
              phx-value-mode="card"
              class={["btn join-item", @view_mode == "card" && "btn-active"]}
              title={gettext("Card view")}
            >
              <.icon name="hero-squares-2x2" class="w-4 h-4" />
            </button>
            <button
              type="button"
              phx-click="toggle_view_mode"
              phx-value-mode="table"
              class={["btn join-item", @view_mode == "table" && "btn-active"]}
              title={gettext("Table view")}
            >
              <.icon name="hero-bars-3-bottom-left" class="w-4 h-4" />
            </button>
          </div>

          <%= if @selected_entity do %>
            <.link
              navigate={
                PhoenixKit.Utils.Routes.path("/admin/entities/#{@selected_entity.uuid}/edit")
              }
              class="btn btn-outline"
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" /> {gettext("Edit Entity")}
            </.link>
          <% end %>
          <%= if not Enum.empty?(@entities) do %>
            <%= if @selected_entity do %>
              <%!-- Direct add button when viewing specific entity --%>
              <.link
                navigate={
                  PhoenixKit.Utils.Routes.path("/admin/entities/#{@selected_entity.name}/data/new")
                }
                class="btn btn-primary"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Add")}
              </.link>
            <% else %>
              <%!-- Dropdown to select entity when viewing all data --%>
              <div class="dropdown dropdown-end">
                <label tabindex="0" class="btn btn-primary">
                  <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Add")}
                  <.icon name="hero-chevron-down" class="w-4 h-4 ml-2" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-64 mt-2"
                >
                  <li class="menu-title">
                    <span>{gettext("Select Entity Type")}</span>
                  </li>
                  <%= for entity <- @entities do %>
                    <%= if entity.status == "published" do %>
                      <li>
                        <.link
                          navigate={
                            PhoenixKit.Utils.Routes.path("/admin/entities/#{entity.name}/data/new")
                          }
                          class="flex items-center justify-between"
                        >
                          <span>{entity.display_name}</span>
                          <span class="badge badge-sm badge-ghost">{entity.name}</span>
                        </.link>
                      </li>
                    <% end %>
                  <% end %>
                  <%= if Enum.all?(@entities, & &1.status != "published") do %>
                    <li class="disabled">
                      <span class="text-sm text-base-content/50">
                        {gettext("No published entities available. Publish an entity first.")}
                      </span>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          <% end %>
          </:actions>
        </.admin_page_header>

        <%!-- Filters. The counts used to be four 130px dashboard cards
             above the fold restating this very control (Max/boss,
             2026-08-28: clients see this page too). They are now ON the
             filter: same numbers, one row, and clicking actually
             filters. Statuses that are empty stay out of the way unless
             they are the current view — a brand-new entity showed four
             giant zeros. --%>
        <div :if={show_filters?(assigns)} class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <.status_chip
                status="all"
                label={gettext("All")}
                count={@total_records}
                selected={@selected_status}
              />
              <.status_chip
                status="published"
                label={gettext("Published")}
                count={@published_records}
                selected={@selected_status}
              />
              <.status_chip
                :if={@draft_records > 0 or @selected_status == "draft"}
                status="draft"
                label={gettext("Drafts")}
                count={@draft_records}
                selected={@selected_status}
              />
              <.status_chip
                :if={@archived_records > 0 or @selected_status == "archived"}
                status="archived"
                label={gettext("Archived")}
                count={@archived_records}
                selected={@selected_status}
              />
              <.status_chip
                :if={@trashed_records > 0 or @selected_status == "trashed"}
                status="trashed"
                label={gettext("Trash")}
                count={@trashed_records}
                selected={@selected_status}
              />
            </div>

            <.form
              for={%{}}
              id="data-navigator-search"
              phx-change="search"
              phx-submit="search"
              class="join w-full"
            >
              <input
                type="text"
                name="search[term]"
                value={@search_term}
                placeholder={gettext("Search by title or slug...")}
                phx-debounce="250"
                autocomplete="off"
                class="input join-item flex-1"
              />
              <button type="submit" class="btn btn-primary join-item">
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
            </.form>

            <%!-- Clear Filters --%>
            <%= if @selected_status != "all" || @search_term != "" do %>
              <div class="flex justify-end mt-4">
                <button phx-click="clear_filters" class="btn btn-outline btn-sm">
                  <.icon name="hero-x-mark" class="w-4 h-4 mr-2" /> {gettext("Clear All Filters")}
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Bulk-select scope: selection lives client-side (BulkSelectScope
             hook) from here through the end of the Results Section below —
             the toolbar buttons, the header "select all" checkbox, and every
             row checkbox (table AND card view) all participate in the same
             selection set. The server only learns the selected UUIDs at the
             moment a toolbar button is clicked. --%>
        <.bulk_select_scope id="entity-data-bulk" total_count={length(@entity_data_records)}>
          <%!-- Bulk Actions Bar — always rendered; hidden via inline style +
               data-bulk-show until the hook detects a non-empty selection. --%>
          <div class="card bg-base-200 shadow-xl mb-6" data-bulk-show="has-selection" style="display: none;">
            <div class="card-body p-4">
              <div class="flex flex-wrap gap-3 items-center">
                <span
                  class="text-sm font-semibold"
                  data-bulk-text-template={gettext("%{count} selected", count: "%{count}")}
                >
                </span>
                <div class="divider divider-horizontal mx-0"></div>
                <%!-- Quick Actions --%>
                <%= if @selected_status == "trashed" do %>
                  <%!-- Trash-bin actions: restore or permanently delete --%>
                  <button
                    type="button"
                    data-bulk-action="bulk_restore_from_trash"
                    phx-disable-with={gettext("…")}
                    class="btn btn-success btn-sm"
                  >
                    <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
                  </button>
                  <button
                    type="button"
                    data-bulk-action="bulk_permanent_delete"
                    phx-disable-with={gettext("…")}
                    class="btn btn-error btn-sm"
                    data-confirm={
                      gettext(
                        "Permanently delete the selected records? This cannot be undone, and will fail if any are still referenced by other tables."
                      )
                    }
                  >
                    <.icon name="hero-x-circle" class="w-4 h-4" />
                    {gettext("Delete forever")}
                  </button>
                <% else %>
                  <button
                    type="button"
                    data-bulk-action="bulk_archive"
                    phx-disable-with={gettext("…")}
                    class="btn btn-warning btn-sm"
                  >
                    <.icon name="hero-archive-box" class="w-4 h-4" /> {gettext("Archive")}
                  </button>
                  <button
                    type="button"
                    data-bulk-action="bulk_restore"
                    phx-disable-with={gettext("…")}
                    class="btn btn-success btn-sm"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Restore")}
                  </button>
                  <button
                    type="button"
                    data-bulk-action="bulk_trash"
                    phx-disable-with={gettext("…")}
                    class="btn btn-error btn-sm"
                    data-confirm={
                      gettext(
                        "Move the selected records to the trash? Restore from the Trash filter if needed."
                      )
                    }
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Trash")}
                  </button>
                <% end %>

                <div class="divider divider-horizontal mx-0"></div>

                <%!-- Change Status Dropdown — a small fixed set of options, so
                     each one is its own data-bulk-action (no capture-then-act
                     modal needed; there's no extra param to gather beyond the
                     click itself). --%>
                <div class="dropdown">
                  <label tabindex="0" class="btn btn-ghost btn-sm">
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" />
                    {gettext("Change Status")}
                    <.icon name="hero-chevron-down" class="w-4 h-4" />
                  </label>
                  <ul
                    tabindex="0"
                    class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-52"
                  >
                    <li>
                      <a data-bulk-action="bulk_set_status_published" phx-disable-with={gettext("…")}>
                        {gettext("Published")}
                      </a>
                    </li>
                    <li>
                      <a data-bulk-action="bulk_set_status_draft" phx-disable-with={gettext("…")}>
                        {gettext("Draft")}
                      </a>
                    </li>
                    <li>
                      <a data-bulk-action="bulk_set_status_archived" phx-disable-with={gettext("…")}>
                        {gettext("Archived")}
                      </a>
                    </li>
                  </ul>
                </div>
                <div class="flex-1"></div>
                <button type="button" data-bulk-clear="true" class="btn btn-ghost btn-sm">
                  <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear")}
                </button>
              </div>
            </div>
          </div>

        <%!-- Results Section --%>
        <%= if Enum.empty?(@entity_data_records) do %>
          <%!-- Empty State --%>
          <div class="card bg-base-100 shadow-xl border-2 border-dashed border-base-300">
            <div class="card-body text-center py-12">
              <div class="text-6xl mb-4 opacity-50">📄</div>
              <%= if Enum.empty?(@entities) do %>
                <%!-- No entities exist --%>
                <h3 class="text-2xl font-semibold text-base-content/60 mb-4">
                  {gettext("No Entities Created Yet")}
                </h3>
                <p class="text-base-content/50 mb-6 max-w-md mx-auto">
                  {gettext("Create your first entity to start managing data records.")}
                </p>
                <.link
                  navigate={PhoenixKit.Utils.Routes.path("/admin/entities")}
                  class="btn btn-primary btn-lg"
                >
                  <.icon name="hero-plus" class="w-5 h-5 mr-2" /> {gettext("Create Your First Entity")}
                </.link>
              <% else %>
                <%= if @total_records == 0 do %>
                  <%!-- Entities exist but no data records at all --%>
                  <h3 class="text-2xl font-semibold text-base-content/60 mb-4">
                    {gettext("No Data Records Yet")}
                  </h3>
                  <p class="text-base-content/50 mb-6 max-w-md mx-auto">
                    {gettext("Get started by adding your first data record.")}
                  </p>
                  <%= if @selected_entity do %>
                    <%!-- Direct add button when viewing specific entity --%>
                    <.link
                      navigate={
                        PhoenixKit.Utils.Routes.path(
                          "/admin/entities/#{@selected_entity.name}/data/new"
                        )
                      }
                      class="btn btn-primary btn-lg"
                    >
                      <.icon name="hero-plus" class="w-5 h-5 mr-2" /> {gettext("Add")}
                    </.link>
                  <% else %>
                    <%!-- Dropdown to select entity when viewing all data --%>
                    <div class="dropdown dropdown-top dropdown-center">
                      <label tabindex="0" class="btn btn-primary btn-lg">
                        <.icon name="hero-plus" class="w-5 h-5 mr-2" /> {gettext("Add")}
                        <.icon name="hero-chevron-down" class="w-5 h-5 ml-2" />
                      </label>
                      <ul
                        tabindex="0"
                        class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-72 mb-2 left-1/2 -translate-x-1/2"
                      >
                        <li class="menu-title">
                          <span>{gettext("Select Entity Type")}</span>
                        </li>
                        <%= for entity <- @entities do %>
                          <%= if entity.status == "published" do %>
                            <li>
                              <.link
                                navigate={
                                  PhoenixKit.Utils.Routes.path(
                                    "/admin/entities/#{entity.name}/data/new"
                                  )
                                }
                                class="flex items-center justify-between"
                              >
                                <span>{entity.display_name}</span>
                                <span class="badge badge-sm badge-ghost">{entity.name}</span>
                              </.link>
                            </li>
                          <% end %>
                        <% end %>
                        <%= if Enum.all?(@entities, & &1.status != "published") do %>
                          <li class="disabled">
                            <span class="text-sm text-base-content/50 p-4">
                              {gettext(
                                "No published entities available. Publish an entity first to create data."
                              )}
                            </span>
                          </li>
                        <% end %>
                      </ul>
                    </div>
                  <% end %>
                <% else %>
                  <%= if @selected_entity_uuid || @selected_status != "all" || @search_term != "" do %>
                    <%!-- Data exists but filters exclude everything --%>
                    <h3 class="text-2xl font-semibold text-base-content/60 mb-4">
                      {gettext("No Data Records Found")}
                    </h3>
                    <p class="text-base-content/50 mb-6 max-w-md mx-auto">
                      {gettext(
                        "No data records match your current filters. Try adjusting your search criteria or clearing the filters."
                      )}
                    </p>
                    <button phx-click="clear_filters" class="btn btn-outline btn-lg">
                      <.icon name="hero-x-mark" class="w-5 h-5 mr-2" /> {gettext("Clear Filters")}
                    </button>
                  <% end %>
                <% end %>
              <% end %>
            </div>
          </div>
        <% else %>
          <%!-- Data Records View --%>
          <%= if @view_mode == "table" do %>
            <%!-- Table View --%>
            <.table_default variant="zebra" size="sm">
              <.table_default_header>
                <.table_default_row>
                  <.table_default_header_cell
                    :if={@selected_entity && length(@entity_data_records) > 1}
                    class="w-8"
                  ></.table_default_header_cell>
                  <.bulk_select_header_cell
                    id="entity-data-select-all"
                    class="w-12"
                    aria_label={gettext("Select all")}
                  />
                  <.table_default_header_cell>{gettext("Title")}</.table_default_header_cell>
                  <%= if !@selected_entity do %>
                    <.table_default_header_cell>{gettext("Entity")}</.table_default_header_cell>
                  <% end %>
                  <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Created")}</.table_default_header_cell>
                  <.table_default_header_cell class="w-px whitespace-nowrap text-right">
                    {gettext("Actions")}
                  </.table_default_header_cell>
                </.table_default_row>
              </.table_default_header>
              <tbody
                id={if @selected_entity, do: "data-records-tbody"}
                data-sortable="true"
                data-sortable-event="reorder_records"
                data-sortable-items=".sortable-item"
                data-sortable-hide-source="false"
                data-sortable-handle=".pk-drag-handle"
                phx-hook={if @selected_entity, do: "SortableGrid"}
              >
                <%= for data_record <- @entity_data_records do %>
                  <.table_default_row
                    class={if @selected_entity, do: "sortable-item"}
                    data-id={data_record.uuid}
                  >
                    <.table_default_cell
                      :if={@selected_entity && length(@entity_data_records) > 1}
                      class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/70 transition-colors"
                      title={gettext("Drag to reorder")}
                    >
                      <.icon name="hero-bars-3" class="w-4 h-4" />
                    </.table_default_cell>
                    <.bulk_select_cell value={data_record.uuid} class="w-12" />
                    <.table_default_cell>
                      <.link
                        navigate={
                          PhoenixKit.Utils.Routes.path(
                            "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}"
                          )
                        }
                        class="block hover:text-primary transition-colors cursor-pointer"
                      >
                        <div class="font-bold">
                          <%= if (depth = Map.get(@record_depths, data_record.uuid, 0)) > 0 do %>
                            <span class="opacity-60 mr-1">{String.duplicate("— ", depth)}</span>
                          <% end %>
                          {data_record.title}
                        </div>
                        <%= if data_record.slug do %>
                          <div class="text-sm opacity-50">
                            <.icon name="hero-link" class="w-3 h-3 inline" />
                            {data_record.slug}
                          </div>
                        <% end %>
                      </.link>
                    </.table_default_cell>
                    <%= if !@selected_entity do %>
                      <.table_default_cell>
                        <span class="badge badge-outline badge-sm h-auto">
                          {get_entity_name(@entities, data_record.entity_uuid)}
                        </span>
                      </.table_default_cell>
                    <% end %>
                    <.table_default_cell>
                      <span class={"badge #{status_badge_class(data_record.status)} badge-sm"}>
                        <.icon name={status_icon(data_record.status)} class="w-3 h-3 mr-1" />
                        {status_label(data_record.status)}
                      </span>
                    </.table_default_cell>
                    <.table_default_cell>
                      <div class="text-sm">
                        {PhoenixKit.Utils.Date.format_date_with_user_format(data_record.date_created)}
                      </div>
                      <%= if data_record.creator do %>
                        <div class="text-xs opacity-50">
                          {data_record.creator.email}
                        </div>
                      <% end %>
                    </.table_default_cell>
                    <.table_default_cell class="text-right whitespace-nowrap">
                      <.table_row_menu mode="auto" id={"data-menu-#{data_record.uuid}"}>
                        <.table_row_menu_link
                          navigate={
                            PhoenixKit.Utils.Routes.path(
                              "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}"
                            )
                          }
                          icon="hero-eye"
                          label={gettext("View")}
                        />
                        <.table_row_menu_link
                          navigate={
                            PhoenixKit.Utils.Routes.path(
                              "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}/edit"
                            )
                          }
                          icon="hero-pencil"
                          label={gettext("Edit")}
                        />
                        <.table_row_menu_divider />
                        <%= cond do %>
                          <% data_record.status == "trashed" -> %>
                            <.table_row_menu_button
                              phx-click="restore_from_trash"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-arrow-uturn-left"
                              label={gettext("Restore from trash")}
                            />
                            <.table_row_menu_button
                              phx-click="permanent_delete"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              data-confirm={
                                gettext(
                                  "Permanently delete this record? This cannot be undone, and will fail if it's still referenced by other tables."
                                )
                              }
                              icon="hero-x-circle"
                              label={gettext("Delete forever")}
                            />
                          <% data_record.status == "archived" -> %>
                            <.table_row_menu_button
                              phx-click="restore_data"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-arrow-path"
                              label={gettext("Restore")}
                            />
                            <.table_row_menu_button
                              phx-click="trash_data"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-trash"
                              label={gettext("Move to trash")}
                            />
                          <% true -> %>
                            <.table_row_menu_button
                              phx-click="archive_data"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-archive-box"
                              label={gettext("Archive")}
                            />
                            <.table_row_menu_button
                              phx-click="trash_data"
                              phx-value-uuid={data_record.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-trash"
                              label={gettext("Move to trash")}
                            />
                        <% end %>
                      </.table_row_menu>
                    </.table_default_cell>
                  </.table_default_row>
                <% end %>
              </tbody>
            </.table_default>
          <% else %>
            <%!-- Card View — single .draggable_list; DnD disabled when no entity is selected --%>
            <.draggable_list
              id="data-records-cards"
              items={@entity_data_records}
              item_id={&(&1.uuid)}
              on_reorder="reorder_records"
              draggable={not is_nil(@selected_entity) and length(@entity_data_records) > 1}
              sortable_handle=".pk-drag-handle"
              layout={:list}
              gap="gap-6"
            >
              <:item :let={data_record}>
                <div class="card bg-base-100 shadow-xl hover:shadow-2xl transition-shadow group/card">
                <div class="card-body">
                  <div class="flex items-start gap-3 mb-4">
                    <div
                      :if={@selected_entity && length(@entity_data_records) > 1}
                      class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/0 group-hover/card:text-base-content/50 transition-colors mt-1"
                      title={gettext("Drag to reorder")}
                    >
                      <.icon name="hero-bars-3" class="w-5 h-5" />
                    </div>
                    <%!-- Card view isn't a table, so this can't use
                         <.bulk_select_cell> (it wraps a <td>) — same
                         data-bulk-role/data-uuid contract, bare input. --%>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-md mt-1"
                      data-bulk-role="row"
                      data-uuid={data_record.uuid}
                    />
                    <div class="flex-1">
                      <div class="flex items-start justify-between mb-2">
                        <.link
                          navigate={
                            PhoenixKit.Utils.Routes.path(
                              "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}"
                            )
                          }
                          class="flex-1 hover:text-primary transition-colors cursor-pointer"
                        >
                          <%!-- Title and Entity Info --%>
                          <div class="flex items-center mb-2">
                            <h3 class="card-title text-lg mr-3">{data_record.title}</h3>
                            <%= if !@selected_entity do %>
                              <span class="badge badge-outline">
                                {get_entity_name(@entities, data_record.entity_uuid)}
                              </span>
                            <% end %>
                          </div>

                          <%!-- Slug --%>
                          <%= if data_record.slug do %>
                            <p class="text-sm text-base-content/60 mb-2">
                              <.icon name="hero-link" class="w-4 h-4 inline mr-1" />
                              {data_record.slug}
                            </p>
                          <% end %>

                          <%!-- Data Preview --%>
                          <%= if data_record.data && map_size(data_record.data) > 0 do %>
                            <p class="text-sm text-base-content/70 mb-3">
                              {format_data_preview(data_record.data)}
                            </p>
                          <% end %>
                        </.link>

                        <%!-- Status Badge --%>
                        <div class="flex flex-col items-end">
                          <span class={"badge #{status_badge_class(data_record.status)} mb-2"}>
                            <.icon name={status_icon(data_record.status)} class="w-3 h-3 mr-1" />
                            {status_label(data_record.status)}
                          </span>

                          <%!-- Status Toggle Button --%>
                          <button
                            class="btn btn-ghost btn-xs"
                            phx-click="toggle_status"
                            phx-value-uuid={data_record.uuid}
                            title={gettext("Cycle status")}
                          >
                            <.icon name="hero-arrow-path" class="w-3 h-3" />
                          </button>
                        </div>
                      </div>

                      <%!-- Metadata Row --%>
                      <div class="flex flex-wrap items-center gap-4 text-xs text-base-content/50 mb-4">
                        <%= if data_record.creator do %>
                          <span>
                            <.icon name="hero-user" class="w-3 h-3 inline mr-1" />
                            {data_record.creator.email}
                          </span>
                        <% end %>
                        <span>
                          <.icon name="hero-calendar" class="w-3 h-3 inline mr-1" />
                          {gettext("Created %{date}",
                            date:
                              PhoenixKit.Utils.Date.format_date_with_user_format(
                                data_record.date_created
                              )
                          )}
                        </span>
                        <%= if data_record.date_updated != data_record.date_created do %>
                          <span>
                            <.icon name="hero-clock" class="w-3 h-3 inline mr-1" />
                            {gettext("Updated %{date}",
                              date:
                                PhoenixKit.Utils.Date.format_date_with_user_format(
                                  data_record.date_updated
                                )
                            )}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%!-- Actions --%>
                  <div class="card-actions justify-end">
                    <.table_row_menu mode="auto" id={"data-card-menu-#{data_record.uuid}"}>
                      <.table_row_menu_link
                        navigate={
                          PhoenixKit.Utils.Routes.path(
                            "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}"
                          )
                        }
                        icon="hero-eye"
                        label={gettext("View")}
                      />
                      <.table_row_menu_link
                        navigate={
                          PhoenixKit.Utils.Routes.path(
                            "/admin/entities/#{get_entity_slug(@entities, data_record.entity_uuid)}/data/#{data_record.uuid}/edit"
                          )
                        }
                        icon="hero-pencil"
                        label={gettext("Edit")}
                      />
                      <.table_row_menu_divider />
                      <%= cond do %>
                        <% data_record.status == "trashed" -> %>
                          <.table_row_menu_button
                            phx-click="restore_from_trash"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-arrow-uturn-left"
                            label={gettext("Restore from trash")}
                          />
                          <.table_row_menu_button
                            phx-click="permanent_delete"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            data-confirm={
                              gettext(
                                "Permanently delete this record? This cannot be undone, and will fail if it's still referenced by other tables."
                              )
                            }
                            icon="hero-x-circle"
                            label={gettext("Delete forever")}
                          />
                        <% data_record.status == "archived" -> %>
                          <.table_row_menu_button
                            phx-click="restore_data"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-arrow-path"
                            label={gettext("Restore")}
                          />
                          <.table_row_menu_button
                            phx-click="trash_data"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-trash"
                            label={gettext("Move to trash")}
                          />
                        <% true -> %>
                          <.table_row_menu_button
                            phx-click="archive_data"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-archive-box"
                            label={gettext("Archive")}
                          />
                          <.table_row_menu_button
                            phx-click="trash_data"
                            phx-value-uuid={data_record.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-trash"
                            label={gettext("Move to trash")}
                          />
                      <% end %>
                    </.table_row_menu>
                  </div>
                </div>
              </div>
            </:item>
          </.draggable_list>
          <% end %>
        <% end %>
        </.bulk_select_scope>
      </div>
    """
  end
end
