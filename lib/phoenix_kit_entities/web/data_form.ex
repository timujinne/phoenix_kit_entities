defmodule PhoenixKitEntities.Web.DataForm do
  @moduledoc """
  LiveView for creating and editing entity data records.
  Provides dynamic form interface based on entity schema definition.
  """

  use PhoenixKitWeb, :live_view
  # Override the backend `use PhoenixKitWeb, :live_view` wires by default
  # (PhoenixKitWeb.Gettext, core's own — unreachable from this package's
  # `mix gettext.extract`). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext
  on_mount(PhoenixKitEntities.Web.Hooks)

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FormBuilder
  alias PhoenixKitEntities.Presence
  alias PhoenixKitEntities.PresenceHelpers

  # Fields that should keep their primary-language DB column value on secondary tabs.
  @preserve_fields %{
    "title" => :title,
    "slug" => :slug,
    "status" => :status,
    "parent_uuid" => :parent_uuid
  }

  @impl true
  def mount(_params, _session, socket) do
    # Defer DB queries (entity load, data record load) and presence init to
    # handle_params/3 — mount runs twice (HTTP + WebSocket), handle_params
    # runs once. See Phoenix iron law.
    {:ok,
     assign(socket,
       show_media_selector: false,
       media_pick_target: nil,
       media_filter: :image,
       media_pick_generation: 0
     )}
  end

  @impl true
  def handle_params(%{"entity_slug" => entity_slug, "uuid" => uuid} = params, _uri, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    # Edit mode with slug.
    #
    # The entity is loaded with `:lang` — that only swaps display_name and
    # description for the admin chrome, leaving fields_definition intact.
    #
    # The RECORD is deliberately loaded WITHOUT `:lang`. `EntityData.get!/2`
    # with `:lang` runs `resolve_language/2`, which replaces the multilang
    # `data` JSONB with the single merged map for that locale — every other
    # language is dropped from the struct. This editor needs all of them: the
    # language tabs read `data[lang]["_title"]`, and the save path feeds
    # `merge_multilang_data/4` from this changeset, so a flattened `data` here
    # gets written back and erases every translation in the row.
    entity = Entities.get_entity_by_name(entity_slug, lang: locale)
    data_record = EntityData.get!(uuid)

    if owns_record?(entity, data_record) do
      changeset = EntityData.change(data_record)

      {:noreply, hydrate_data_form(socket, entity, data_record, changeset, locale)}
    else
      {:noreply, redirect_to_owning_entity(socket, data_record)}
    end
  end

  def handle_params(%{"entity_id" => entity_uuid, "id" => id} = params, _uri, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    # Edit mode with ID (backwards compat). Record loaded raw — see the
    # entity_slug clause above for why `:lang` must not touch it.
    entity = Entities.get_entity!(entity_uuid, lang: locale)
    data_record = EntityData.get!(id)

    if owns_record?(entity, data_record) do
      changeset = EntityData.change(data_record)

      {:noreply, hydrate_data_form(socket, entity, data_record, changeset, locale)}
    else
      {:noreply, redirect_to_owning_entity(socket, data_record)}
    end
  end

  def handle_params(%{"entity_slug" => entity_slug} = params, _uri, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    # Create mode with slug
    entity = Entities.get_entity_by_name(entity_slug, lang: locale)
    data_record = %EntityData{entity_uuid: entity.uuid}
    changeset = EntityData.change(data_record)

    {:noreply, hydrate_data_form(socket, entity, data_record, changeset, locale)}
  end

  def handle_params(%{"entity_id" => entity_uuid} = params, _uri, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    # Create mode with ID (backwards compat)
    entity = Entities.get_entity!(entity_uuid, lang: locale)
    data_record = %EntityData{entity_uuid: entity.uuid}
    changeset = EntityData.change(data_record)

    {:noreply, hydrate_data_form(socket, entity, data_record, changeset, locale)}
  end

  # The record is loaded by uuid, the entity comes from the URL, and until now
  # nothing tied the two together: `/admin/entities/<other>/data/<uuid>/edit`
  # happily rendered the record against a different blueprint's
  # `fields_definition`. That was merely wrong on screen while the form posted
  # the record's own `entity_uuid` back. It is not any more —
  # `client_writable_params/2` now sets `entity_uuid` from the URL entity, on
  # purpose, so that a crafted payload cannot re-parent a row. Which makes "the
  # server knows which entity this form is for" a claim the server has to
  # actually check: without this guard a plain Save on a mismatched URL moves
  # the record to the blueprint the URL named.
  defp owns_record?(%{uuid: entity_uuid}, %EntityData{entity_uuid: entity_uuid}), do: true
  defp owns_record?(_entity, _data_record), do: false

  # Send the admin to the same record under the blueprint it really belongs
  # to, rather than 404ing a uuid that plainly exists.
  defp redirect_to_owning_entity(socket, data_record) do
    owner = Entities.get_entity!(data_record.entity_uuid)

    socket
    |> put_flash(
      :info,
      gettext("That record belongs to %{entity}.", entity: owner.display_name)
    )
    |> push_navigate(
      to:
        Routes.path("/admin/entities/#{owner.name}/data/#{data_record.uuid}/edit",
          locale: socket.assigns.current_locale_base
        )
    )
  end

  defp hydrate_data_form(socket, entity, data_record, changeset, locale) do
    project_title = Settings.get_project_title()
    current_user = socket.assigns[:phoenix_kit_current_user]

    # The breadcrumb bar carries the page identity: "Entities / <Plural> /
    # Edit <Entity> · subtitle". Nothing in the body repeats it.
    {page_title, page_subtitle} =
      if data_record.uuid do
        {gettext("Edit %{entity}", entity: entity.display_name),
         gettext("Update data for the %{entity} entity", entity: entity.display_name)}
      else
        {gettext("Create New %{entity}", entity: entity.display_name),
         gettext("Add data for the %{entity} entity", entity: entity.display_name)}
      end

    page_crumbs = [
      %{
        label: entity.display_name_plural || entity.display_name,
        path: Routes.path("/admin/entities/#{entity.name}/data")
      }
    ]

    # For new records, set default status to "published" to avoid validation errors
    changeset =
      if is_nil(data_record.uuid) do
        Ecto.Changeset.put_change(changeset, :status, "published")
      else
        changeset
      end

    form_record_key =
      case data_record.uuid do
        nil -> {:new, entity.name}
        uuid -> uuid
      end

    live_source = ensure_live_source(socket)

    # Multilang state (driven by Languages module globally)
    multilang_enabled = multilang_enabled?()

    # Lazy re-key: if global primary changed since this record was saved,
    # restructure data around the new primary language.
    # Also seed _title into JSONB data for backwards compat.
    changeset =
      if multilang_enabled and data_record.uuid do
        changeset
        |> rekey_data_on_mount()
        |> seed_translatable_fields(data_record)
      else
        changeset
      end

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, page_title)
      |> assign(:page_subtitle, page_subtitle)
      |> assign(:page_section, gettext("Entities"))
      |> assign(:page_section_path, Routes.path("/admin/entities"))
      |> assign(:page_crumbs, page_crumbs)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:data_record, data_record)
      # Does the slug still follow the title? Server state — see
      # track_slug_ownership/3.
      |> assign(:slug_auto?, is_nil(data_record.uuid))
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)
      |> assign(:form_record_key, form_record_key)
      |> assign(:form_record_topic_key, normalize_record_key(form_record_key))
      |> assign(:live_source, live_source)
      |> assign(:has_unsaved_changes, false)
      |> assign_parent_options(entity, data_record, locale)
      |> mount_multilang()

    hydrate_data_presence(socket, entity, data_record, form_record_key, current_user)
  end

  # Build the parent-picker options for the current record. Excludes the
  # row itself and any of its descendants (selecting either would create
  # a cycle). Trashed rows are excluded — they can't meaningfully be a
  # parent in the active tree.
  #
  # Loads the entity's rows once and feeds both the depth-ordered tree
  # build and the descendant exclusion — `list_tree/2` +
  # `descendant_uuids/3` would each load the same set independently.
  defp assign_parent_options(socket, entity, data_record, locale) do
    rows = EntityData.list_by_entity(entity.uuid, lang: locale)
    tree = EntityData.tree_from_rows(rows)

    excluded_uuids =
      case data_record.uuid do
        nil -> []
        uuid -> [uuid | EntityData.descendant_uuids_from_rows(uuid, rows)]
      end

    options =
      tree
      |> Enum.reject(&(&1.record.uuid in excluded_uuids))
      |> Enum.map(fn %{record: r, depth: d} ->
        prefix = String.duplicate("— ", d)
        {prefix <> (r.title || ""), r.uuid}
      end)

    assign(socket, :parent_options, options)
  end

  defp hydrate_data_presence(socket, entity, data_record, form_record_key, current_user) do
    if connected?(socket) do
      Events.subscribe_to_entity_data(entity.uuid)
      Events.subscribe_to_data_form(entity.uuid, form_record_key)
      setup_data_editing(socket, data_record, current_user)
    else
      assign_no_lock(socket)
    end
  end

  defp setup_data_editing(socket, data_record, current_user) do
    if data_record.uuid do
      {:ok, _ref} =
        PresenceHelpers.track_editing_session(:data, data_record.uuid, socket, current_user)

      PresenceHelpers.subscribe_to_editing(:data, data_record.uuid)
      socket = assign_editing_role(socket, data_record.uuid)

      if socket.assigns.readonly?,
        do: load_spectator_state(socket, data_record.uuid),
        else: socket
    else
      assign_no_lock(socket)
    end
  end

  defp assign_no_lock(socket) do
    socket
    |> assign(:lock_owner?, true)
    |> assign(:readonly?, false)
  end

  defp assign_editing_role(socket, data_uuid) do
    current_user = socket.assigns[:current_user]

    case PresenceHelpers.get_editing_role(:data, data_uuid, socket.id, current_user.uuid) do
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

  defp load_spectator_state(socket, data_uuid) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(:data, data_uuid) do
      %{form_state: form_state} when not is_nil(form_state) ->
        # Apply owner's form state
        params = Map.get(form_state, :params) || Map.get(form_state, "params")

        if params do
          socket
          |> apply_remote_data_params(params)
          |> assign(:has_unsaved_changes, true)
        else
          socket
        end

      _ ->
        # No form state to sync
        socket
    end
  end

  @impl true
  def terminate(_reason, _socket) do
    :ok
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"phoenix_kit_entity_data" => data_params} = params, socket) do
    if socket.assigns[:lock_owner?] do
      socket
      |> track_slug_ownership(params, data_params)
      |> then(&do_validate(data_params, &1))
    else
      # Spectator - ignore local changes, wait for broadcasts
      {:noreply, socket}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "Entity data validate failed: #{Exception.message(e)} " <>
          "(entity_uuid=#{inspect(record_uuid_for_log(socket, :entity))} " <>
          "data_record_uuid=#{inspect(record_uuid_for_log(socket, :data_record))})\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, gettext("Validation error — your data is preserved."))}
  end

  def handle_event("save", %{"phoenix_kit_entity_data" => data_params}, socket) do
    if socket.assigns[:lock_owner?] do
      do_save(data_params, socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "Entity data save failed: #{Exception.message(e)} " <>
          "(entity_uuid=#{inspect(record_uuid_for_log(socket, :entity))} " <>
          "data_record_uuid=#{inspect(record_uuid_for_log(socket, :data_record))})\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Reload data record from database or reset to empty state
      {data_record, changeset} =
        if socket.assigns.data_record.uuid do
          # Reload from database
          reloaded_data = EntityData.get_data!(socket.assigns.data_record.uuid)
          {reloaded_data, EntityData.change(reloaded_data)}
        else
          # Reset to empty new data record
          empty_data = %EntityData{
            entity_uuid: socket.assigns.entity.uuid
          }

          changeset =
            empty_data
            |> EntityData.change()
            |> Ecto.Changeset.put_change(:status, "published")

          {empty_data, changeset}
        end

      socket =
        socket
        |> assign(:data_record, data_record)
        |> assign(:changeset, changeset)
        |> put_flash(:info, gettext("Changes reset to last saved state"))
        |> broadcast_data_form_state(extract_changeset_params(changeset))

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot reset - you are spectating"))}
    end
  end

  def handle_event("generate_slug", _params, socket) do
    if socket.assigns[:lock_owner?] do
      do_generate_slug(socket)
    else
      {:noreply, socket}
    end
  end

  # ── Media picker (2026-08-27: managed blueprints edit their values,
  # images included, right here — the owning modules dropped their own
  # editors). ONE page-level MediaSelectorModal shared by every media
  # field, reconfigured per click; the generation in its id remounts it
  # fresh each open so a previous open's search/page (possibly a
  # different type lock) can't present a wrong-empty library.

  def handle_event("pick_media_field", %{"key" => key, "type" => type}, socket) do
    # The field must exist on the blueprint with a matching media type —
    # the buttons only render for legal fields, but events are events.
    fields = socket.assigns.entity.fields_definition || []
    legal? = Enum.any?(fields, &(&1["key"] == key and &1["type"] == type))

    if legal? and type in ["image", "video"] and socket.assigns.lock_owner? do
      {:noreply,
       socket
       |> assign(:media_pick_target, key)
       |> assign(:media_filter, if(type == "video", do: :video, else: :image))
       |> update(:media_pick_generation, &(&1 + 1))
       |> assign(:show_media_selector, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_media_field", %{"key" => key}, socket) do
    fields = socket.assigns.entity.fields_definition || []

    if Enum.any?(fields, &(&1["key"] == key and &1["type"] in ["image", "video"])) and
         socket.assigns.lock_owner? do
      {:noreply, put_media_value(socket, key, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_media_selector", _params, socket) do
    {:noreply, assign(socket, show_media_selector: false, media_pick_target: nil)}
  end

  # Pulls the resource uuid off socket assigns for use in error log
  # context. Returns `nil` when the assign is missing or the underlying
  # struct hasn't been hydrated yet (e.g. an exception during the very
  # first validate before the entity is loaded).
  defp record_uuid_for_log(socket, key) do
    case socket.assigns[key] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # Writes the picked/cleared value into the changeset's data so the
  # hidden input re-renders with it — from there the ordinary form params
  # carry it through every validate and the save (see the FormBuilder
  # media block: a changeset-only value would be wiped by the next
  # keystroke).
  defp put_media_value(socket, key, value) do
    changeset = socket.assigns.changeset
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    lang = socket.assigns[:current_lang]

    data =
      if socket.assigns[:multilang_enabled] && is_binary(lang) do
        Map.update(data, lang, %{key => value}, &Map.put(&1 || %{}, key, value))
      else
        Map.put(data, key, value)
      end

    changeset = Ecto.Changeset.put_change(changeset, :data, data)
    assign(socket, :changeset, changeset)
  end

  # The parent picker is rendered as a raw <select>, so any changeset
  # error on :parent_uuid doesn't surface through <.input>'s built-in
  # error block. Pull the first error message manually for the template.
  defp parent_uuid_error(%Ecto.Changeset{action: action, errors: errors})
       when action in [:validate, :insert, :update] do
    case Keyword.get(errors, :parent_uuid) do
      {msg, opts} -> translate_validator_error({msg, opts})
      _ -> nil
    end
  end

  defp parent_uuid_error(_), do: nil

  defp translate_validator_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end

  # ── Validate/Save helpers (below all handle_event clauses to avoid grouping warnings) ──

  defp maybe_auto_generate_data_slug(data_params, _entity_uuid, record_uuid, _socket)
       when not is_nil(record_uuid),
       do: data_params

  defp maybe_auto_generate_data_slug(data_params, entity_uuid, record_uuid, socket) do
    current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
    previous_title = current_data.title || ""
    title = data_params["title"] || previous_title

    cond do
      # The user owns the slug now — the title stops driving it.
      not socket.assigns[:slug_auto?] ->
        data_params

      # Nothing to derive when the title is unchanged. With the title
      # field firing on EVERY keystroke, this is the difference between
      # a uniqueness query per character typed ANYWHERE in the form and
      # none at all (2026-08-28).
      title == previous_title and (data_params["slug"] || "") != "" ->
        data_params

      true ->
        Map.put(
          data_params,
          "slug",
          auto_generate_entity_slug(
            entity_uuid,
            record_uuid,
            title,
            socket.assigns[:primary_language]
          )
        )
    end
  end

  # Client-side echo of the slug while typing (SlugFromTitle in
  # priv/static/assets/phoenix_kit_entities.js). The round trip is what
  # made this feel laggy even at zero debounce — a slug is just text, and
  # the browser can write it immediately. The server still derives the
  # slug it stores; the hook stays quiet unless `data-slug-auto` says the
  # slug is still following the title, and for scripts it cannot romanize
  # (core's rule is locale-aware) it leaves the server's value alone.
  #
  # Dynamic attrs for the same reason as live_debounce/0: phx-hook and
  # data-* are not declared attributes of translatable_field.
  defp slug_mirror_attrs do
    %{"phx-hook" => "SlugFromTitle", "data-slug-target" => "#phoenix_kit_entity_data_slug"}
  end

  # The hook reads this rather than guessing from the field's contents.
  defp slug_auto_attrs(auto?), do: %{"data-slug-auto" => to_string(auto? == true)}

  # True when this record's owning blueprint (`@entity`) belongs to another
  # module AND the record already exists — its slug is the relation key
  # that module's write-path guard protects
  # (`Managed.validate_data_mutation/4`), but that guard only fires on
  # `EntityData.update/3`. On `/data/new` there is no slug to key on yet,
  # so locking the field there only prevented the FIRST slug from ever
  # being set (the disabled field's hidden mirror posts back "", and
  # `changeset/2` never derives a slug from the title): the record was
  # created with `slug: nil`. The UI locks the field here too so the guard
  # isn't the only thing stopping a silent change on an EXISTING record;
  # mirrors `managed_blueprint?/1` in entity_form.ex, which guards the
  # blueprint's own slug (and gates the same way on an existing `uuid`).
  defp managed_blueprint?(entity, %{uuid: uuid}) when not is_nil(uuid),
    do: PhoenixKitEntities.Managed.managed?(entity)

  defp managed_blueprint?(_entity, _new_record), do: false

  # Ownership of the slug is server state, deliberately NOT inferred from
  # the slug value the client posts back.
  #
  # It used to be "regenerate while the posted slug still equals what the
  # PREVIOUS title would generate". That reads fine and passes any test
  # that posts tidy, in-order params — but with the debounce gone the
  # client posts a slug it has not caught up on yet (the server is
  # already a keystroke or two further along), so the comparison failed,
  # the form decided the user had typed a custom slug, and the slug
  # froze after the first character. Only touching the slug field itself
  # ends auto mode now; emptying it starts it again, which is what the
  # field's own hint promises.
  defp track_slug_ownership(socket, params, data_params) do
    case params["_target"] do
      [_prefix, "slug"] ->
        assign(socket, :slug_auto?, String.trim(data_params["slug"] || "") == "")

      _ ->
        socket
    end
  end

  defp do_validate(data_params, socket) do
    entity_uuid = socket.assigns.entity.uuid
    record_uuid = socket.assigns.data_record.uuid

    # Resolve any `allow_other` "Muu" sentinel + companion free-text params
    # into the actual custom value before FormBuilder validates the data —
    # otherwise the sentinel would fail options validation and the typed
    # text would never reach storage.
    form_data =
      FormBuilder.merge_other_params(
        socket.assigns.entity.fields_definition || [],
        Map.get(data_params, "data", %{})
      )

    data_params =
      if socket.assigns.data_record.uuid,
        do: data_params,
        else: Map.put(data_params, "created_by_uuid", socket.assigns.current_user.uuid)

    data_params =
      maybe_auto_generate_data_slug(data_params, entity_uuid, record_uuid, socket)

    current_lang = socket.assigns[:current_lang]

    # Inject _title and _slug into form data so they flow through multilang merge
    form_data =
      form_data
      |> inject_db_field_into_data("title", data_params, current_lang, socket.assigns)
      |> inject_db_field_into_data("slug", data_params, current_lang, socket.assigns)

    # On secondary language tabs, preserve primary-language fields that aren't in the form
    data_params =
      preserve_primary_fields(
        data_params,
        socket.assigns.changeset,
        socket.assigns,
        @preserve_fields
      )

    case FormBuilder.validate_data(socket.assigns.entity, form_data, current_lang) do
      {:ok, validated_data} ->
        validated_data =
          validated_data
          |> inject_db_field_into_data("title", data_params, current_lang, socket.assigns)
          |> inject_db_field_into_data("slug", data_params, current_lang, socket.assigns)

        data_params = strip_lang_params(data_params)

        final_data =
          merge_multilang_data(
            socket.assigns.changeset,
            merge_lang(socket, current_lang),
            validated_data,
            socket.assigns
          )

        params = Map.put(data_params, "data", final_data)

        changeset =
          socket.assigns.data_record
          |> EntityData.change(params)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> broadcast_data_form_state(params)

        {:noreply, socket}

      {:error, errors} ->
        # Preserve full multilang data in both changeset and broadcast
        error_data =
          merge_multilang_data(
            socket.assigns.changeset,
            merge_lang(socket, current_lang),
            form_data,
            socket.assigns
          )

        data_params =
          data_params
          |> Map.delete("lang_title")
          |> Map.delete("lang_slug")

        error_params = Map.put(data_params, "data", error_data)

        changeset =
          socket.assigns.data_record
          |> EntityData.change(error_params)
          |> add_form_errors(errors)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> broadcast_data_form_state(error_params)

        {:noreply, socket}
    end
  end

  defp do_save(data_params, socket) do
    # Extract the data field from params, resolving any `allow_other` "Muu"
    # sentinel + companion free-text params into the actual custom value
    # (see do_validate/2 for why this must happen before FormBuilder
    # validates the data).
    form_data =
      FormBuilder.merge_other_params(
        socket.assigns.entity.fields_definition || [],
        Map.get(data_params, "data", %{})
      )

    current_lang = socket.assigns[:current_lang]

    # Inject _title and _slug into form data so they flow through multilang merge
    form_data =
      form_data
      |> inject_db_field_into_data("title", data_params, current_lang, socket.assigns)
      |> inject_db_field_into_data("slug", data_params, current_lang, socket.assigns)

    # On secondary language tabs, preserve primary-language fields that aren't in the form
    data_params =
      preserve_primary_fields(
        data_params,
        socket.assigns.changeset,
        socket.assigns,
        @preserve_fields
      )

    # Validate the form data against entity field definitions
    case FormBuilder.validate_data(socket.assigns.entity, form_data, current_lang) do
      {:ok, validated_data} ->
        validated_data =
          validated_data
          |> inject_db_field_into_data("title", data_params, current_lang, socket.assigns)
          |> inject_db_field_into_data("slug", data_params, current_lang, socket.assigns)

        data_params = strip_lang_params(data_params)

        final_data =
          merge_multilang_data(
            socket.assigns.changeset,
            merge_lang(socket, current_lang),
            validated_data,
            socket.assigns
          )

        params =
          data_params
          |> client_writable_params(socket.assigns.entity.uuid)
          |> Map.put("data", final_data)
          |> maybe_add_creator_uuid(socket.assigns.current_user, socket.assigns.data_record)

        case save_data_record(socket, params) do
          {:ok, saved_record} ->
            {:noreply, handle_data_save_success(socket, saved_record, params)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket |> assign(:changeset, changeset) |> broadcast_data_form_state(params)}

          # The managed-blueprint write guard refuses a slug change with an
          # atom, not a changeset (`Managed.validate_data_mutation/4`) —
          # without this clause it fell through to a CaseClauseError instead
          # of a flash (same shape as entity_form.ex's own managed-blueprint
          # refusal handling).
          #
          # MINOR-2 (2026-09-11 review): the rejected slug used to stay in
          # `socket.assigns.changeset` — the disabled field's hidden mirror
          # would then resubmit it on every subsequent save, refusing the
          # form forever and making this very flash's advice ("revert that
          # change to save") unactionable, since nothing in the UI can
          # revert a disabled field. Rebuilding the changeset from the
          # persisted record clears the rejected value, so the next save
          # goes through.
          {:error, :locked_key} ->
            {:noreply,
             socket
             |> assign(:changeset, EntityData.change(socket.assigns.data_record))
             |> put_flash(
               :error,
               gettext(
                 "This record's slug is locked by its owning module — revert that change to save."
               )
             )}
        end

      {:error, errors} ->
        # Preserve full multilang data in both changeset and broadcast
        error_data =
          merge_multilang_data(
            socket.assigns.changeset,
            merge_lang(socket, current_lang),
            form_data,
            socket.assigns
          )

        data_params =
          data_params
          |> Map.delete("lang_title")
          |> Map.delete("lang_slug")

        error_params = Map.put(data_params, "data", error_data)

        changeset =
          socket.assigns.data_record
          |> EntityData.change(error_params)
          |> add_form_errors(errors)
          # `EntityData.change/2` never touches repo.insert/update, so this
          # changeset arrives with `action: nil` — and `<.input>` gates error
          # display on `changeset.action != nil`. Every per-field error
          # add_form_errors/2 just attached was invisible, leaving the user
          # only the concatenated flash below. The `validate` handler above
          # already does this; the save path was the outlier.
          |> Map.put(:action, :validate)

        error_list =
          Enum.map_join(errors, "; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(
            :error,
            gettext("Field validation errors: %{errors}", errors: error_list)
          )
          |> broadcast_data_form_state(error_params)

        {:noreply, socket}
    end
  end

  defp handle_data_save_success(socket, saved_record, params) do
    if socket.assigns.data_record.uuid do
      changeset = EntityData.change(saved_record)

      socket
      |> assign(:data_record, saved_record)
      |> assign(:changeset, changeset)
      |> put_flash(:info, gettext("Data record saved successfully"))
      |> broadcast_data_form_state(params)
    else
      entity_name = socket.assigns.entity.name

      socket
      |> put_flash(:info, gettext("Data record created successfully"))
      |> push_navigate(
        to:
          Routes.path(
            "/admin/entities/#{entity_name}/data/#{saved_record.uuid}/edit",
            locale: socket.assigns.current_locale_base
          )
      )
    end
  end

  ## Live updates

  def handle_info({:media_selected, [file_uuid | _]}, socket) do
    case socket.assigns.media_pick_target do
      key when is_binary(key) ->
        {:noreply,
         socket
         |> assign(show_media_selector: false, media_pick_target: nil)
         |> put_media_value(key, file_uuid)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:media_selected, _}, socket), do: {:noreply, socket}

  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, show_media_selector: false, media_pick_target: nil)}
  end

  @impl true
  def handle_info({:data_form_change, entity_uuid, record_key, payload, source}, socket) do
    cond do
      source == socket.assigns.live_source ->
        {:noreply, socket}

      entity_uuid != socket.assigns.entity.uuid ->
        {:noreply, socket}

      normalize_record_key(record_key) != socket.assigns.form_record_topic_key ->
        {:noreply, socket}

      true ->
        params = Map.get(payload, :params) || Map.get(payload, "params") || %{}

        socket =
          socket
          |> apply_remote_data_params(params)

        {:noreply, socket}
    end
  end

  def handle_info({:data_updated, entity_uuid, data_uuid}, socket) do
    cond do
      entity_uuid != socket.assigns.entity.uuid ->
        {:noreply, socket}

      socket.assigns.data_record.uuid != data_uuid ->
        {:noreply, socket}

      # Ignore our own saves — the save handler already refreshes state
      socket.assigns[:lock_owner?] ->
        {:noreply, socket}

      true ->
        # Raw, no `:lang` — this changeset is what the next save writes back,
        # so it has to keep every language. See handle_params/3.
        data_record = EntityData.get_data!(data_uuid)
        changeset = EntityData.change(data_record)

        socket =
          socket
          |> assign(:data_record, data_record)
          |> assign(:form_record_key, data_record.uuid)
          |> assign(:form_record_topic_key, normalize_record_key(data_record.uuid))
          |> assign(:changeset, changeset)
          |> put_flash(
            :info,
            gettext("Record updated in another session. Showing latest changes.")
          )

        {:noreply, socket}
    end
  end

  def handle_info({:data_deleted, entity_uuid, data_uuid}, socket) do
    cond do
      entity_uuid != socket.assigns.entity.uuid ->
        {:noreply, socket}

      socket.assigns.data_record.uuid != data_uuid ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> put_flash(:error, gettext("This record was removed in another session."))
          |> push_navigate(
            to:
              Routes.path("/admin/entities/#{socket.assigns.entity.name}/data",
                locale: socket.assigns.current_locale_base
              )
          )

        {:noreply, socket}
    end
  end

  def handle_info({:entity_created, _}, socket), do: {:noreply, socket}

  def handle_info({:entity_updated, entity_uuid}, socket) do
    if entity_uuid == socket.assigns.entity.uuid do
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
        socket =
          socket
          |> refresh_entity_assignment(entity)
          |> put_flash(:info, gettext("Entity schema updated. Form revalidated."))

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entity_deleted, entity_uuid}, socket) do
    if entity_uuid == socket.assigns.entity.uuid do
      socket =
        socket
        |> put_flash(:error, gettext("Entity was deleted in another session."))
        |> push_navigate(
          to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Someone joined or left - check if our role changed
    if socket.assigns.data_record && socket.assigns.data_record.uuid do
      data_uuid = socket.assigns.data_record.uuid
      was_owner = socket.assigns[:lock_owner?]

      # Re-evaluate our role
      socket = assign_editing_role(socket, data_uuid)

      # If we were promoted from spectator to owner, reload fresh data
      if !was_owner && socket.assigns[:lock_owner?] do
        data_record = EntityData.get_data!(data_uuid)

        socket
        |> assign(:data_record, data_record)
        |> assign(:changeset, EntityData.change(data_record))
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
      "DataForm: unhandled handle_info — #{inspect(message)}"
    end)

    {:noreply, socket}
  end

  # The language key submitted values get merged under.
  #
  # With multilang enabled this is just the active tab. With multilang
  # disabled `current_lang` is nil — but the row can still carry multilang
  # `data` (languages were configured once and later switched off), and
  # `merge_multilang_data/4` keeps honouring that structure rather than
  # flattening it. Merging under a nil key there would write a `null`
  # language into the JSONB, so fall back to the row's embedded primary.
  #
  # Flat rows have no `_primary_language`, so this stays nil for them and
  # `merge_multilang_data/4` passes the params straight through as before.
  defp merge_lang(_socket, current_lang) when is_binary(current_lang), do: current_lang

  defp merge_lang(socket, _current_lang) do
    case Ecto.Changeset.get_field(socket.assigns.changeset, :data) do
      %{"_primary_language" => primary} when is_binary(primary) -> primary
      _ -> nil
    end
  end

  # The read side of `merge_lang/2`, for the single-language layout.
  #
  # That layout renders its fields with `lang_code: nil`, so FormBuilder
  # reads `data["field_key"]` straight off the changeset. A row carrying
  # multilang `data` keeps its values one level down (`data[primary]`),
  # so every custom field would render blank — and the save writes that
  # blank form back over the primary language, which is the same data
  # loss `merge_lang/2` guards the write side against. Hand the fields a
  # flattened primary-language view to read; names are unchanged, so the
  # submitted params still round-trip back under the primary key.
  #
  # Flat rows are returned untouched.
  defp primary_language_view(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset} = form) do
    data = Ecto.Changeset.get_field(changeset, :data)

    if Multilang.multilang_data?(data) do
      flattened = Multilang.get_primary_data(data)
      %{form | source: Ecto.Changeset.put_change(changeset, :data, flattened)}
    else
      form
    end
  end

  defp primary_language_view(form), do: form

  # Strip lang_title/lang_slug from params — these are translation input names
  # that shouldn't be passed to the changeset as DB fields.
  defp strip_lang_params(params) do
    params
    |> Map.delete("lang_title")
    |> Map.delete("lang_slug")
  end

  # ── Lazy re-keying helpers (primary language change) ────────

  # Re-keys JSONB data in changeset if embedded primary != global primary.
  defp rekey_data_on_mount(changeset) do
    current_data = Ecto.Changeset.get_field(changeset, :data)
    rekeyed = Multilang.maybe_rekey_data(current_data)

    if rekeyed != current_data do
      Ecto.Changeset.put_change(changeset, :data, rekeyed)
    else
      changeset
    end
  end

  # Seeds `_title` and `_slug` into the JSONB data column for existing records on mount.
  # Handles backwards compat: migrates from metadata["translations"] to data[lang]["_title"].
  defp seed_translatable_fields(changeset, data_record) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}

    if Multilang.multilang_data?(data) do
      primary = data["_primary_language"]
      primary_data = Map.get(data, primary, %{})

      changeset =
        if Map.has_key?(primary_data, "_title") do
          changeset
        else
          title = Ecto.Changeset.get_field(changeset, :title)
          do_seed_title(changeset, data, data_record, primary, primary_data, title)
        end

      # Also seed _slug if not already present
      seed_slug_in_data(changeset)
    else
      changeset
    end
  end

  defp seed_slug_in_data(changeset) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    primary = data["_primary_language"]
    primary_data = Map.get(data, primary, %{})

    if Map.has_key?(primary_data, "_slug") do
      changeset
    else
      slug = Ecto.Changeset.get_field(changeset, :slug)

      if is_binary(slug) and slug != "" do
        updated_primary = Map.put(primary_data, "_slug", slug)
        data = Map.put(data, primary, updated_primary)
        Ecto.Changeset.put_change(changeset, :data, data)
      else
        changeset
      end
    end
  end

  defp do_seed_title(changeset, data, data_record, primary, primary_data, title) do
    # Seed primary _title from the title column
    updated_primary = Map.put(primary_data, "_title", title || "")
    data = Map.put(data, primary, updated_primary)

    # Migrate secondary titles from metadata["translations"]
    metadata = Ecto.Changeset.get_field(changeset, :metadata) || %{}
    {data, metadata} = migrate_title_translations(data, metadata, title)

    changeset = Ecto.Changeset.put_change(changeset, :data, data)

    # Update title column if primary was rekeyed
    changeset = maybe_sync_rekeyed_title(changeset, data, data_record, primary, title)

    if metadata != (Ecto.Changeset.get_field(changeset, :metadata) || %{}) do
      Ecto.Changeset.put_change(changeset, :metadata, metadata)
    else
      changeset
    end
  end

  defp migrate_title_translations(data, metadata, primary_title) do
    translations = metadata["translations"] || %{}

    Enum.reduce(translations, {data, metadata}, fn
      {lang_code, %{"title" => lang_title}}, {d, m}
      when is_binary(lang_title) and lang_title != "" ->
        d = put_secondary_title(d, lang_code, lang_title, primary_title)
        m = clean_title_translation(m, lang_code)
        {d, m}

      _, acc ->
        acc
    end)
  end

  defp put_secondary_title(data, _lang_code, lang_title, primary_title)
       when lang_title == primary_title,
       do: data

  defp put_secondary_title(data, lang_code, lang_title, _primary_title) do
    lang_data = Map.get(data, lang_code, %{})
    Map.put(data, lang_code, Map.put(lang_data, "_title", lang_title))
  end

  defp clean_title_translation(metadata, lang_code) do
    cleaned = metadata |> Map.get("translations", %{}) |> Map.delete(lang_code)

    if map_size(cleaned) == 0,
      do: Map.delete(metadata, "translations"),
      else: Map.put(metadata, "translations", cleaned)
  end

  defp maybe_sync_rekeyed_title(changeset, data, data_record, primary, title) do
    old_embedded = get_in(data_record.data || %{}, ["_primary_language"])

    if old_embedded && old_embedded != primary do
      new_title = get_in(data, [primary, "_title"])

      if is_binary(new_title) and new_title != "" and new_title != title do
        Ecto.Changeset.put_change(changeset, :title, new_title)
      else
        changeset
      end
    else
      changeset
    end
  end

  # Helper Functions

  # MINOR-1 (2026-09-11 review): the Generate button is hidden via `:if`
  # on a managed record, but a LiveView event is not bound by the markup
  # that produced it — the same reasoning `client_writable_params/2`
  # gives for forcing `entity_uuid` server-side. Gated here (not just in
  # the `generate_slug` event clause) so every path into this function is
  # covered. Without this, a forged `generate_slug` event rewrites the
  # hidden slug mirror while the visible field stays disabled and
  # Generate stays gone — nothing in the UI can put it back.
  defp do_generate_slug(socket) do
    if managed_blueprint?(socket.assigns.entity, socket.assigns.data_record) do
      {:noreply, socket}
    else
      changeset = socket.assigns.changeset
      current_lang = socket.assigns[:current_lang]
      primary = socket.assigns[:primary_language]
      is_secondary = socket.assigns[:multilang_enabled] && current_lang != primary
      title = slug_source_title(changeset, is_secondary, current_lang)

      if title == "" do
        {:noreply, socket}
      else
        {params, changeset} = build_slug_params(socket, title, is_secondary, current_lang)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> broadcast_data_form_state(params)

        {:noreply, socket}
      end
    end
  end

  defp slug_source_title(changeset, true = _secondary, current_lang) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}

    case Multilang.get_language_data(data, current_lang) do
      %{"_title" => lang_title} when is_binary(lang_title) and lang_title != "" -> lang_title
      _ -> Ecto.Changeset.get_field(changeset, :title) || ""
    end
  end

  defp slug_source_title(changeset, _primary, _current_lang) do
    Ecto.Changeset.get_field(changeset, :title) || ""
  end

  defp build_slug_params(socket, title, is_secondary, current_lang) do
    changeset = socket.assigns.changeset
    db_entity_uuid = Ecto.Changeset.get_field(changeset, :entity_uuid)
    db_title = Ecto.Changeset.get_field(changeset, :title) || ""
    status = Ecto.Changeset.get_field(changeset, :status) || "draft"
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    created_by_uuid = Ecto.Changeset.get_field(changeset, :created_by_uuid)

    {slug, data} =
      compute_slug_and_data(socket, title, is_secondary, current_lang, changeset, data)

    params = %{
      "entity_uuid" => db_entity_uuid,
      "title" => db_title,
      "slug" => slug,
      "status" => status,
      "data" => data,
      "created_by_uuid" => created_by_uuid
    }

    changeset =
      socket.assigns.data_record
      |> EntityData.change(params)
      |> Map.put(:action, :validate)

    {params, changeset}
  end

  defp compute_slug_and_data(socket, title, true = _secondary, current_lang, changeset, data) do
    entity_uuid = socket.assigns.entity.uuid
    record_uuid = socket.assigns.data_record.uuid

    # current_lang is the language this title is IN, and core 2.0's Slug is
    # locale-aware (it delegates to `locale_slug`): German expands "ö"/"ß" to
    # "oe"/"ss" while Estonian folds them to "o"/"s", and one table cannot do
    # both. `Slug.slugify("Größe Fußball", locale: "de")` => "groesse-fussball";
    # with locale: "et" it is "grosse-fussball". The parameter was being
    # discarded here.
    #
    # `transliterate: true` is redundant under core 2.0 — romanization is always
    # on and the option is accepted-and-ignored for source compatibility — but
    # kept so the call reads the same as every other slug site in the umbrella.
    slug_text =
      title
      |> Slug.slugify(locale: current_lang, transliterate: true)
      |> Slug.ensure_unique(
        &EntityData.secondary_slug_exists?(entity_uuid, current_lang, &1, record_uuid)
      )

    lang_data = Multilang.get_raw_language_data(data, current_lang)
    updated_lang = Map.put(lang_data, "_slug", slug_text)
    updated_data = Multilang.put_language_data(data, current_lang, updated_lang)
    {Ecto.Changeset.get_field(changeset, :slug), updated_data}
  end

  defp compute_slug_and_data(socket, title, _primary, _current_lang, _changeset, data) do
    entity_uuid = socket.assigns.entity.uuid
    record_uuid = socket.assigns.data_record.uuid

    slug_text =
      auto_generate_entity_slug(
        entity_uuid,
        record_uuid,
        title,
        socket.assigns[:primary_language]
      )

    {slug_text, data}
  end

  defp broadcast_data_form_state(socket, params) when is_map(params) do
    socket =
      if connected?(socket) &&
           socket.assigns[:form_record_key] &&
           socket.assigns[:entity] &&
           socket.assigns.data_record.uuid &&
           socket.assigns[:lock_owner?] do
        data_uuid = socket.assigns.data_record.uuid
        topic = PresenceHelpers.editing_topic(:data, data_uuid)

        payload = %{params: params}

        # Update Presence metadata with form state (for spectators to sync)
        Presence.update(self(), topic, socket.id, fn meta ->
          Map.put(meta, :form_state, payload)
        end)

        # Also broadcast for real-time sync to spectators
        Events.broadcast_data_form_change(
          socket.assigns.entity.uuid,
          socket.assigns.form_record_key,
          payload,
          source: socket.assigns.live_source
        )

        socket
      else
        socket
      end

    # Mark that we have unsaved changes
    assign(socket, :has_unsaved_changes, true)
  end

  defp apply_remote_data_params(socket, params) when is_map(params) do
    # Build the changeset WITHOUT enforcing validations yet
    # This ensures we capture the exact remote state, even invalid values
    changeset =
      socket.assigns.data_record
      |> Ecto.Changeset.cast(params, [
        :entity_uuid,
        :title,
        :slug,
        :status,
        :data,
        :metadata,
        :created_by_uuid
      ])
      |> Map.put(:action, :validate)

    # Apply changes to get the updated record with remote values
    updated_record = Ecto.Changeset.apply_changes(changeset)

    # Now create a validated changeset for display
    # This will show validation errors but preserve the remote values
    validated_changeset = EntityData.change(updated_record)

    socket
    |> assign(:data_record, updated_record)
    |> assign(:changeset, validated_changeset)
    |> assign(:has_unsaved_changes, true)
  end

  defp refresh_entity_assignment(socket, entity) do
    params = extract_changeset_params(socket.assigns.changeset)

    data_record = %{
      socket.assigns.data_record
      | entity: entity,
        entity_uuid: entity.uuid
    }

    changeset =
      data_record
      |> EntityData.change(params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:entity, entity)
    |> assign(:data_record, data_record)
    |> assign(:changeset, changeset)
    |> refresh_multilang()
  end

  defp extract_changeset_params(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.take([:entity_uuid, :title, :slug, :status, :data, :metadata, :created_by_uuid])
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  # The fields this form actually renders. `data_params` is whatever the
  # client submitted under `phoenix_kit_entity_data`, and
  # `EntityData.changeset/2` casts rather more than that — `created_by_uuid`,
  # `date_created`, `metadata` and `position` are all castable and none has an
  # input. So a crafted `save` payload could forge authorship, back-date the
  # audit timestamp, or rewrite the `ip_address` / `user_agent` /
  # `security_warnings` metadata that a flagged public submission was stored
  # with. Admin access is required to reach this, but these are the columns
  # that exist to survive an admin.
  #
  # `data` is rebuilt server-side by the caller and the creator is applied by
  # `maybe_add_creator_uuid/3`, so neither belongs in the allowlist.
  #
  # `entity_uuid` is NOT in the list. It was, and that left the very hole this
  # function was written to close: the blueprint a record belongs to decides
  # its URL, its sitemap entry and which navigator it appears in, and
  # `changeset/2` casts it while `validate_entity_reference/1` checks only
  # that the target exists. A crafted save on
  # `/admin/entities/products/data/<uuid>/edit` naming another entity's uuid
  # re-parented the row — it vanished from one blueprint and appeared under
  # another. The form renders it as a hidden input, but a LiveView event is
  # not bound by the markup that produced it: the server knows which entity
  # this form is for, so the server sets it.
  #
  # `status` is filtered to what the select offers. `"trashed"` is a valid
  # status the form never shows, and writing it directly skips `trash/2`,
  # which is where `metadata["trashed_from_status"]` is stashed — so the row
  # would soft-delete without recording where it came from, log
  # `entity_data.updated` instead of `entity_data.trashed`, and later restore
  # to "draft" whatever it had been. The reverse (writing "published" onto a
  # trashed row) skips `restore_from_trash/2` the same way.
  defp client_writable_params(data_params, entity_uuid) do
    data_params
    |> Map.take(["title", "slug", "status", "parent_uuid"])
    |> filter_status()
    |> Map.put("entity_uuid", entity_uuid)
  end

  @client_settable_statuses ~w(draft published archived)

  defp filter_status(params) do
    case Map.fetch(params, "status") do
      {:ok, status} when status in @client_settable_statuses -> params
      {:ok, _other} -> Map.delete(params, "status")
      :error -> params
    end
  end

  defp save_data_record(socket, data_params) do
    opts = actor_opts(socket)

    if socket.assigns.data_record.uuid do
      EntityData.update(socket.assigns.data_record, data_params, opts)
    else
      EntityData.create(data_params, opts)
    end
  end

  # Threads the current user UUID through to context functions that
  # accept `actor_uuid:` opts.
  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp maybe_add_creator_uuid(params, current_user, data_record) do
    if data_record.uuid do
      # Editing existing record - don't change creator
      params
    else
      # Creating new record - set creator
      params
      |> Map.put("created_by_uuid", current_user.uuid)
    end
  end

  defp add_form_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field_key, field_errors}, acc ->
      Enum.reduce(field_errors, acc, fn error, inner_acc ->
        Ecto.Changeset.add_error(
          inner_acc,
          :data,
          gettext("%{key}: %{error}", key: field_key, error: error)
        )
      end)
    end)
  end

  defp ensure_live_source(socket) do
    socket.assigns[:live_source] ||
      (socket.id ||
         "entities-data-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false))
  end

  defp normalize_record_key({:new, key}) when is_atom(key), do: "new-#{Atom.to_string(key)}"
  defp normalize_record_key({:new, key}) when is_binary(key), do: "new-#{key}"
  defp normalize_record_key({:new, key}), do: "new-#{to_string(key)}"
  defp normalize_record_key(key) when is_integer(key), do: Integer.to_string(key)
  defp normalize_record_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_record_key(key) when is_binary(key), do: key
  defp normalize_record_key(key), do: to_string(key)

  # `debounce: "0"` for the title, passed as a DYNAMIC attr rather than a
  # literal one: `translatable_field` only gained the attribute in core
  # after this module's released pin, and a literal would fail the
  # compile gate until that release lands. An older core simply ignores
  # the extra assign and keeps its hardcoded 300ms — the same graceful
  # degradation the apply/3 guards give us on the data side.
  #
  # "0", not nil: phx-debounce CASCADES, and this form carries
  # phx-debounce="500". Omitting the attribute inherits that 500ms — the
  # opposite of live, and slower than the 300ms it replaced. Only an
  # explicit value on the input overrides an ancestor's.
  defp live_debounce, do: %{debounce: "0"}

  defp auto_generate_entity_slug(_entity_uuid, _record_uuid, title, _lang)
       when title in [nil, ""],
       do: ""

  # Primary-language slug. `lang` tunes core's romanization per language — see
  # the note in compute_slug_and_data/5.
  defp auto_generate_entity_slug(entity_uuid, current_record_uuid, title, lang) do
    title
    |> Slug.slugify(locale: lang, transliterate: true)
    |> Slug.ensure_unique(&slug_taken_by_other?(entity_uuid, &1, current_record_uuid))
  end

  defp slug_taken_by_other?(_entity_uuid, "", _current_record_uuid), do: false

  defp slug_taken_by_other?(entity_uuid, candidate, current_record_uuid) do
    case EntityData.get_by_slug(entity_uuid, candidate) do
      nil ->
        false

      %EntityData{uuid: uuid} ->
        is_nil(current_record_uuid) || uuid != current_record_uuid
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <%!-- Readonly Banner --%>
        <%= if @readonly? do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-eye" class="w-5 h-5" />
            <span>
              {gettext(
                "This record is currently being edited by another user. You are in view-only mode."
              )}
            </span>
          </div>
        <% end %>

        <%!-- Edit Mode Form --%>
        <.form
          :let={f}
          for={@changeset}
          id="entity-data-form"
          phx-change="validate"
          phx-debounce="500"
          phx-submit="save"
          class="space-y-8"
        >
          <div class="flex justify-end">
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@readonly?}
              phx-disable-with={gettext("Saving…")}
            >
              <%= if @data_record.uuid do %>
                {gettext("Update %{entity}", entity: @entity.display_name)}
              <% else %>
                {gettext("Create %{entity}", entity: @entity.display_name)}
              <% end %>
            </button>
          </div>

          <%= if @show_multilang_tabs do %>
            <%!-- Multilang: unified card with language tabs wrapping all content --%>
            <% lang_data = get_lang_data(@changeset, @current_lang, @multilang_enabled) %>
            <div class="card bg-base-100 shadow-xl">
              <.multilang_tabs
                multilang_enabled={@multilang_enabled}
                language_tabs={@language_tabs}
                current_lang={@current_lang}
              />

              <.multilang_fields_wrapper
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
              >
                <:skeleton>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-24"></div>
                      <div class="skeleton h-12 w-full"></div>
                    </div>
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-32"></div>
                      <div class="skeleton h-12 w-full"></div>
                      <div class="skeleton h-3 w-48"></div>
                    </div>
                  </div>
                  <div class="divider my-2"></div>
                  <div class="space-y-4">
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-24"></div>
                      <div class="skeleton h-12 w-full"></div>
                    </div>
                    <div class="space-y-2">
                      <div class="skeleton h-4 w-40"></div>
                      <div class="skeleton h-24 w-full"></div>
                    </div>
                  </div>
                </:skeleton>

                <div class="divider mx-6 my-0"></div>

                <%!-- Tab content: Title & Slug (translatable) --%>
                <div class="card-body pt-4 pb-4">
                  <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide mb-3">
                    <.icon name="hero-information-circle" class="w-4 h-4 inline -mt-0.5" />
                    {gettext("Basic Information")}
                  </h3>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <%!-- The slug beside this field is DERIVED from it, so
                          waiting 300ms for a typing pause reads as lag
                          rather than as typing (Max, 2026-08-28) — see
                          live_debounce/0 for why it is passed dynamically. --%>
                    <.translatable_field
                      field_name="title"
                      form_prefix="phoenix_kit_entity_data"
                      changeset={@changeset}
                      schema_field={:title}
                      multilang_enabled={@multilang_enabled}
                      current_lang={@current_lang}
                      primary_language={@primary_language}
                      lang_data={lang_data}
                      label={gettext("Title")}
                      placeholder={gettext("Enter a title for this record")}
                      required
                      disabled={@readonly?}
                      class="w-full"
                      {live_debounce()}
                      {slug_mirror_attrs()}
                    />

                    <.translatable_field
                      field_name="slug"
                      form_prefix="phoenix_kit_entity_data"
                      changeset={@changeset}
                      schema_field={:slug}
                      multilang_enabled={@multilang_enabled}
                      current_lang={@current_lang}
                      primary_language={@primary_language}
                      lang_data={lang_data}
                      label={gettext("Slug (URL-friendly identifier)")}
                      placeholder={gettext("auto-generated-slug")}
                      disabled={@readonly? or managed_blueprint?(@entity, @data_record)}
                      class="w-full"
                      pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
                      title={gettext("Use lowercase letters, numbers, and hyphens only.")}
                      hint={
                        if managed_blueprint?(@entity, @data_record),
                          do: gettext("Locked — the owning module keys on this slug"),
                          else: gettext("Leave empty to auto-generate from title")
                      }
                      secondary_hint={gettext("Leave empty to use the primary language slug")}
                      {slug_auto_attrs(@slug_auto?)}
                    >
                      <:label_extra>
                        <button
                          :if={not managed_blueprint?(@entity, @data_record)}
                          type="button"
                          class="btn btn-ghost btn-xs ml-2"
                          phx-click="generate_slug"
                          title={gettext("Generate from title")}
                          disabled={@readonly?}
                        >
                          <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Generate")}
                        </button>
                      </:label_extra>
                    </.translatable_field>
                    <%!-- A disabled input doesn't submit; keep the slug in the
                         params so validation (and the write-path guard) stays
                         whole. --%>
                    <input
                      :if={managed_blueprint?(@entity, @data_record)}
                      type="hidden"
                      name="phoenix_kit_entity_data[slug]"
                      value={Ecto.Changeset.get_field(@changeset, :slug) || ""}
                    />
                  </div>
                </div>

                <%= if @entity.fields_definition != nil and @entity.fields_definition != [] do %>
                  <div class="divider mx-6 my-0"></div>

                  <%!-- Tab content: Custom Fields (translatable) --%>
                  <div class="card-body pt-4">
                    <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide mb-3">
                      <.icon name="hero-list-bullet" class="w-4 h-4 inline -mt-0.5" />
                      {gettext("Custom Fields")}
                    </h3>

                    <%!-- Dynamic form fields generated by FormBuilder --%>
                    {PhoenixKitEntities.FormBuilder.build_fields(@entity, f,
                      wrapper_class: "mb-6",
                      disabled: @readonly?,
                      media_picker: not @readonly?,
                      lang_code: if(@multilang_enabled, do: @current_lang, else: nil)
                    )}
                  </div>
                <% end %>
              </.multilang_fields_wrapper>
            </div>

            <%!-- Record Settings (non-translatable, separate card) --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">
                  <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
                  {gettext("Record Settings")}
                </h2>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                  <%!-- Status --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_status">{gettext("Status")}</.label>
                    <label class="select w-full">
                      <select
                        name="phoenix_kit_entity_data[status]"
                        disabled={@readonly?}
                      >
                        <option
                          value="draft"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "draft"}
                        >
                          {gettext("Draft")}
                        </option>
                        <option
                          value="published"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "published"}
                        >
                          {gettext("Published")}
                        </option>
                        <option
                          value="archived"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}
                        >
                          {gettext("Archived")}
                        </option>
                      </select>
                    </label>
                  </div>

                  <%!-- Parent (optional, same-entity) --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_parent_uuid">{gettext("Parent")}</.label>
                    <label class="select w-full">
                      <select
                        id="phoenix_kit_entity_data_parent_uuid"
                        name="phoenix_kit_entity_data[parent_uuid]"
                        disabled={@readonly?}
                      >
                        <option value="" selected={
                          is_nil(Ecto.Changeset.get_field(@changeset, :parent_uuid))
                        }>
                          {gettext("— None (top level) —")}
                        </option>
                        <%= for {label, value} <- @parent_options do %>
                          <option
                            value={value}
                            selected={Ecto.Changeset.get_field(@changeset, :parent_uuid) == value}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </label>
                    <%= if (msg = parent_uuid_error(@changeset)) do %>
                      <p class="mt-1 text-sm text-error">{msg}</p>
                    <% end %>
                  </div>

                  <%!-- Entity Type (Read-only) --%>
                  <div>
                    <.label>{gettext("Entity Type")}</.label>
                    <div class="input w-full bg-base-200 flex items-center">
                      <%= if @entity.icon do %>
                        <.icon name={@entity.icon} class="w-4 h-4 mr-2" />
                      <% end %>
                      {@entity.display_name}
                    </div>
                    <input
                      type="hidden"
                      name="phoenix_kit_entity_data[entity_uuid]"
                      value={@entity.uuid}
                    />
                  </div>
                </div>
              </div>
            </div>
          <% else %>
            <%!-- Non-multilang: separate cards (original layout) --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-2xl mb-4">
                  <.icon name="hero-information-circle" class="w-6 h-6" />
                  {gettext("Basic Information")}
                </h2>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <%!-- Title --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_title">{gettext("Title")} *</.label>
                    <%!-- The hook attrs belong on THIS branch too. They were
                         only on the multilang one, so on a single-language
                         install — the default — the slug never derived itself
                         in the browser and fell back to a 300ms round trip.
                         Being raw inputs rather than <.translatable_field>,
                         these also work against the released core, which does
                         not yet forward :global attrs to its input. --%>
                    <input
                      type="text"
                      name="phoenix_kit_entity_data[title]"
                      id="phoenix_kit_entity_data_title"
                      value={Ecto.Changeset.get_field(@changeset, :title) || ""}
                      placeholder={gettext("Enter a title for this record")}
                      class="input w-full"
                      required
                      phx-debounce="0"
                      disabled={@readonly?}
                      {slug_mirror_attrs()}
                    />
                  </div>

                  <%!-- Slug with Generator --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_slug">
                      {gettext("Slug (URL-friendly identifier)")}
                      <button
                        :if={not managed_blueprint?(@entity, @data_record)}
                        type="button"
                        class="btn btn-ghost btn-xs ml-2"
                        phx-click="generate_slug"
                        title={gettext("Generate from title")}
                        disabled={@readonly?}
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Generate")}
                      </button>
                    </.label>
                    <input
                      type="text"
                      name="phoenix_kit_entity_data[slug]"
                      id="phoenix_kit_entity_data_slug"
                      value={Ecto.Changeset.get_field(@changeset, :slug) || ""}
                      placeholder={gettext("auto-generated-slug")}
                      class="input w-full"
                      pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
                      title={gettext("Use lowercase letters, numbers, and hyphens only.")}
                      phx-debounce="0"
                      disabled={@readonly? or managed_blueprint?(@entity, @data_record)}
                      {slug_auto_attrs(@slug_auto?)}
                    />
                    <%!-- A disabled input doesn't submit; keep the slug in the
                         params so validation (and the write-path guard) stays
                         whole. --%>
                    <input
                      :if={managed_blueprint?(@entity, @data_record)}
                      type="hidden"
                      name="phoenix_kit_entity_data[slug]"
                      value={Ecto.Changeset.get_field(@changeset, :slug) || ""}
                    />
                    <.label class="label">
                      <span class="fieldset-label">
                        <%= if managed_blueprint?(@entity, @data_record) do %>
                          {gettext("Locked — the owning module keys on this slug")}
                        <% else %>
                          {gettext("Leave empty to auto-generate from title")}
                        <% end %>
                      </span>
                    </.label>
                  </div>

                  <%!-- Status --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_status">{gettext("Status")}</.label>
                    <label class="select w-full">
                      <select
                        name="phoenix_kit_entity_data[status]"
                        disabled={@readonly?}
                      >
                        <option
                          value="draft"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "draft"}
                        >
                          {gettext("Draft")}
                        </option>
                        <option
                          value="published"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "published"}
                        >
                          {gettext("Published")}
                        </option>
                        <option
                          value="archived"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}
                        >
                          {gettext("Archived")}
                        </option>
                      </select>
                    </label>
                  </div>

                  <%!-- Parent (optional, same-entity) --%>
                  <div>
                    <.label for="phoenix_kit_entity_data_parent_uuid">{gettext("Parent")}</.label>
                    <label class="select w-full">
                      <select
                        id="phoenix_kit_entity_data_parent_uuid"
                        name="phoenix_kit_entity_data[parent_uuid]"
                        disabled={@readonly?}
                      >
                        <option value="" selected={
                          is_nil(Ecto.Changeset.get_field(@changeset, :parent_uuid))
                        }>
                          {gettext("— None (top level) —")}
                        </option>
                        <%= for {label, value} <- @parent_options do %>
                          <option
                            value={value}
                            selected={Ecto.Changeset.get_field(@changeset, :parent_uuid) == value}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </label>
                    <%= if (msg = parent_uuid_error(@changeset)) do %>
                      <p class="mt-1 text-sm text-error">{msg}</p>
                    <% end %>
                  </div>

                  <%!-- Entity Type (Read-only) --%>
                  <div>
                    <.label>{gettext("Entity Type")}</.label>
                    <div class="input w-full bg-base-200 flex items-center">
                      <%= if @entity.icon do %>
                        <.icon name={@entity.icon} class="w-4 h-4 mr-2" />
                      <% end %>
                      {@entity.display_name}
                    </div>
                    <input
                      type="hidden"
                      name="phoenix_kit_entity_data[entity_uuid]"
                      value={@entity.uuid}
                    />
                  </div>
                </div>
              </div>
            </div>

            <%= if @entity.fields_definition != nil and @entity.fields_definition != [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title text-2xl mb-4">
                    <.icon name="hero-list-bullet" class="w-6 h-6" /> {gettext("Custom Fields")}
                  </h2>

                  <%!-- Dynamic form fields generated by FormBuilder --%>
                  {PhoenixKitEntities.FormBuilder.build_fields(@entity, primary_language_view(f),
                    wrapper_class: "mb-6",
                    disabled: @readonly?,
                    lang_code: nil
                  )}
                </div>
              </div>
            <% end %>
          <% end %>

          <%!-- Form Actions --%>
          <div class="flex justify-between items-center">
            <div class="flex gap-2">
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin/entities/#{@entity.name}/data")}
                class="btn btn-outline"
              >
                {gettext("Cancel")}
              </.link>

              <button type="button" phx-click="reset" class="btn btn-warning" disabled={@readonly?}>
                <.icon name="hero-arrow-path" class="w-4 h-4" />
                {gettext("Reset Changes")}
              </button>
            </div>

            <button
              type="submit"
              class="btn btn-primary"
              disabled={@readonly?}
              phx-disable-with={gettext("Saving…")}
            >
              <.icon name="hero-check" class="w-4 h-4 mr-2" />
              <%= if @data_record.uuid do %>
                {gettext("Update %{entity}", entity: @entity.display_name)}
              <% else %>
                {gettext("Create %{entity}", entity: @entity.display_name)}
              <% end %>
            </button>
          </div>
        </.form>

        <.live_component
          :if={@show_media_selector}
          module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
          id={"data-form-media-selector-#{@media_filter}-g#{@media_pick_generation}"}
          show={@show_media_selector}
          mode={:single}
          file_type_filter={@media_filter}
          lock_file_type
          title={
            if @media_filter == :video,
              do: gettext("Select Video"),
              else: gettext("Select Image")
          }
          selected_uuids={[]}
          phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
        />
      </div>
    """
  end
end
