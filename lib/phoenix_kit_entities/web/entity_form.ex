defmodule PhoenixKitEntities.Web.EntityForm do
  @moduledoc """
  LiveView for creating and editing entity schemas.
  Provides form interface for defining entity fields, types, and validation rules.
  """

  # Defensive catch-all clauses for parse_int/2 and parse_accept_list/1 are
  # unreachable given current call sites but kept for safety.
  @dialyzer {:nowarn_function, parse_int: 2}
  @dialyzer {:nowarn_function, parse_accept_list: 1}

  use PhoenixKitWeb, :live_view
  # Override the backend `use PhoenixKitWeb, :live_view` wires by default
  # (PhoenixKitWeb.Gettext, core's own — unreachable from this package's
  # `mix gettext.extract`). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext
  on_mount(PhoenixKitEntities.Web.Hooks)

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.HeroIcons
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.Mirror.Exporter
  alias PhoenixKitEntities.Mirror.Storage
  alias PhoenixKitEntities.Presence
  alias PhoenixKitEntities.PresenceHelpers

  @impl true
  def mount(_params, _session, socket) do
    # Defer DB query to handle_params/3 — mount runs twice (HTTP + WebSocket),
    # handle_params runs once. See Phoenix iron law.
    # Capture the page the user came from (WS connect only) so the
    # "and Return" button can route back there. Validated as an
    # internal admin path; falls back to the entities list otherwise.
    return_to =
      if connected?(socket) do
        socket |> get_connect_params() |> referer_to_return_path()
      end

    {:ok, assign(socket, :return_to_path, return_to)}
  end

  @impl true
  def handle_params(%{"id" => id} = _params, uri, socket) do
    # Edit mode
    entity = Entities.get_entity!(id)
    changeset = Entities.change_entity(entity)

    socket =
      socket
      |> drop_self_referer(uri)
      |> hydrate_entity_form(entity, changeset, gettext("Edit Entity"))

    {:noreply, socket}
  end

  def handle_params(_params, uri, socket) do
    # Create mode
    entity = %Entities{}
    changeset = Entities.change_entity(entity)

    socket =
      socket
      |> drop_self_referer(uri)
      |> hydrate_entity_form(entity, changeset, gettext("New Entity"))

    {:noreply, socket}
  end

  # Pull `_live_referer` out of the connect params, parse the path, and
  # return it only if it looks like an internal admin path. External or
  # malformed referrers fall back to nil so the save handler routes to
  # the entities list. Defensive — never trust a redirect target that
  # rides in on a client-supplied param.
  defp referer_to_return_path(%{"_live_referer" => referer}) when is_binary(referer) do
    case URI.parse(referer) do
      %URI{path: path} when is_binary(path) ->
        if internal_admin_path?(path), do: path, else: nil

      _ ->
        nil
    end
  end

  defp referer_to_return_path(_), do: nil

  # We don't trust arbitrary site paths as a redirect target — only PhoenixKit's
  # admin area. Two questions, and neither implies the other, so a
  # client-supplied path needs both:
  #
  #   * `local_path?/1` — does it point off-site at all? Rejects `//evil.com`,
  #     `/\evil.com`, and ASCII control characters (browsers strip tab/CR/LF,
  #     so `"/\t/evil.com"` lands as `//evil.com`).
  #   * `admin_area_path?/1` — does it land in the admin area? Strips the mount
  #     prefix, allows a locale segment, and compares by SEGMENT.
  #
  # This was hand-rolled as `String.contains?(path, "/admin/")`, which was wrong
  # three ways: it claimed `/administrators`, it claimed a host's own page at
  # `/shop/admin`, and it matched nothing at all once a host renamed the admin
  # area with `config :phoenix_kit, admin_path:` — silently dropping the "and
  # Return" destination it exists to preserve. Core exposed
  # `admin_area_path?/1` in 2.14.0 for exactly this; don't re-roll it.
  defp internal_admin_path?(path) do
    Routes.local_path?(path) and admin_area_path?(path)
  end

  # `Routes.admin_area_path?/1` is public from core 2.14.1. The `:phoenix_kit`
  # requirement stays a two-segment `~> 2.0` on purpose — narrowing it to a
  # single core minor breaks `mix deps.get` for every host running this module
  # alongside a different one, with no degraded mode (see
  # `test/core_pin_conformance_test.exs`). So the newer API is used when it is
  # there and the previous check stands in when it is not, rather than being
  # pinned into existence.
  #
  # `Code.ensure_loaded?/1` alongside `function_exported?/3` because the latter
  # answers false for a module that simply has not been loaded yet, which under
  # a release is the normal state.
  defp admin_area_path?(path) do
    if Code.ensure_loaded?(Routes) and function_exported?(Routes, :admin_area_path?, 1) do
      Routes.admin_area_path?(path)
    else
      String.contains?(path, "/admin/")
    end
  end

  # If the referrer is the same page we're rendering (e.g. user reloaded
  # the edit page), drop it so "and Return" doesn't no-op back to here.
  defp drop_self_referer(socket, uri) do
    case socket.assigns[:return_to_path] do
      nil ->
        socket

      path ->
        current_path = URI.parse(uri).path

        if current_path &&
             String.trim_trailing(current_path, "/") ==
               String.trim_trailing(path, "/") do
          assign(socket, :return_to_path, nil)
        else
          socket
        end
    end
  end

  defp hydrate_entity_form(socket, entity, _changeset, page_title) do
    project_title = Settings.get_project_title()
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get current fields or initialize empty
    current_fields = entity.fields_definition || []

    # Initialize settings if nil
    entity = Map.update!(entity, :settings, fn settings -> settings || %{} end)

    # Regenerate changeset with initialized entity
    changeset = Entities.change_entity(entity)

    form_key =
      case entity.uuid do
        nil -> nil
        uuid -> "entity-#{uuid}"
      end

    live_source = ensure_live_source(socket)

    socket =
      socket
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)
      |> assign(:fields, current_fields)
      |> assign(:field_types, FieldTypes.for_picker())
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, new_field_form())
      |> assign(:field_error, nil)
      |> assign(:field_key_manually_set, false)
      |> assign(:show_icon_picker, false)
      |> assign(:icon_search, "")
      |> assign(:selected_category, "All")
      |> assign(:icon_categories, ["All" | HeroIcons.list_categories()])
      |> assign(:available_icons, HeroIcons.list_all_icons())
      |> assign(:form_key, form_key)
      |> assign(:live_source, live_source)
      |> assign(:delete_confirm_index, nil)
      |> assign(:has_unsaved_changes, false)
      |> assign(:mirror_path, Storage.root_path())
      |> assign(:sort_mode, Entities.get_sort_mode(entity))
      |> mount_multilang()

    hydrate_entity_presence(socket, form_key, entity, current_user)
  end

  defp hydrate_entity_presence(socket, form_key, entity, current_user) do
    if (connected?(socket) and form_key) && entity.uuid do
      {:ok, _ref} =
        PresenceHelpers.track_editing_session(:entity, entity.uuid, socket, current_user)

      PresenceHelpers.subscribe_to_editing(:entity, entity.uuid)
      Events.subscribe_to_entity_form(form_key)

      socket = assign_editing_role(socket, entity.uuid)

      if socket.assigns.readonly?,
        do: load_spectator_state(socket, entity.uuid),
        else: socket
    else
      socket
      |> assign(:lock_owner?, true)
      |> assign(:readonly?, false)
    end
  end

  defp assign_editing_role(socket, entity_uuid) do
    current_user = socket.assigns[:current_user]

    case PresenceHelpers.get_editing_role(:entity, entity_uuid, socket.id, current_user.uuid) do
      {:owner, _presences} ->
        # I'm the owner - I can edit (or same user in different tab)
        socket
        |> assign(:lock_owner?, true)
        |> assign(:readonly?, false)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> assign(:lock_owner?, false)
        |> assign(:readonly?, true)
    end
  end

  defp load_spectator_state(socket, entity_uuid) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(:entity, entity_uuid) do
      %{form_state: form_state} when not is_nil(form_state) ->
        # Apply owner's form state
        changeset_params =
          Map.get(form_state, :changeset_params) || Map.get(form_state, "changeset_params")

        fields = Map.get(form_state, :fields) || Map.get(form_state, "fields")

        if changeset_params && fields do
          changeset = Entities.change_entity(socket.assigns.entity, changeset_params)

          socket
          |> assign(:changeset, changeset)
          |> assign(:fields, fields)
          |> assign(:has_unsaved_changes, true)
        else
          socket
        end

      _ ->
        # No form state to sync
        socket
    end
  end

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  @impl true
  def handle_event("validate", %{"entities" => entity_params}, socket) do
    if socket.assigns[:lock_owner?] do
      do_validate(entity_params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"entities" => entity_params} = params, socket) do
    if socket.assigns[:lock_owner?] do
      # "Create and Return" / "Update and Return" submits a second button
      # named `return_to_list=true`; the regular Create/Update button omits it.
      return_to_list? = params["return_to_list"] == "true"
      do_save(entity_params, assign(socket, :return_to_list, return_to_list?))
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
    end
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Reload entity from database or reset to empty state
      {entity, fields} =
        if socket.assigns.entity.uuid do
          # Reload from database
          reloaded_entity = Entities.get_entity!(socket.assigns.entity.uuid)
          {reloaded_entity, reloaded_entity.fields_definition || []}
        else
          # Reset to empty new entity
          {%Entities{}, []}
        end

      changeset = Entities.change_entity(entity)

      socket =
        socket
        |> assign(:entity, entity)
        |> assign(:changeset, changeset)
        |> assign(:fields, fields)
        |> assign(:show_field_form, false)
        |> assign(:editing_field_index, nil)
        |> assign(:field_form, new_field_form())
        |> assign(:field_error, nil)
        |> assign(:show_icon_picker, false)
        |> assign(:delete_confirm_index, nil)
        |> put_flash(:info, gettext("Changes reset to last saved state"))

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot reset - you are spectating"))}
    end
  end

  # Icon Picker Events

  def handle_event("open_icon_picker", _params, socket) do
    socket = assign(socket, :show_icon_picker, true)
    reply_with_broadcast(socket)
  end

  def handle_event("close_icon_picker", _params, socket) do
    socket =
      assign(socket,
        show_icon_picker: false,
        icon_search: "",
        selected_category: "All"
      )

    reply_with_broadcast(socket)
  end

  def handle_event("stop_propagation", _params, socket) do
    # This event does nothing - it just prevents the click from propagating to the backdrop
    {:noreply, socket}
  end

  def handle_event("generate_entity_slug", _params, socket) do
    if socket.assigns[:lock_owner?] do
      changeset = socket.assigns.changeset

      # Get display_name from changeset
      display_name = Ecto.Changeset.get_field(changeset, :display_name) || ""

      # Don't generate if display_name is empty
      if display_name == "" do
        {:noreply, socket}
      else
        # Generate slug from display_name (snake_case)
        slug = generate_slug_from_name(display_name)

        # Update changeset with generated slug while preserving all other data
        changeset = update_changeset_field(socket, %{"name" => slug})

        socket = assign(socket, :changeset, changeset)
        reply_with_broadcast(socket)
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_icon", %{"icon" => icon_name}, socket) do
    if socket.assigns[:lock_owner?] do
      # Update the changeset with the selected icon while preserving all other data
      changeset = update_changeset_field(socket, %{"icon" => icon_name})

      socket =
        socket
        |> assign(:changeset, changeset)
        |> assign(:show_icon_picker, false)
        |> assign(:icon_search, "")
        |> assign(:selected_category, "All")

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_icon", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Clear the icon field while preserving all other data
      changeset = update_changeset_field(socket, %{"icon" => nil})

      socket = assign(socket, :changeset, changeset)
      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_icons", %{"search" => search_term}, socket) do
    filtered_icons =
      if String.trim(search_term) == "" do
        if socket.assigns.selected_category == "All" do
          HeroIcons.list_all_icons()
        else
          HeroIcons.list_icons_by_category()[socket.assigns.selected_category] || []
        end
      else
        HeroIcons.search_icons(search_term)
      end

    socket =
      socket
      |> assign(:icon_search, search_term)
      |> assign(:available_icons, filtered_icons)

    reply_with_broadcast(socket)
  end

  def handle_event("filter_by_category", %{"tab" => category}, socket) do
    filtered_icons =
      if category == "All" do
        HeroIcons.list_all_icons()
      else
        HeroIcons.list_icons_by_category()[category] || []
      end

    socket =
      socket
      |> assign(:selected_category, category)
      |> assign(:available_icons, filtered_icons)
      |> assign(:icon_search, "")

    reply_with_broadcast(socket)
  end

  # Field Management Events

  def handle_event("add_field", _params, socket) do
    if socket.assigns[:lock_owner?] do
      socket =
        socket
        |> assign(:show_field_form, true)
        |> assign(:editing_field_index, nil)
        |> assign(:field_form, new_field_form())
        |> assign(:field_key_manually_set, false)
        |> assign(:field_error, nil)
        |> assign(:delete_confirm_index, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("edit_field", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      field = Enum.at(socket.assigns.fields, index)

      socket =
        socket
        |> assign(:show_field_form, true)
        |> assign(:editing_field_index, index)
        |> assign(:field_form, normalize_field_form(field) || %{})
        |> assign(:field_key_manually_set, true)
        |> assign(:field_error, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("cancel_field", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, new_field_form())
      |> assign(:field_key_manually_set, false)
      |> assign(:field_error, nil)

    reply_with_broadcast(socket)
  end

  def handle_event("save_field", %{"field" => field_params}, socket) do
    if socket.assigns[:lock_owner?] do
      field_form = socket.assigns.field_form || %{}
      merged_params = Map.merge(field_form, field_params)
      sanitized_options = sanitize_field_options(merged_params)
      merged_params = Map.put(merged_params, "options", sanitized_options)

      # Process file-specific fields
      merged_params = process_file_upload_settings(merged_params)

      with :ok <- validate_field_requirements(merged_params, sanitized_options),
           :ok <-
             validate_unique_field_key(
               merged_params,
               socket.assigns.fields,
               socket.assigns.editing_field_index
             ),
           {:ok, validated_field} <- FieldTypes.validate_field(merged_params) do
        socket = save_validated_field(socket, validated_field)
        reply_with_broadcast(socket)
      else
        {:error, reason} ->
          socket = assign(socket, :field_error, PhoenixKitEntities.Errors.message(reason))
          reply_with_broadcast(socket)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save field - you are spectating"))}
    end
  end

  def handle_event("confirm_delete_field", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, :delete_confirm_index, index)}
  end

  def handle_event("cancel_delete_field", _params, socket) do
    {:noreply, assign(socket, :delete_confirm_index, nil)}
  end

  def handle_event("delete_field", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      fields = List.delete_at(socket.assigns.fields, index)

      socket =
        socket
        |> assign(:fields, fields)
        |> assign(:delete_confirm_index, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot delete field - you are spectating"))}
    end
  end

  def handle_event("move_field_up", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      if index > 0 do
        fields = move_field(socket.assigns.fields, index, index - 1)
        socket = assign(socket, :fields, fields)
        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_field_down", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      if index < length(socket.assigns.fields) - 1 do
        fields = move_field(socket.assigns.fields, index, index + 1)
        socket = assign(socket, :fields, fields)
        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_field_form", %{"field" => field_params} = params, socket) do
    if socket.assigns[:lock_owner?] do
      target = Map.get(params, "_target", [])
      manual_key? = manual_key_target?(target)

      field_params =
        if manual_key?, do: field_params, else: Map.delete(field_params, "key")

      # Update field form with live changes
      current_form = normalize_field_form(socket.assigns.field_form)

      updated_form =
        current_form
        |> Map.merge(field_params)
        |> maybe_auto_update_field_key(current_form, socket.assigns.field_key_manually_set,
          editing?: socket.assigns.editing_field_index != nil
        )

      socket =
        socket
        |> assign(:field_form, updated_form)
        |> assign(:field_key_manually_set, manual_key? || socket.assigns.field_key_manually_set)
        # Clear error when user makes changes
        |> assign(:field_error, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_option", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = current_options ++ [""]

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_option", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = List.delete_at(current_options, index)

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_option", %{"index" => index} = params, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      # Extract value from phx-change format: %{"option" => %{"0" => "value"}}
      value =
        case params do
          %{"option" => option_map} when is_map(option_map) ->
            Map.get(option_map, to_string(index), "")

          %{"value" => v} ->
            v

          _ ->
            ""
        end

      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = List.replace_at(current_options, index, value)

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_field_key", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Get label from field form
      label = Map.get(socket.assigns.field_form, "label", "")

      # Don't generate if label is empty
      if label == "" do
        {:noreply, socket}
      else
        # Generate key from label (snake_case)
        key = generate_slug_from_name(label)

        # Update field form with generated key
        field_form = Map.put(socket.assigns.field_form, "key", key)
        socket = assign(socket, :field_form, field_form)

        reply_with_broadcast(socket)
      end
    else
      {:noreply, socket}
    end
  end

  # Public Form Configuration Events

  def handle_event("toggle_public_form", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      current_enabled = Map.get(current_settings, "public_form_enabled", false)

      updated_settings = Map.put(current_settings, "public_form_enabled", !current_enabled)

      # Initialize default fields when enabling
      updated_settings =
        if current_enabled do
          updated_settings
        else
          Map.put(updated_settings, "public_form_fields", [])
        end

      # Update the entity with new settings
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("update_public_form_setting", params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}

      # Extract the setting name and value from params
      {setting_name, value} =
        cond do
          Map.has_key?(params, "public_form_title") ->
            {"public_form_title", params["public_form_title"]}

          Map.has_key?(params, "public_form_description") ->
            {"public_form_description", params["public_form_description"]}

          Map.has_key?(params, "public_form_submit_text") ->
            {"public_form_submit_text", params["public_form_submit_text"]}

          Map.has_key?(params, "public_form_success_message") ->
            {"public_form_success_message", params["public_form_success_message"]}

          true ->
            {nil, nil}
        end

      if setting_name do
        updated_settings = Map.put(current_settings, setting_name, value)
        updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
        changeset = Entities.change_entity(updated_entity)

        socket =
          socket
          |> assign(:entity, updated_entity)
          |> assign(:changeset, changeset)

        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_public_form_field", %{"field" => field_key}, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      current_fields = Map.get(current_settings, "public_form_fields", [])

      # Toggle the field in the list
      updated_fields =
        if field_key in current_fields do
          List.delete(current_fields, field_key)
        else
          current_fields ++ [field_key]
        end

      updated_settings = Map.put(current_settings, "public_form_fields", updated_fields)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("toggle_security_setting", %{"setting" => setting_key}, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}

      # For metadata, default is true (enabled), so we check != false
      current_value =
        if setting_key == "public_form_collect_metadata" do
          Map.get(current_settings, setting_key) != false
        else
          Map.get(current_settings, setting_key, false)
        end

      updated_settings = Map.put(current_settings, setting_key, !current_value)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("update_security_action", params, socket) do
    if socket.assigns[:lock_owner?] do
      # Extract the setting key and value from params
      # The select sends the setting name in phx-value-setting and value in the form field
      setting_key = params["setting"]
      # The value comes from the select with the same name as the setting
      value = params[setting_key]

      current_settings = socket.assigns.entity.settings || %{}
      updated_settings = Map.put(current_settings, setting_key, value)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("reset_form_stats", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      updated_settings = Map.delete(current_settings, "public_form_stats")
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)
        |> put_flash(:info, gettext("Form statistics have been reset"))

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  # Backup Settings Events

  def handle_event("toggle_backup_definitions", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity
      current_value = Entities.mirror_definitions_enabled?(entity)
      new_value = !current_value

      # When disabling definitions, also disable data sync
      new_settings =
        if new_value do
          %{"mirror_definitions" => true}
        else
          %{"mirror_definitions" => false, "mirror_data" => false}
        end

      case Entities.update_mirror_settings(entity, new_settings) do
        {:ok, updated_entity} ->
          socket =
            socket
            |> assign(:entity, updated_entity)
            |> assign(:changeset, Entities.change_entity(updated_entity))

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update backup settings"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("toggle_backup_data", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity
      current_value = Entities.mirror_data_enabled?(entity)
      new_value = !current_value

      case Entities.update_mirror_settings(entity, %{"mirror_data" => new_value}) do
        {:ok, updated_entity} ->
          socket =
            socket
            |> assign(:entity, updated_entity)
            |> assign(:changeset, Entities.change_entity(updated_entity))

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update backup settings"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("export_entity_now", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity

      message =
        case Exporter.export_entity(entity) do
          {:ok, _path, :with_data} ->
            gettext("Exported %{name} (definition + records)", name: entity.display_name)

          {:ok, _path, :definition_only} ->
            gettext("Exported %{name} (definition only)", name: entity.display_name)

          {:error, _reason} ->
            nil
        end

      socket =
        if message do
          put_flash(socket, :info, message)
        else
          put_flash(socket, :error, gettext("Export failed"))
        end

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot export - you are spectating"))}
    end
  end

  # ── Validate/Save helpers (below all handle_event clauses to avoid grouping warnings) ──

  defp do_validate(entity_params, socket) do
    existing_data = changeset_to_string_map(socket.assigns.changeset)
    entity_params = Map.merge(existing_data, entity_params)
    entity_params = maybe_auto_generate_slug(entity_params, existing_data, socket.assigns.entity)

    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    settings = merge_translation_params(socket, entity_params)

    settings =
      case entity_params["sort_mode"] do
        mode when mode in ~w(auto manual) -> Map.put(settings, "sort_mode", mode)
        _ -> settings
      end

    entity_params =
      entity_params
      |> Map.put("settings", settings)
      |> Map.delete("translations")

    entity_params =
      if socket.assigns.entity.uuid,
        do: entity_params,
        else: Map.put(entity_params, "created_by_uuid", socket.assigns.current_user.uuid)

    # `change_entity/2` doesn't go through `repo.insert/update`, so the
    # changeset action defaults to `nil`. `<.input>` only renders inline
    # errors when `changeset.action != nil`, so without this set, every
    # validation error is silent. Use `:validate` (matches the event).
    changeset =
      socket.assigns.entity
      |> Entities.change_entity(entity_params)
      |> Map.put(:action, :validate)

    entity = %{socket.assigns.entity | settings: settings}

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:entity, entity)
      |> assign(:sort_mode, settings["sort_mode"] || "auto")

    reply_with_broadcast(socket)
  end

  defp changeset_to_string_map(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.drop([:__meta__, :creator, :entity_data, :id, :uuid, :date_created, :date_updated])
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_auto_generate_slug(entity_params, existing_data, entity) do
    if entity.uuid do
      entity_params
    else
      display_name = entity_params["display_name"] || ""
      current_slug = entity_params["name"] || ""
      previous_display_name = existing_data["display_name"] || ""
      auto_generated_slug = generate_slug_from_name(previous_display_name)

      if current_slug == "" || current_slug == auto_generated_slug do
        Map.put(entity_params, "name", generate_slug_from_name(display_name))
      else
        entity_params
      end
    end
  end

  defp do_save(entity_params, socket) do
    existing_data = changeset_to_string_map(socket.assigns.changeset)
    entity_params = Map.merge(existing_data, entity_params)
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    settings = merge_translation_params(socket, entity_params)

    settings =
      case entity_params["sort_mode"] do
        mode when mode in ~w(auto manual) -> Map.put(settings, "sort_mode", mode)
        _ -> settings
      end

    entity_params =
      entity_params
      |> Map.put("settings", settings)
      |> Map.delete("translations")

    entity_params =
      if socket.assigns.entity.uuid,
        do: entity_params,
        else: Map.put(entity_params, "created_by_uuid", socket.assigns.current_user.uuid)

    try do
      case save_entity(socket, entity_params) do
        {:ok, saved_entity} ->
          handle_save_success(socket, saved_entity)

        {:error, %Ecto.Changeset{} = changeset} ->
          reply_with_broadcast(assign(socket, :changeset, changeset))

        # Managed-blueprint refusals arrive as atoms, not changesets —
        # without this branch they fell into the rescue below and read
        # as an unexplained crash (panel finding, 2026-08-19 review).
        {:error, reason} when reason in [:managed_blueprint, :locked_key] ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext(
               "The blueprint's slug, status and module-locked settings are protected — revert those changes to save."
             )
           )}
      end
    rescue
      e ->
        require Logger

        Logger.error(
          "Entity save failed: #{Exception.message(e)} " <>
            "(entity_uuid=#{inspect(entity_uuid_for_log(socket))})"
        )

        {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
    end
  end

  # Pulls the entity uuid off socket assigns for error-log context.
  # Returns `nil` for the new-entity path (no uuid yet) so the log
  # line still differentiates "save failed before insert" from "save
  # failed updating <uuid>".
  defp entity_uuid_for_log(socket) do
    case socket.assigns[:entity] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp handle_save_success(socket, saved_entity) do
    locale = socket.assigns[:current_locale] || "en"

    cond do
      socket.assigns[:return_to_list] ->
        flash =
          if socket.assigns.entity.uuid,
            do: gettext("Entity saved successfully"),
            else: gettext("Entity created successfully")

        # Prefer the page the user came from (captured at mount and
        # validated as an internal admin path); fall back to the
        # entities list. `Routes.path/2` already carries the URL prefix
        # so the captured path is used as-is.
        return_target =
          socket.assigns[:return_to_path] ||
            Routes.path("/admin/entities", locale: locale)

        socket =
          socket
          |> put_flash(:info, flash)
          |> push_navigate(to: return_target)

        {:noreply, socket}

      socket.assigns.entity.uuid ->
        changeset = Entities.change_entity(saved_entity)

        socket =
          socket
          |> assign(:entity, saved_entity)
          |> assign(:changeset, changeset)
          |> assign(:fields, saved_entity.fields_definition || [])
          |> assign(:sort_mode, Entities.get_sort_mode(saved_entity))
          |> put_flash(:info, gettext("Entity saved successfully"))

        reply_with_broadcast(socket)

      true ->
        socket =
          socket
          |> put_flash(:info, gettext("Entity created successfully"))
          |> push_navigate(
            to: Routes.path("/admin/entities/#{saved_entity.uuid}/edit", locale: locale)
          )

        {:noreply, socket}
    end
  end

  ## Live updates

  @impl true
  def handle_info({:entity_form_change, form_key, payload, source}, socket) do
    cond do
      socket.assigns.form_key == nil ->
        {:noreply, socket}

      form_key != socket.assigns.form_key ->
        {:noreply, socket}

      source == socket.assigns.live_source ->
        {:noreply, socket}

      true ->
        try do
          socket = apply_remote_entity_form_change(socket, payload)
          {:noreply, socket}
        rescue
          e ->
            Logger.error(
              "Failed to apply remote entity form change: #{inspect(e)} " <>
                "(entity_uuid=#{inspect(entity_uuid_for_log(socket))})"
            )

            {:noreply, socket}
        end
    end
  end

  def handle_info({:entity_created, _}, socket), do: {:noreply, socket}

  def handle_info({:entity_updated, entity_uuid}, socket) do
    cond do
      socket.assigns.entity.uuid != entity_uuid -> {:noreply, socket}
      socket.assigns[:lock_owner?] -> {:noreply, socket}
      true -> handle_remote_entity_update(socket, entity_uuid)
    end
  end

  def handle_info({:entity_deleted, entity_uuid}, socket) do
    if socket.assigns.entity.uuid == entity_uuid do
      locale = socket.assigns[:current_locale] || "en"

      socket =
        socket
        |> put_flash(:error, gettext("This entity was deleted in another session."))
        |> push_navigate(to: Routes.path("/admin/entities", locale: locale))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Someone joined or left - check if our role changed
    if socket.assigns.entity && socket.assigns.entity.uuid do
      entity_uuid = socket.assigns.entity.uuid
      was_owner = socket.assigns[:lock_owner?]

      # Re-evaluate our role
      socket = assign_editing_role(socket, entity_uuid)

      # If we were promoted from spectator to owner, reload fresh data
      if !was_owner && socket.assigns[:lock_owner?] do
        entity = Entities.get_entity!(entity_uuid)

        socket
        |> assign(:entity, entity)
        |> assign(:changeset, Entities.change_entity(entity))
        |> assign(:fields, entity.fields_definition || [])
        |> assign(:has_unsaved_changes, false)
        |> then(&{:noreply, &1})
      else
        # Just a presence update (someone joined/left as spectator)
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Catch-all — log at :debug rather than crashing the socket so unexpected
  # messages stay visible during development without producing noise in prod.
  def handle_info(message, socket) do
    Logger.debug(fn ->
      "EntityForm: unhandled handle_info — #{inspect(message)}"
    end)

    {:noreply, socket}
  end

  # Helper Functions

  defp handle_remote_entity_update(socket, entity_uuid) do
    entity = Entities.get_entity!(entity_uuid)
    locale = socket.assigns[:current_locale] || "en"

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
       |> redirect(to: Routes.path("/admin/entities", locale: locale))}
    else
      {:noreply,
       socket
       |> refresh_entity_state(entity)
       |> put_flash(:info, gettext("Entity updated in another session."))}
    end
  end

  defp reply_with_broadcast(socket) do
    {:noreply, broadcast_entity_form_state(socket)}
  end

  defp broadcast_entity_form_state(socket, extra \\ %{}) do
    socket =
      if connected?(socket) && socket.assigns[:form_key] && socket.assigns.entity.uuid &&
           socket.assigns[:lock_owner?] do
        entity_uuid = socket.assigns.entity.uuid
        topic = PresenceHelpers.editing_topic(:entity, entity_uuid)

        payload =
          %{
            changeset_params: extract_entity_changeset_params(socket.assigns.changeset),
            fields: socket.assigns.fields
          }
          |> Map.merge(extra)

        # Update Presence metadata with form state (for spectators to sync)
        Presence.update(self(), topic, socket.id, fn meta ->
          Map.put(meta, :form_state, payload)
        end)

        # Also broadcast for real-time sync to spectators
        Events.broadcast_entity_form_change(socket.assigns.form_key, payload,
          source: socket.assigns.live_source
        )

        socket
      else
        socket
      end

    # Mark that we have unsaved changes
    assign(socket, :has_unsaved_changes, true)
  end

  defp apply_remote_entity_form_change(socket, payload) do
    changeset_params =
      Map.get(payload, :changeset_params) ||
        Map.get(payload, "changeset_params") ||
        extract_entity_changeset_params(socket.assigns.changeset)

    fields = Map.get(payload, :fields) || Map.get(payload, "fields") || socket.assigns.fields

    entity_params =
      changeset_params
      |> Map.put("fields_definition", fields)

    changeset =
      socket.assigns.entity
      |> Entities.change_entity(entity_params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:fields, fields)
    |> assign(:changeset, changeset)
    |> assign(:delete_confirm_index, nil)
    |> assign(:has_unsaved_changes, true)

    # Note: UI-only state (show_icon_picker, icon_search, selected_category,
    # show_field_form, editing_field_index, field_form, field_error, delete_confirm_index)
    # is not synced from remote changes to keep modal and form state local to each user
  end

  defp extract_entity_changeset_params(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :creator,
      :entity_data,
      :fields_definition,
      :inserted_at,
      :updated_at
    ])
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp refresh_entity_state(socket, entity) do
    fields = entity.fields_definition || []

    params =
      socket.assigns.changeset
      |> extract_entity_changeset_params()
      |> Map.put("fields_definition", fields)

    changeset =
      entity
      |> Entities.change_entity(params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:entity, entity)
    |> assign(:fields, fields)
    |> assign(:changeset, changeset)
    |> maybe_update_available_icons()
  end

  defp maybe_update_available_icons(socket) do
    icons =
      cond do
        socket.assigns.icon_search && String.trim(socket.assigns.icon_search) != "" ->
          HeroIcons.search_icons(socket.assigns.icon_search)

        socket.assigns.selected_category == "All" ->
          HeroIcons.list_all_icons()

        true ->
          HeroIcons.list_icons_by_category()[socket.assigns.selected_category] || []
      end

    assign(socket, :available_icons, icons)
  end

  defp sanitize_field_options(params) do
    params
    |> Map.get("options", [])
    |> Enum.reject(&(&1 in [nil, ""] || String.trim(to_string(&1)) == ""))
  end

  defp validate_field_requirements(params, sanitized_options) do
    field_type = params["type"]

    cond do
      field_type in ["select", "radio", "checkbox"] and sanitized_options == [] ->
        {:error, gettext("Field type '%{type}' requires at least one option", type: field_type)}

      field_type == "relation" and params["target_entity"] in [nil, ""] ->
        {:error, gettext("Relation field requires a target entity")}

      true ->
        :ok
    end
  end

  defp save_validated_field(socket, validated_field) do
    fields =
      case socket.assigns.editing_field_index do
        nil -> socket.assigns.fields ++ [validated_field]
        index -> List.replace_at(socket.assigns.fields, index, validated_field)
      end

    socket
    |> assign(:fields, fields)
    |> assign(:show_field_form, false)
    |> assign(:editing_field_index, nil)
    |> assign(:field_form, new_field_form())
    |> assign(:field_error, nil)
  end

  # Threads the current user UUID through to context functions that
  # accept `actor_uuid:` opts.
  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp save_entity(socket, entity_params) do
    opts = actor_opts(socket)

    if socket.assigns.entity.uuid do
      # Reload entity from database to ensure Ecto detects all changes
      # (socket.assigns.entity may have in-memory modifications that mask changes)
      fresh_entity = Entities.get_entity!(socket.assigns.entity.uuid)
      Entities.update_entity(fresh_entity, entity_params, opts)
    else
      Entities.create_entity(entity_params, opts)
    end
  end

  defp move_field(fields, from_index, to_index) do
    field = Enum.at(fields, from_index)

    fields
    |> List.delete_at(from_index)
    |> List.insert_at(to_index, field)
  end

  defp validate_unique_field_key(field_params, existing_fields, editing_index) do
    new_key = field_params["key"]

    duplicate? =
      existing_fields
      |> Enum.with_index()
      |> Enum.any?(fn {field, index} ->
        field["key"] == new_key && index != editing_index
      end)

    if duplicate? do
      {:error,
       gettext("Field key '%{key}' already exists. Please use a unique key.", key: new_key)}
    else
      :ok
    end
  end

  defp update_changeset_field(socket, new_params) do
    # Get all current data from the changeset (both changes and original data)
    current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

    # Convert struct to map
    existing_data =
      current_data
      |> Map.from_struct()
      |> Map.drop([:__meta__, :creator, :entity_data, :id, :uuid, :date_created, :date_updated])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Merge existing data with new params (new params override existing)
    entity_params = Map.merge(existing_data, new_params)

    # Add fields_definition
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    # Add created_by for new entities
    entity_params =
      if socket.assigns.entity.uuid do
        entity_params
      else
        entity_params
        |> Map.put("created_by_uuid", socket.assigns.current_user.uuid)
      end

    socket.assigns.entity
    |> Entities.change_entity(entity_params)
    |> Map.put(:action, :validate)
  end

  # Template Helper Functions

  # FieldTypes.label_for/1 is the single source of truth for translated
  # field-type labels (one literal `gettext(...)` clause per type, so
  # `mix gettext.extract` picks them up) — this just delegates to it
  # instead of keeping a second copy of the same clauses here.
  def field_type_label(type_name), do: FieldTypes.label_for(type_name)

  def field_category_label(:basic), do: gettext("Basic")
  def field_category_label(:numeric), do: gettext("Numeric")
  def field_category_label(:boolean), do: gettext("Boolean")
  def field_category_label(:datetime), do: gettext("Date & Time")
  def field_category_label(:choice), do: gettext("Choice")
  def field_category_label(:advanced), do: gettext("Advanced")
  def field_category_label(other), do: to_string(other)

  def field_type_icon(type_name) do
    case FieldTypes.get_type(type_name) do
      nil -> "hero-question-mark-circle"
      type_info -> type_info.icon
    end
  end

  def requires_options?(type_name) do
    FieldTypes.requires_options?(type_name)
  end

  def icon_category_label("All"), do: gettext("All")
  def icon_category_label("General"), do: gettext("General")
  def icon_category_label("Content"), do: gettext("Content")
  def icon_category_label("Actions"), do: gettext("Actions")
  def icon_category_label("Navigation"), do: gettext("Navigation")
  def icon_category_label("Communication"), do: gettext("Communication")
  def icon_category_label("Users"), do: gettext("Users")
  def icon_category_label("Business"), do: gettext("Business")
  def icon_category_label("Interface"), do: gettext("Interface")
  def icon_category_label("Tech"), do: gettext("Tech")
  def icon_category_label("Status"), do: gettext("Status")
  def icon_category_label(category), do: category

  def format_stats_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} ->
        PhoenixKit.Utils.Date.format_datetime_with_user_format(datetime)

      _ ->
        iso_string
    end
  end

  def format_stats_datetime(_), do: "-"

  defp ensure_live_source(socket) do
    socket.assigns[:live_source] ||
      (socket.id ||
         "entities-form-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false))
  end

  defp generate_slug_from_name(name) when is_binary(name),
    do: Slug.slugify(name, separator: "_", transliterate: true)

  defp generate_slug_from_name(_), do: ""

  defp merge_translation_params(socket, entity_params) do
    settings = socket.assigns.entity.settings || %{}
    existing_translations = settings["translations"] || %{}

    # Extract translation params from form (e.g., %{"es-ES" => %{"display_name" => "Marcas"}})
    new_translations = entity_params["translations"] || %{}

    # Merge new translations into existing, stripping empty values
    updated_translations =
      Enum.reduce(new_translations, existing_translations, fn {lang_code, fields}, acc ->
        cleaned =
          fields
          |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
          |> Map.new()

        if map_size(cleaned) == 0 do
          Map.delete(acc, lang_code)
        else
          Map.put(acc, lang_code, cleaned)
        end
      end)

    if map_size(updated_translations) == 0 do
      Map.delete(settings, "translations")
    else
      Map.put(settings, "translations", updated_translations)
    end
  end

  defp new_field_form do
    %{
      "type" => "text",
      "key" => "",
      "label" => "",
      "required" => false,
      "default" => "",
      "options" => []
    }
  end

  defp normalize_field_form(nil), do: new_field_form()

  defp normalize_field_form(field) when is_map(field) do
    Enum.reduce(field, %{}, fn {key, value}, acc ->
      cond do
        is_binary(key) -> Map.put(acc, key, value)
        is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        true -> acc
      end
    end)
  end

  defp maybe_auto_update_field_key(updated_form, previous_form, manual?, opts) do
    if manual? || Keyword.get(opts, :editing?, false) do
      updated_form
    else
      auto_update_field_key(updated_form, previous_form)
    end
  end

  defp auto_update_field_key(updated_form, previous_form) do
    label = fetch_form_value(updated_form, "label") || ""
    current_key = fetch_form_value(updated_form, "key") || ""
    previous_label = fetch_form_value(previous_form, "label") || ""
    auto_generated_key = generate_slug_from_name(previous_label)

    if label != "" && (current_key == "" || current_key == auto_generated_key) do
      Map.put(updated_form, "key", generate_slug_from_name(label))
    else
      updated_form
    end
  end

  defp fetch_form_value(form, key) do
    Map.get(form, key) ||
      case key do
        "label" -> Map.get(form, :label)
        "key" -> Map.get(form, :key)
        "type" -> Map.get(form, :type)
        _ -> nil
      end
  end

  # File upload settings processing
  defp process_file_upload_settings(%{"type" => "file"} = params) do
    params
    |> process_max_entries()
    |> process_max_file_size()
    |> process_accept_list()
  end

  defp process_file_upload_settings(params), do: params

  defp process_max_entries(params) do
    max_entries =
      case params["max_entries"] do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int(value, 5)
        _ -> 5
      end

    # Clamp to valid range (1-20)
    max_entries = max(1, min(20, max_entries))
    Map.put(params, "max_entries", max_entries)
  end

  defp process_max_file_size(params) do
    max_file_size =
      case params do
        %{"max_file_size_mb" => mb_value} -> mb_to_bytes(mb_value, 15)
        %{"max_file_size" => bytes} when is_integer(bytes) -> bytes
        _ -> 15_728_640
      end

    # Clamp to valid range (1-100 MB)
    max_file_size = max(1_048_576, min(104_857_600, max_file_size))

    params
    |> Map.put("max_file_size", max_file_size)
    |> Map.delete("max_file_size_mb")
  end

  defp process_accept_list(params) do
    accept =
      case params["accept"] do
        list when is_list(list) -> list
        string when is_binary(string) -> parse_accept_list(string)
        _ -> []
      end

    Map.put(params, "accept", accept)
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> default
    end
  end

  defp parse_int(_non_binary, default), do: default

  defp mb_to_bytes(mb_string, default_mb) when is_binary(mb_string) do
    case Float.parse(mb_string) do
      {mb, _} -> round(mb * 1_048_576)
      _ -> default_mb * 1_048_576
    end
  end

  defp mb_to_bytes(mb_value, _default_mb) when is_number(mb_value) do
    round(mb_value * 1_048_576)
  end

  defp mb_to_bytes(_, default_mb), do: default_mb * 1_048_576

  defp parse_accept_list(accept_string) when is_binary(accept_string) do
    accept_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn ext ->
      if String.starts_with?(ext, "."), do: ext, else: "." <> ext
    end)
  end

  defp parse_accept_list(_non_binary), do: []

  # Helper functions for the view
  def bytes_to_mb(bytes) when is_integer(bytes) do
    Float.round(bytes / 1_048_576, 1)
  end

  def bytes_to_mb(_), do: 15.0

  def format_accept_list(accept) when is_list(accept) do
    Enum.join(accept, ", ")
  end

  def format_accept_list(_), do: ""

  defp manual_key_target?(["field", "key"]), do: true
  defp manual_key_target?(_), do: false

  # True for an EXISTING blueprint owned by another module — the fields
  # the write guard would refuse render disabled (with hidden twins so
  # the form params stay whole; disabled controls don't submit).
  defp managed_blueprint?(%{uuid: uuid} = entity) when not is_nil(uuid),
    do: PhoenixKitEntities.Managed.owner(entity) != nil

  defp managed_blueprint?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <.admin_page_header back={PhoenixKit.Utils.Routes.path("/admin/entities")}>
          <%!-- Edit mode's title duplicates the page_title assign already
          shown in the breadcrumb bar ("Edit Entity") — only the create
          mode's heading ("Create New Entity" vs. its distinct "New Entity"
          page_title) still needs to render here. --%>
          <h1
            :if={is_nil(@entity.uuid)}
            class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content"
          >
            {gettext("Create New Entity")}
          </h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {gettext("Define your custom content type with dynamic fields")}
          </p>
        </.admin_page_header>

        <%!-- Managed Banner — the blueprint belongs to another module.
        Since 2026-08-27 these ARE edited here (the owning modules dropped
        their own editors); only the structural surface stays locked. --%>
        <%= if owner = PhoenixKitEntities.Managed.owner(@entity) do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-shield-check" class="w-5 h-5" />
            <span>
              {gettext(
                "Managed by the %{owner} module. Its slug, status and %{owner}-locked settings are protected — everything else is edited right here.",
                owner: owner
              )}
            </span>
          </div>
        <% end %>

        <%!-- Readonly Banner --%>
        <%= if @readonly? do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-eye" class="w-5 h-5" />
            <span>
              {gettext(
                "This entity is currently being edited by another user. You are in view-only mode."
              )}
            </span>
          </div>
        <% end %>

        <.form
          :let={f}
          for={@changeset}
          id="entity-form"
          phx-change="validate"
          phx-debounce="500"
          phx-submit="save"
          class="space-y-8"
        >
          <div class="flex justify-end gap-2">
            <button
              type="submit"
              class="btn btn-primary btn-outline"
              disabled={!@changeset.valid? or @readonly?}
              phx-disable-with={gettext("Saving…")}
            >
              {if @entity.uuid, do: gettext("Update Entity"), else: gettext("Create Entity")}
            </button>
            <button
              type="submit"
              name="return_to_list"
              value="true"
              class="btn btn-primary"
              disabled={!@changeset.valid? or @readonly?}
              phx-disable-with={gettext("Saving…")}
            >
              {if @entity.uuid,
                do: gettext("Update and Return"),
                else: gettext("Create and Return")}
            </button>
          </div>

          <%!-- Entity Metadata Section --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-2xl mb-4">
                <.icon name="hero-information-circle" class="w-6 h-6" /> {gettext(
                  "Entity Information"
                )}
              </h2>

              <% lang_translations =
                if @multilang_enabled && @current_lang != @primary_language do
                  translations = (@entity.settings || %{})["translations"] || %{}
                  translations[@current_lang] || %{}
                else
                  %{}
                end %>

              <%!-- Language tabs --%>
              <%= if @show_multilang_tabs do %>
                <div class="alert alert-info py-2 text-xs mb-4">
                  <.icon name="hero-information-circle" class="w-4 h-4" />
                  <span>
                    {gettext(
                      "Use the language tabs below to translate this entity's name, plural name, slug, and description. The primary language (marked with a star) is required. Other languages are optional — any empty fields will fall back to the primary language value."
                    )}
                  </span>
                </div>
              <% end %>

              <.multilang_tabs
                multilang_enabled={@multilang_enabled}
                language_tabs={@language_tabs}
                current_lang={@current_lang}
                show_header={false}
                show_info={false}
                class="mb-4"
              />

              <.multilang_fields_wrapper
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                skeleton_class="space-y-6"
                fields_class="space-y-6"
              >
                <:skeleton>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-36"></div>
                      <div class="skeleton h-12 w-full"></div>
                      <div class="skeleton h-3 w-48"></div>
                    </div>
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-36"></div>
                      <div class="skeleton h-12 w-full"></div>
                      <div class="skeleton h-3 w-48"></div>
                    </div>
                  </div>
                  <div class="space-y-2">
                    <div class="skeleton h-4 w-24"></div>
                    <div class="skeleton h-12 w-full"></div>
                    <div class="skeleton h-3 w-56"></div>
                  </div>
                  <div class="space-y-2">
                    <div class="skeleton h-4 w-40"></div>
                    <div class="skeleton h-24 w-full"></div>
                  </div>
                </:skeleton>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <%!-- Entity Name (Singular) --%>
                  <.translatable_field
                    field_name="display_name"
                    form_prefix="entities"
                    changeset={@changeset}
                    schema_field={:display_name}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={lang_translations}
                    secondary_name={"entities[translations][#{@current_lang}][display_name]"}
                    lang_data_key="display_name"
                    label={gettext("Entity Name (Singular)")}
                    placeholder={gettext("Brand")}
                    required
                    disabled={@readonly?}
                    class="w-full"
                    hint={gettext("Singular form (e.g., \"Brand\")")}
                  />

                  <%!-- Entity Name (Plural) --%>
                  <.translatable_field
                    field_name="display_name_plural"
                    form_prefix="entities"
                    changeset={@changeset}
                    schema_field={:display_name_plural}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={lang_translations}
                    secondary_name={"entities[translations][#{@current_lang}][display_name_plural]"}
                    lang_data_key="display_name_plural"
                    label={gettext("Entity Name (Plural)")}
                    placeholder={gettext("Brands")}
                    required
                    disabled={@readonly?}
                    class="w-full"
                    hint={gettext("Plural form (e.g., \"Brands\")")}
                  />
                </div>

                <%!-- Slug (translatable) --%>
                <.translatable_field
                  field_name="name"
                  form_prefix="entities"
                  changeset={@changeset}
                  schema_field={:name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={lang_translations}
                  secondary_name={"entities[translations][#{@current_lang}][name]"}
                  lang_data_key="name"
                  label={gettext("Slug")}
                  placeholder={gettext("brand")}
                  required
                  disabled={@readonly? or managed_blueprint?(@entity)}
                  class="w-full"
                  hint={
                    if managed_blueprint?(@entity),
                      do: gettext("Locked — the owning module keys on this slug"),
                      else: gettext("snake_case identifier used in the system")
                  }
                >
                  <:label_extra>
                    <%= if !@multilang_enabled || @current_lang == @primary_language do %>
                      <button
                        :if={not managed_blueprint?(@entity)}
                        type="button"
                        class="btn btn-ghost btn-xs ml-2"
                        phx-click="generate_entity_slug"
                        title={gettext("Generate from Entity Name")}
                        disabled={@readonly?}
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Generate")}
                      </button>
                    <% end %>
                  </:label_extra>
                </.translatable_field>
                <%!-- A disabled input doesn't submit; keep the slug in the
                params so validation stays whole. --%>
                <input
                  :if={managed_blueprint?(@entity)}
                  type="hidden"
                  name="entities[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                />

                <%!-- Description (translatable) --%>
                <.translatable_field
                  field_name="description"
                  form_prefix="entities"
                  changeset={@changeset}
                  schema_field={:description}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={lang_translations}
                  secondary_name={"entities[translations][#{@current_lang}][description]"}
                  lang_data_key="description"
                  label={gettext("Description (Optional)")}
                  placeholder={gettext("Describe what this entity represents...")}
                  type="textarea"
                  rows={3}
                  disabled={@readonly?}
                  class="w-full"
                />
              </.multilang_fields_wrapper>
            </div>
          </div>

          <%!-- Entity System Settings (non-translatable) --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-2xl mb-4">
                <.icon name="hero-cog-6-tooth" class="w-6 h-6" /> {gettext("System Settings")}
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <%!-- Icon --%>
                <div>
                  <.label for="entity_icon">{gettext("Icon (Optional)")}</.label>
                  <div class="flex gap-2">
                    <div class="flex-1">
                      <.input
                        field={f[:icon]}
                        type="text"
                        placeholder={gettext("hero-document-text")}
                        phx-debounce="300"
                        disabled={@readonly?}
                      />
                    </div>
                    <button
                      type="button"
                      phx-click="open_icon_picker"
                      class="btn btn-outline btn-square"
                      title={gettext("Browse icons")}
                      disabled={@readonly?}
                    >
                      <.icon name="hero-squares-2x2" class="w-5 h-5" />
                    </button>
                    <%= if f[:icon].value && f[:icon].value != "" do %>
                      <button
                        type="button"
                        phx-click="clear_icon"
                        class="btn btn-outline btn-square btn-error"
                        title={gettext("Clear icon")}
                        disabled={@readonly?}
                      >
                        <.icon name="hero-x-mark" class="w-5 h-5" />
                      </button>
                      <%= if String.starts_with?(f[:icon].value, "hero-") do %>
                        <div class="btn btn-square btn-ghost pointer-events-none">
                          <.icon name={f[:icon].value} class="w-6 h-6" />
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                  <.label class="label">
                    <span class="fieldset-label">
                      {gettext("Heroicon name or click Browse")}
                    </span>
                  </.label>
                </div>

                <%!-- Status --%>
                <div>
                  <.label for="entity_status">{gettext("Status")} *</.label>
                  <label class="select w-full">
                    <select
                      id="entity_status"
                      name={f[:status].name}
                      required
                      disabled={@readonly? or managed_blueprint?(@entity)}
                    >
                      <option value="published" selected={f[:status].value == "published"}>
                        {gettext("Published (active)")}
                      </option>
                      <option value="draft" selected={f[:status].value == "draft"}>
                        {gettext("Draft (not visible)")}
                      </option>
                      <option value="archived" selected={f[:status].value == "archived"}>
                        {gettext("Archived (hidden)")}
                      </option>
                    </select>
                  </label>
                  <input
                    :if={managed_blueprint?(@entity)}
                    type="hidden"
                    name={f[:status].name}
                    value={f[:status].value}
                  />
                  <.label class="label">
                    <span class="fieldset-label">
                      <%= if managed_blueprint?(@entity) do %>
                        {gettext("Locked — the owning module controls the lifecycle")}
                      <% else %>
                        {gettext("Only published can be used")}
                      <% end %>
                    </span>
                  </.label>
                </div>

                <%!-- Sort Mode --%>
                <div>
                  <.label for="entity_sort_mode">{gettext("Record Ordering")}</.label>
                  <label class="select w-full">
                    <select
                      id="entity_sort_mode"
                      name="entities[sort_mode]"
                      disabled={@readonly?}
                    >
                      <option
                        value="auto"
                        selected={@sort_mode == "auto"}
                      >
                        {gettext("Automatic (by creation date)")}
                      </option>
                      <option
                        value="manual"
                        selected={@sort_mode == "manual"}
                      >
                        {gettext("Manual (custom order)")}
                      </option>
                    </select>
                  </label>
                  <.label class="label">
                    <span class="fieldset-label">
                      {gettext("Manual mode enables drag-and-drop reordering of records")}
                    </span>
                  </.label>
                </div>
              </div>
            </div>
          </div>

          <%!-- Fields Section --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between mb-4">
                <h2 class="card-title text-2xl">
                  <.icon name="hero-list-bullet" class="w-6 h-6" />
                  {ngettext(
                    "%{count} Field Definition",
                    "%{count} Field Definitions",
                    length(@fields),
                    count: length(@fields)
                  )}
                </h2>
                <button
                  type="button"
                  class="btn btn-primary"
                  phx-click="add_field"
                  disabled={@readonly?}
                >
                  <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Add Field")}
                </button>
              </div>

              <%= if Enum.empty?(@fields) do %>
                <%!-- Empty Fields State --%>
                <div class="text-center py-8 border-2 border-dashed border-base-300 rounded-lg">
                  <div class="text-4xl mb-4 opacity-50">📝</div>
                  <h3 class="text-lg font-semibold text-base-content/60 mb-2">
                    {gettext("No Fields Yet")}
                  </h3>
                  <p class="text-base-content/50 mb-4">
                    {gettext("Add fields to define what data this entity can store")}
                  </p>
                  <button
                    type="button"
                    class="btn btn-primary"
                    phx-click="add_field"
                    disabled={@readonly?}
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Add Your First Field")}
                  </button>
                </div>
              <% else %>
                <%!-- Fields List --%>
                <div class="space-y-4">
                  <%= for {field, index} <- Enum.with_index(@fields) do %>
                    <div class="card bg-base-200 border border-base-300">
                      <div class="card-body p-4">
                        <div class="flex items-center justify-between">
                          <%!-- Move buttons (stacked vertically) at the beginning --%>
                          <div class="flex flex-col -space-y-1 mr-3">
                            <button
                              type="button"
                              class={"btn btn-ghost btn-xs px-1.5 #{if index == 0, do: "invisible", else: ""}"}
                              phx-click="move_field_up"
                              phx-value-index={index}
                              title={gettext("Move up")}
                              disabled={index == 0 or @readonly?}
                            >
                              <.icon name="hero-chevron-up" class="w-3 h-3" />
                            </button>
                            <button
                              type="button"
                              class={"btn btn-ghost btn-xs px-1.5 #{if index >= length(@fields) - 1, do: "invisible", else: ""}"}
                              phx-click="move_field_down"
                              phx-value-index={index}
                              title={gettext("Move down")}
                              disabled={index >= length(@fields) - 1 or @readonly?}
                            >
                              <.icon name="hero-chevron-down" class="w-3 h-3" />
                            </button>
                          </div>

                          <div class="flex items-center justify-between flex-1">
                            <%!-- Field Icon & Info --%>
                            <div class="flex items-center space-x-2">
                              <.icon
                                name={field_type_icon(field["type"])}
                                class="w-5 h-5 text-primary"
                              />
                              <div>
                                <div class="font-medium">{field["label"]}</div>
                                <div class="text-sm text-base-content/60">
                                  {field["key"]} · {field_type_label(field["type"])}
                                  {if field["required"], do: " · #{gettext("Required")}"}
                                </div>
                              </div>
                            </div>

                            <%!-- Field Actions --%>
                            <div class="flex items-center space-x-2">
                              <%= if @delete_confirm_index == index do %>
                                <%!-- Delete confirmation buttons --%>
                                <button
                                  type="button"
                                  class="btn btn-error btn-sm"
                                  phx-click="delete_field"
                                  phx-value-index={index}
                                  phx-disable-with={gettext("…")}
                                  disabled={@readonly?}
                                >
                                  {gettext("Confirm?")}
                                </button>
                                <button
                                  type="button"
                                  class="btn btn-outline btn-sm"
                                  phx-click="cancel_delete_field"
                                  disabled={@readonly?}
                                >
                                  {gettext("Cancel")}
                                </button>
                              <% else %>
                                <%!-- Edit button --%>
                                <button
                                  type="button"
                                  class="btn btn-primary btn-sm"
                                  phx-click="edit_field"
                                  phx-value-index={index}
                                  disabled={@readonly?}
                                >
                                  <.icon name="hero-pencil" class="w-4 h-4" />
                                </button>

                                <%!-- Delete button --%>
                                <button
                                  type="button"
                                  class="btn btn-error btn-sm"
                                  phx-click="confirm_delete_field"
                                  phx-value-index={index}
                                  title={gettext("Delete field")}
                                  disabled={@readonly?}
                                >
                                  <.icon name="hero-trash" class="w-4 h-4" />
                                </button>
                              <% end %>
                            </div>
                          </div>
                        </div>

                        <%!-- Field Options Preview --%>
                        <%= if requires_options?(field["type"]) && field["options"] do %>
                          <div class="mt-2 text-sm text-base-content/60">
                            <span class="font-medium">{gettext("Options")}:</span>
                            {Enum.join(field["options"], ", ")}
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Public Form Configuration Section --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="card-title text-2xl">
                    <.icon name="hero-globe-alt" class="w-6 h-6" />
                    {gettext("Public Form Configuration")}
                  </h2>
                  <p class="text-sm text-base-content/70 mt-1">
                    {gettext("Enable this entity to be used as an embeddable form on public pages")}
                  </p>
                </div>
              </div>

              <%!-- Enable Public Form Toggle --%>
              <div class="fieldset">
                <label class="label cursor-pointer justify-start gap-4">
                  <input
                    type="checkbox"
                    name="public_form_enabled"
                    class="toggle toggle-primary"
                    checked={get_in(@entity.settings, ["public_form_enabled"]) || false}
                    phx-click="toggle_public_form"
                    disabled={@readonly?}
                  />
                  <div>
                    <span class="fieldset-legend font-semibold">
                      {gettext("Enable Public Form")}
                    </span>
                    <p class="text-xs text-base-content/60 mt-1">
                      {gettext("Allow this entity to be embedded as a form on public pages")}
                    </p>
                  </div>
                </label>
              </div>

              <%= if get_in(@entity.settings, ["public_form_enabled"]) do %>
                <div class="divider"></div>

                <%!-- Form Configuration --%>
                <div class="space-y-4">
                  <%!-- Form Title --%>
                  <div>
                    <.label>{gettext("Form Title")}</.label>
                    <input
                      type="text"
                      name="public_form_title"
                      value={get_in(@entity.settings, ["public_form_title"]) || @entity.display_name}
                      placeholder={@entity.display_name}
                      class="input w-full"
                      phx-blur="update_public_form_setting"
                      phx-debounce="500"
                      disabled={@readonly?}
                    />
                  </div>

                  <%!-- Form Description --%>
                  <div>
                    <.label>{gettext("Form Description (Optional)")}</.label>
                    <textarea
                      name="public_form_description"
                      placeholder={gettext("Describe what this form is for...")}
                      class="textarea w-full"
                      rows="2"
                      phx-blur="update_public_form_setting"
                      phx-debounce="500"
                      disabled={@readonly?}
                    >{get_in(@entity.settings, ["public_form_description"]) || ""}</textarea>
                  </div>

                  <%!-- Submit Button Text --%>
                  <div>
                    <.label>{gettext("Submit Button Text")}</.label>
                    <input
                      type="text"
                      name="public_form_submit_text"
                      value={
                        get_in(@entity.settings, ["public_form_submit_text"]) || gettext("Submit")
                      }
                      placeholder={gettext("Submit")}
                      class="input w-full"
                      phx-blur="update_public_form_setting"
                      phx-debounce="500"
                      disabled={@readonly?}
                    />
                  </div>

                  <%!-- Success Message --%>
                  <div>
                    <.label>{gettext("Success Message")}</.label>
                    <textarea
                      name="public_form_success_message"
                      placeholder={gettext("Thank you for your submission!")}
                      class="textarea w-full"
                      rows="2"
                      phx-blur="update_public_form_setting"
                      phx-debounce="500"
                      disabled={@readonly?}
                    >{get_in(@entity.settings, ["public_form_success_message"]) || gettext("Thank you for your submission!")}</textarea>
                  </div>

                  <%!-- Field Selection --%>
                  <%= if not Enum.empty?(@fields) do %>
                    <div>
                      <.label>{gettext("Form Fields")}</.label>
                      <p class="text-sm text-base-content/60 mb-3">
                        {gettext(
                          "Select which fields to include in the public form. Fields not selected will only be visible in the admin data viewer."
                        )}
                      </p>

                      <div class="space-y-2 max-h-64 overflow-y-auto border border-base-300 rounded-lg p-3">
                        <%= for field <- @fields, field["type"] != "heading" do %>
                          <label class="flex items-center gap-3 p-2 hover:bg-base-200 rounded cursor-pointer">
                            <input
                              type="checkbox"
                              name="public_form_field"
                              value={field["key"]}
                              checked={
                                field["key"] in (get_in(@entity.settings, ["public_form_fields"]) ||
                                                   [])
                              }
                              phx-click="toggle_public_form_field"
                              phx-value-field={field["key"]}
                              class="checkbox checkbox-primary"
                              disabled={@readonly?}
                            />
                            <div class="flex items-center gap-2 flex-1">
                              <.icon
                                name={field_type_icon(field["type"])}
                                class="w-4 h-4 text-primary"
                              />
                              <div>
                                <span class="font-medium">{field["label"]}</span>
                                <span class="text-xs text-base-content/50 ml-2">
                                  ({field["key"]})
                                </span>
                              </div>
                            </div>
                            <span class="badge badge-sm badge-outline">
                              {field_type_label(field["type"])}
                            </span>
                          </label>
                        <% end %>
                      </div>
                    </div>
                  <% else %>
                    <div class="alert alert-warning">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                      <span>
                        {gettext(
                          "Add fields to this entity first before configuring the public form."
                        )}
                      </span>
                    </div>
                  <% end %>

                  <%!-- Usage Example --%>
                  <%= if not Enum.empty?(get_in(@entity.settings, ["public_form_fields"]) || []) do %>
                    <div class="alert alert-info">
                      <.icon name="hero-information-circle" class="w-5 h-5" />
                      <div class="flex-1">
                        <p class="font-semibold mb-1">{gettext("Embed this form:")}</p>
                        <code class="text-xs bg-base-300 px-2 py-1 rounded">
                          &lt;EntityForm entity_slug="{@entity.name}" /&gt;
                        </code>
                      </div>
                    </div>
                  <% end %>

                  <div class="divider"></div>

                  <%!-- Security Section --%>
                  <div>
                    <h3 class="text-lg font-semibold mb-4 flex items-center gap-2">
                      <.icon name="hero-shield-check" class="w-5 h-5" />
                      {gettext("Security")}
                    </h3>

                    <div class="space-y-4">
                      <%!-- Collect Metadata Toggle --%>
                      <div class="fieldset">
                        <label class="label cursor-pointer justify-start gap-4">
                          <input
                            type="checkbox"
                            name="public_form_collect_metadata"
                            class="toggle toggle-primary"
                            checked={
                              get_in(@entity.settings, ["public_form_collect_metadata"]) != false
                            }
                            phx-click="toggle_security_setting"
                            phx-value-setting="public_form_collect_metadata"
                            disabled={@readonly?}
                          />
                          <div>
                            <span class="fieldset-legend font-medium">
                              {gettext("Collect Submission Metadata")}
                            </span>
                            <p class="text-xs text-base-content/60 mt-1">
                              {gettext(
                                "Record IP address, browser, device info, and referrer for each submission"
                              )}
                            </p>
                          </div>
                        </label>
                      </div>

                      <%!-- Debug Mode Toggle --%>
                      <div class="fieldset">
                        <label class="label cursor-pointer justify-start gap-4">
                          <input
                            type="checkbox"
                            name="public_form_debug_mode"
                            class="toggle toggle-warning"
                            checked={get_in(@entity.settings, ["public_form_debug_mode"]) || false}
                            phx-click="toggle_security_setting"
                            phx-value-setting="public_form_debug_mode"
                            disabled={@readonly?}
                          />
                          <div>
                            <span class="fieldset-legend font-medium">
                              {gettext("Debug Mode")}
                            </span>
                            <p class="text-xs text-base-content/60 mt-1">
                              {gettext(
                                "Show detailed error messages when security checks fail (for troubleshooting only)"
                              )}
                            </p>
                          </div>
                        </label>
                      </div>

                      <%= if get_in(@entity.settings, ["public_form_debug_mode"]) do %>
                        <div class="alert alert-warning">
                          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                          <span class="text-sm">
                            {gettext(
                              "Debug mode is enabled. Detailed security errors will be shown to users. Disable this in production."
                            )}
                          </span>
                        </div>
                      <% end %>

                      <%!-- Honeypot Protection --%>
                      <div class="border border-base-300 rounded-lg p-4">
                        <div class="fieldset">
                          <label class="label cursor-pointer justify-start gap-4">
                            <input
                              type="checkbox"
                              name="public_form_honeypot"
                              class="toggle toggle-primary"
                              checked={get_in(@entity.settings, ["public_form_honeypot"]) || false}
                              phx-click="toggle_security_setting"
                              phx-value-setting="public_form_honeypot"
                              disabled={@readonly?}
                            />
                            <div>
                              <span class="fieldset-legend font-medium">
                                {gettext("Honeypot Protection")}
                              </span>
                              <p class="text-xs text-base-content/60 mt-1">
                                {gettext("Add a hidden field that bots typically fill out")}
                              </p>
                            </div>
                          </label>
                        </div>

                        <%= if get_in(@entity.settings, ["public_form_honeypot"]) do %>
                          <div class="mt-3 pl-14">
                            <.label class="text-sm">{gettext("When triggered:")}</.label>
                            <label class="select select-sm w-full max-w-xs mt-1">
                            <select
                              name="public_form_honeypot_action"
                              phx-change="update_security_action"
                              phx-value-setting="public_form_honeypot_action"
                              disabled={@readonly?}
                            >
                              <option
                                value="reject_silent"
                                selected={
                                  get_in(@entity.settings, ["public_form_honeypot_action"]) ==
                                    "reject_silent" ||
                                    is_nil(get_in(@entity.settings, ["public_form_honeypot_action"]))
                                }
                              >
                                {gettext("Reject silently (fake success)")}
                              </option>
                              <option
                                value="reject_error"
                                selected={
                                  get_in(@entity.settings, ["public_form_honeypot_action"]) ==
                                    "reject_error"
                                }
                              >
                                {gettext("Reject with error message")}
                              </option>
                              <option
                                value="save_suspicious"
                                selected={
                                  get_in(@entity.settings, ["public_form_honeypot_action"]) ==
                                    "save_suspicious"
                                }
                              >
                                {gettext("Save but mark as suspicious")}
                              </option>
                              <option
                                value="save_log"
                                selected={
                                  get_in(@entity.settings, ["public_form_honeypot_action"]) ==
                                    "save_log"
                                }
                              >
                                {gettext("Save and log warning")}
                              </option>
                            </select>
                            </label>
                          </div>
                        <% end %>
                      </div>

                      <%!-- Time-based Validation --%>
                      <div class="border border-base-300 rounded-lg p-4">
                        <div class="fieldset">
                          <label class="label cursor-pointer justify-start gap-4">
                            <input
                              type="checkbox"
                              name="public_form_time_check"
                              class="toggle toggle-primary"
                              checked={get_in(@entity.settings, ["public_form_time_check"]) || false}
                              phx-click="toggle_security_setting"
                              phx-value-setting="public_form_time_check"
                              disabled={@readonly?}
                            />
                            <div>
                              <span class="fieldset-legend font-medium">
                                {gettext("Time-based Validation")}
                              </span>
                              <p class="text-xs text-base-content/60 mt-1">
                                {gettext(
                                  "Check if submission happens too quickly (less than 3 seconds)"
                                )}
                              </p>
                            </div>
                          </label>
                        </div>

                        <%= if get_in(@entity.settings, ["public_form_time_check"]) do %>
                          <div class="mt-3 pl-14">
                            <.label class="text-sm">{gettext("When triggered:")}</.label>
                            <label class="select select-sm w-full max-w-xs mt-1">
                            <select
                              name="public_form_time_check_action"
                              phx-change="update_security_action"
                              phx-value-setting="public_form_time_check_action"
                              disabled={@readonly?}
                            >
                              <option
                                value="reject_error"
                                selected={
                                  get_in(@entity.settings, ["public_form_time_check_action"]) ==
                                    "reject_error" ||
                                    is_nil(
                                      get_in(@entity.settings, ["public_form_time_check_action"])
                                    )
                                }
                              >
                                {gettext("Reject with error message")}
                              </option>
                              <option
                                value="reject_silent"
                                selected={
                                  get_in(@entity.settings, ["public_form_time_check_action"]) ==
                                    "reject_silent"
                                }
                              >
                                {gettext("Reject silently (fake success)")}
                              </option>
                              <option
                                value="save_suspicious"
                                selected={
                                  get_in(@entity.settings, ["public_form_time_check_action"]) ==
                                    "save_suspicious"
                                }
                              >
                                {gettext("Save but mark as suspicious")}
                              </option>
                              <option
                                value="save_log"
                                selected={
                                  get_in(@entity.settings, ["public_form_time_check_action"]) ==
                                    "save_log"
                                }
                              >
                                {gettext("Save and log warning")}
                              </option>
                            </select>
                            </label>
                          </div>
                        <% end %>
                      </div>

                      <%!-- Rate Limiting --%>
                      <div class="border border-base-300 rounded-lg p-4">
                        <div class="fieldset">
                          <label class="label cursor-pointer justify-start gap-4">
                            <input
                              type="checkbox"
                              name="public_form_rate_limit"
                              class="toggle toggle-primary"
                              checked={get_in(@entity.settings, ["public_form_rate_limit"]) || false}
                              phx-click="toggle_security_setting"
                              phx-value-setting="public_form_rate_limit"
                              disabled={@readonly?}
                            />
                            <div>
                              <span class="fieldset-legend font-medium">
                                {gettext("Rate Limiting")}
                              </span>
                              <p class="text-xs text-base-content/60 mt-1">
                                {gettext("Limit submissions to 5 per minute per IP address")}
                              </p>
                            </div>
                          </label>
                        </div>

                        <%= if get_in(@entity.settings, ["public_form_rate_limit"]) do %>
                          <div class="mt-3 pl-14">
                            <.label class="text-sm">{gettext("When triggered:")}</.label>
                            <label class="select select-sm w-full max-w-xs mt-1">
                            <select
                              name="public_form_rate_limit_action"
                              phx-change="update_security_action"
                              phx-value-setting="public_form_rate_limit_action"
                              disabled={@readonly?}
                            >
                              <option
                                value="reject_error"
                                selected={
                                  get_in(@entity.settings, ["public_form_rate_limit_action"]) ==
                                    "reject_error" ||
                                    is_nil(
                                      get_in(@entity.settings, ["public_form_rate_limit_action"])
                                    )
                                }
                              >
                                {gettext("Reject with error message")}
                              </option>
                              <option
                                value="reject_silent"
                                selected={
                                  get_in(@entity.settings, ["public_form_rate_limit_action"]) ==
                                    "reject_silent"
                                }
                              >
                                {gettext("Reject silently (fake success)")}
                              </option>
                              <option
                                value="save_suspicious"
                                selected={
                                  get_in(@entity.settings, ["public_form_rate_limit_action"]) ==
                                    "save_suspicious"
                                }
                              >
                                {gettext("Save but mark as suspicious")}
                              </option>
                              <option
                                value="save_log"
                                selected={
                                  get_in(@entity.settings, ["public_form_rate_limit_action"]) ==
                                    "save_log"
                                }
                              >
                                {gettext("Save and log warning")}
                              </option>
                            </select>
                            </label>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%!-- Form Statistics --%>
                  <% stats = get_in(@entity.settings, ["public_form_stats"]) || %{} %>
                  <div class="divider"></div>

                  <div>
                    <h3 class="text-lg font-semibold mb-4 flex items-center gap-2">
                      <.icon name="hero-chart-bar" class="w-5 h-5" />
                      {gettext("Form Statistics")}
                    </h3>

                    <div class="stats stats-vertical lg:stats-horizontal shadow w-full bg-base-200">
                      <div class="stat">
                        <div class="stat-figure text-primary">
                          <.icon name="hero-document-text" class="w-8 h-8" />
                        </div>
                        <div class="stat-title">{gettext("Total Submissions")}</div>
                        <div class="stat-value text-primary">
                          {stats["total_submissions"] || 0}
                        </div>
                      </div>

                      <div class="stat">
                        <div class="stat-figure text-success">
                          <.icon name="hero-check-circle" class="w-8 h-8" />
                        </div>
                        <div class="stat-title">{gettext("Successful")}</div>
                        <div class="stat-value text-success">
                          {stats["successful_submissions"] || 0}
                        </div>
                      </div>

                      <div class="stat">
                        <div class="stat-figure text-error">
                          <.icon name="hero-x-circle" class="w-8 h-8" />
                        </div>
                        <div class="stat-title">{gettext("Rejected")}</div>
                        <div class="stat-value text-error">
                          {stats["rejected_submissions"] || 0}
                        </div>
                      </div>
                    </div>

                    <%!-- Security trigger breakdown --%>
                    <%= if stats["honeypot_triggers"] || stats["too_fast_triggers"] || stats["rate_limited_triggers"] do %>
                      <div class="mt-4">
                        <h4 class="text-sm font-medium text-base-content/70 mb-2">
                          {gettext("Security Triggers")}
                        </h4>
                        <div class="flex flex-wrap gap-2">
                          <%= if stats["honeypot_triggers"] do %>
                            <div class="badge badge-warning gap-1">
                              <.icon name="hero-bug-ant" class="w-3 h-3" />
                              {gettext("Honeypot: %{count}", count: stats["honeypot_triggers"])}
                            </div>
                          <% end %>
                          <%= if stats["too_fast_triggers"] do %>
                            <div class="badge badge-warning gap-1">
                              <.icon name="hero-bolt" class="w-3 h-3" />
                              {gettext("Too Fast: %{count}", count: stats["too_fast_triggers"])}
                            </div>
                          <% end %>
                          <%= if stats["rate_limited_triggers"] do %>
                            <div class="badge badge-warning gap-1">
                              <.icon name="hero-clock" class="w-3 h-3" />
                              {gettext("Rate Limited: %{count}",
                                count: stats["rate_limited_triggers"]
                              )}
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>

                    <%!-- Last submission time --%>
                    <%= if stats["last_submission_at"] do %>
                      <div class="mt-4 text-sm text-base-content/60">
                        {gettext("Last submission: %{datetime}",
                          datetime: format_stats_datetime(stats["last_submission_at"])
                        )}
                      </div>
                    <% end %>

                    <%!-- Reset Stats Button (only show if there are stats) --%>
                    <%= if stats["total_submissions"] do %>
                      <div class="mt-4">
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm"
                          phx-click="reset_form_stats"
                          disabled={@readonly?}
                        >
                          <.icon name="hero-arrow-path" class="w-4 h-4" />
                          {gettext("Reset Statistics")}
                        </button>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Backup Settings Section --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="card-title text-2xl">
                    <.icon name="hero-arrow-down-tray" class="w-6 h-6" />
                    {gettext("Backup Settings")}
                  </h2>
                  <p class="text-sm text-base-content/70 mt-1">
                    {gettext("Configure automatic backup to file for this entity")}
                  </p>
                </div>
                <%= if @entity.uuid do %>
                  <button
                    type="button"
                    class="btn btn-primary btn-sm"
                    phx-click="export_entity_now"
                    phx-disable-with={gettext("Exporting…")}
                    disabled={@readonly?}
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    {gettext("Export Now")}
                  </button>
                <% end %>
              </div>

              <%= if @entity.uuid do %>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <%!-- Definition Sync Toggle --%>
                  <div class="fieldset">
                    <label class="label cursor-pointer justify-start gap-4">
                      <input
                        type="checkbox"
                        class="toggle toggle-primary"
                        checked={PhoenixKitEntities.mirror_definitions_enabled?(@entity)}
                        phx-click="toggle_backup_definitions"
                        disabled={@readonly?}
                      />
                      <div>
                        <span class="fieldset-legend font-semibold">
                          {gettext("Sync Definition to File")}
                        </span>
                        <p class="text-xs text-base-content/60 mt-1">
                          {gettext("Automatically export entity schema when changes are saved")}
                        </p>
                      </div>
                    </label>
                  </div>

                  <%!-- Records Sync Toggle --%>
                  <div class={"fieldset #{unless PhoenixKitEntities.mirror_definitions_enabled?(@entity), do: "opacity-50"}"}>
                    <label class="label cursor-pointer justify-start gap-4">
                      <input
                        type="checkbox"
                        class="toggle toggle-primary"
                        checked={PhoenixKitEntities.mirror_data_enabled?(@entity)}
                        phx-click="toggle_backup_data"
                        disabled={
                          @readonly? or
                            not PhoenixKitEntities.mirror_definitions_enabled?(@entity)
                        }
                      />
                      <div>
                        <span class="fieldset-legend font-semibold">
                          {gettext("Sync Records to File")}
                        </span>
                        <p class="text-xs text-base-content/60 mt-1">
                          {gettext(
                            "Automatically export data records when they are created or updated"
                          )}
                        </p>
                      </div>
                    </label>
                  </div>
                </div>

                <%!-- File Info --%>
                <div class="mt-4 p-4 bg-base-200 rounded-lg">
                  <div class="flex items-center gap-2 text-sm">
                    <.icon name="hero-folder" class="w-4 h-4 text-base-content/70" />
                    <span class="text-base-content/70">{gettext("Export path")}:</span>
                    <code class="text-xs bg-base-300 px-2 py-1 rounded break-all">
                      {@mirror_path}/{@entity.name}.json
                    </code>
                  </div>
                </div>
              <% else %>
                <%!-- New entity - show message --%>
                <div class="alert alert-info">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <span>
                    {gettext("Save the entity first to configure backup settings.")}
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Form Actions --%>
          <div class="flex justify-between items-center">
            <div class="flex gap-2">
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin/entities")}
                class="btn btn-outline"
              >
                {gettext("Cancel")}
              </.link>

              <button type="button" phx-click="reset" class="btn btn-warning" disabled={@readonly?}>
                <.icon name="hero-arrow-path" class="w-4 h-4" />
                {gettext("Reset Changes")}
              </button>
            </div>

            <div class="flex gap-2">
              <button
                type="submit"
                class="btn btn-primary btn-outline"
                disabled={!@changeset.valid? or @readonly?}
                phx-disable-with={gettext("Saving…")}
              >
                {if @entity.uuid, do: gettext("Update Entity"), else: gettext("Create Entity")}
              </button>
              <button
                type="submit"
                name="return_to_list"
                value="true"
                class="btn btn-primary"
                disabled={!@changeset.valid? or @readonly?}
                phx-disable-with={gettext("Saving…")}
              >
                {if @entity.uuid,
                  do: gettext("Update and Return"),
                  else: gettext("Create and Return")}
              </button>
            </div>
          </div>
        </.form>

        <%!-- Field Form Modal --%>
        <%= if @show_field_form do %>
          <div class="modal modal-open" phx-click="cancel_field">
            <div class="modal-box w-11/12 max-w-2xl" phx-click="stop_propagation">
              <h3 class="font-bold text-lg mb-4">
                {if @editing_field_index, do: gettext("Edit Field"), else: gettext("Add New Field")}
              </h3>

              <%!-- Field Error Alert --%>
              <%= if @field_error do %>
                <div class="alert alert-error mb-4">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <span>{@field_error}</span>
                </div>
              <% end %>

              <.form
                for={%{}}
                id="entity-field-form"
                phx-change="update_field_form"
                phx-submit="save_field"
                class="space-y-4"
              >
                <%!-- Field Type --%>
                <div>
                  <.label>{gettext("Field Type")} *</.label>
                  <label class="select w-full">
                    <select
                      name="field[type]"
                      phx-debounce="300"
                      value={@field_form["type"]}
                    >
                      <%= for {category_key, _label} <- PhoenixKitEntities.FieldTypes.category_list() do %>
                        <optgroup label={field_category_label(category_key)}>
                          <%= for type <- PhoenixKitEntities.FieldTypes.by_category(category_key) do %>
                            <option value={type.name} selected={@field_form["type"] == type.name}>
                              {field_type_label(type.name)}
                            </option>
                          <% end %>
                        </optgroup>
                      <% end %>
                    </select>
                  </label>
                </div>

                <%!-- Field Label and Key --%>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <.label>{gettext("Field Label")} *</.label>
                    <input
                      type="text"
                      name="field[label]"
                      class="input w-full"
                      placeholder={gettext("Field Name")}
                      value={@field_form["label"]}
                      phx-debounce="300"
                      required
                    />
                    <.label class="label">
                      <span class="fieldset-label">{gettext("Display name for users")}</span>
                    </.label>
                  </div>

                  <div>
                    <.label>
                      {gettext("Slug")} *
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs ml-2"
                        phx-click="generate_field_key"
                        title={gettext("Generate from Field Label")}
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Generate")}
                      </button>
                    </.label>
                    <input
                      type="text"
                      name="field[key]"
                      class="input w-full"
                      placeholder={gettext("field_name")}
                      value={@field_form["key"]}
                      phx-debounce="300"
                      required
                    />
                    <.label class="label">
                      <span class="fieldset-label">{gettext("snake_case identifier")}</span>
                    </.label>
                  </div>
                </div>

                <%!-- Required and Default Value (meaningless for display-only heading fields) --%>
                <%= if @field_form["type"] != "heading" do %>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <.label class="label cursor-pointer">
                        <span class="fieldset-legend">{gettext("Required Field")}</span>
                        <input
                          type="checkbox"
                          name="field[required]"
                          class="toggle toggle-primary"
                          value="true"
                          checked={@field_form["required"]}
                        />
                      </.label>
                    </div>

                    <div>
                      <.label>{gettext("Default Value (Optional)")}</.label>
                      <input
                        type="text"
                        name="field[default]"
                        class="input w-full"
                        phx-debounce="300"
                        value={@field_form["default"]}
                      />
                    </div>
                  </div>
                <% end %>

                <%!-- File Upload Configuration (only for file type) --%>
                <%= if @field_form["type"] == "file" do %>
                  <div class="space-y-4 p-4 bg-base-200 rounded-lg">
                    <div class="text-sm font-semibold text-base-content/70">
                      {gettext("File Upload Settings")}
                    </div>

                    <%!-- Max Files --%>
                    <div class="fieldset">
                      <.label>{gettext("Maximum Files")}</.label>
                      <input
                        type="number"
                        name="field[max_entries]"
                        value={@field_form["max_entries"] || 5}
                        min="1"
                        max="20"
                        class="input"
                        placeholder="5"
                        phx-debounce="300"
                      />
                      <.label class="label">
                        <span class="fieldset-label">
                          {gettext("Max number of files users can upload (1-20)")}
                        </span>
                      </.label>
                    </div>

                    <%!-- Max File Size --%>
                    <div class="fieldset">
                      <.label>{gettext("Max File Size (MB)")}</.label>
                      <input
                        type="number"
                        name="field[max_file_size_mb]"
                        value={bytes_to_mb(@field_form["max_file_size"] || 15_728_640)}
                        min="1"
                        max="100"
                        step="0.1"
                        class="input"
                        placeholder="15"
                        phx-debounce="300"
                      />
                      <.label class="label">
                        <span class="fieldset-label">
                          {gettext("Maximum size per file in megabytes (1-100 MB)")}
                        </span>
                      </.label>
                    </div>

                    <%!-- Accepted File Types --%>
                    <div class="fieldset">
                      <.label>{gettext("Accepted File Types")}</.label>
                      <textarea
                        name="field[accept]"
                        rows="3"
                        class="textarea"
                        placeholder=".pdf, .jpg, .png"
                        phx-debounce="300"
                      ><%= format_accept_list(@field_form["accept"]) %></textarea>
                      <.label class="label">
                        <span class="fieldset-label">
                          {gettext(
                            "Comma-separated list of extensions (e.g., .pdf, .jpg, .png, .step, .dwg)"
                          )}
                        </span>
                      </.label>
                    </div>
                  </div>
                <% end %>

                <%!-- Options (for choice fields) --%>
                <%= if requires_options?(@field_form["type"]) do %>
                  <div>
                    <div class="flex items-center justify-between mb-2">
                      <.label>{gettext("Options")} *</.label>
                      <button
                        type="button"
                        class="btn btn-sm btn-outline"
                        phx-click="add_option"
                      >
                        <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add Option")}
                      </button>
                    </div>

                    <div class="space-y-2">
                      <%= for {option, option_index} <- Enum.with_index(@field_form["options"] || []) do %>
                        <div class="flex gap-2">
                          <input
                            type="text"
                            name={"option[#{option_index}]"}
                            value={option}
                            class="input flex-1"
                            phx-change="update_option"
                            phx-value-index={option_index}
                            phx-debounce="300"
                            placeholder={gettext("Option value")}
                          />
                          <button
                            type="button"
                            class="btn btn-error btn-sm"
                            phx-click="remove_option"
                            phx-value-index={option_index}
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </div>
                      <% end %>
                    </div>

                    <%= if Enum.empty?(@field_form["options"] || []) do %>
                      <div class="text-center text-base-content/60 py-4">
                        {gettext("No options added yet. Click \"Add Option\" to get started.")}
                      </div>
                    <% end %>

                    <.label class="label cursor-pointer justify-start gap-2 mt-2">
                      <input type="hidden" name="field[allow_other]" value="false" />
                      <input
                        type="checkbox"
                        name="field[allow_other]"
                        class="toggle toggle-primary toggle-sm"
                        value="true"
                        checked={FieldTypes.allow_other?(@field_form)}
                      />
                      <span class="fieldset-legend">{gettext("Allow a custom \"Other\" option")}</span>
                    </.label>
                  </div>
                <% end %>

                <%!-- Modal Actions --%>
                <div class="modal-action">
                  <button
                    type="button"
                    class="btn btn-outline"
                    phx-click="cancel_field"
                  >
                    {gettext("Cancel")}
                  </button>
                  <button
                    type="submit"
                    class="btn btn-primary"
                  >
                    {if @editing_field_index, do: gettext("Update Field"), else: gettext("Add Field")}
                  </button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

        <%!-- Icon Picker Modal --%>
        <%= if @show_icon_picker do %>
          <div
            class="fixed inset-0 bg-base-content/50 z-50 flex items-center justify-center p-4"
            phx-click="close_icon_picker"
          >
            <div
              class="bg-base-100 rounded-lg shadow-xl max-w-4xl w-full max-h-[90vh] flex flex-col"
              phx-click="stop_propagation"
            >
              <%!-- Modal Header --%>
              <div class="flex items-center justify-between p-6 border-b border-base-300">
                <h2 class="text-2xl font-bold flex items-center gap-2">
                  <.icon name="hero-squares-2x2" class="w-6 h-6" /> {gettext("Select an Icon")}
                </h2>
                <button
                  type="button"
                  phx-click="close_icon_picker"
                  class="btn btn-ghost btn-sm btn-circle"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <%!-- Search Bar --%>
              <div class="p-4 border-b border-base-300">
                <.form
                  for={%{}}
                  id="entity-icon-search"
                  phx-change="search_icons"
                  phx-submit="search_icons"
                >
                  <div class="join w-full">
                    <input
                      type="text"
                      name="search"
                      value={@icon_search}
                      placeholder={gettext("Search icons...")}
                      class="input join-item flex-1"
                      phx-debounce="300"
                    />
                    <button type="submit" class="btn btn-primary join-item">
                      <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                    </button>
                  </div>
                </.form>
              </div>

              <%!-- Category Tabs --%>
              <div class="px-4 py-2 border-b border-base-300 overflow-x-auto">
                <%!-- Core's <.nav_tabs>, not hand-rolled markup: this strip
                     was one of the sites a daisyUI class rename had to touch
                     precisely because it restated the classes itself. The
                     payload key moves from `category` to the component's
                     standard `tab`. --%>
                <.nav_tabs
                  active_tab={@selected_category}
                  on_change="filter_by_category"
                  class="inline-flex"
                  tabs={
                    Enum.map(@icon_categories, fn category ->
                      %{id: category, label: icon_category_label(category)}
                    end)
                  }
                />
              </div>

              <%!-- Icon Grid --%>
              <div class="flex-1 overflow-y-auto p-6">
                <%= if Enum.empty?(@available_icons) do %>
                  <div class="text-center py-12">
                    <div class="text-4xl mb-4 opacity-50">🔍</div>
                    <p class="text-base-content/70">
                      {gettext("No icons found matching your search")}
                    </p>
                  </div>
                <% else %>
                  <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 gap-3">
                    <%= for {icon_name, display_name} <- @available_icons do %>
                      <button
                        type="button"
                        phx-click="select_icon"
                        phx-value-icon={icon_name}
                        class="btn btn-outline flex flex-col h-auto py-3 gap-1 hover:btn-primary min-h-0"
                        title={display_name}
                      >
                        <.icon name={icon_name} class="w-6 h-6 flex-shrink-0" />
                        <span class="text-xs leading-tight text-center break-words w-full">
                          {display_name}
                        </span>
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <%!-- Modal Footer --%>
              <div class="p-4 border-t border-base-300 bg-base-200">
                <div class="flex justify-between items-center text-sm text-base-content/70">
                  <span>
                    {ngettext(
                      "%{count} icon available",
                      "%{count} icons available",
                      length(@available_icons),
                      count: length(@available_icons)
                    )}
                  </span>
                  <button type="button" phx-click="close_icon_picker" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    """
  end
end
