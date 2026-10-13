defmodule PhoenixKitEntities.Web.DataShow do
  @moduledoc """
  Read-only page for one entity data record, at
  `/admin/entities/:entity_slug/data/:uuid`.

  The record's fields are laid out as labelled values — images as thumbnails,
  files as names, relations as the linked record's title — with `Edit` and
  `Back` buttons. It never writes, takes no editing lock and renders no
  form, so opening it cannot disturb someone editing the same record.

  Permission: core resolves an admin view's permission key from the module
  namespace (`PhoenixKitEntities.Web.*` -> `"entities"`), the same rule that
  gates `Web.DataForm`; nothing here re-checks it.
  """

  use PhoenixKitWeb, :live_view
  # Override the backend `use PhoenixKitWeb, :live_view` wires by default
  # (PhoenixKitWeb.Gettext, core's own). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext
  on_mount(PhoenixKitEntities.Web.Hooks)

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.HtmlSanitizer
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FormBuilder
  alias PhoenixKitEntities.Relations

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"entity_slug" => entity_slug, "uuid" => uuid} = params, _uri, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    entity = Entities.get_entity_by_name(entity_slug, lang: locale)
    record = EntityData.get!(uuid, lang: locale)

    if owns_record?(entity, record) do
      # Linked records can belong to other entities; their lifecycle events
      # must also refresh the displayed titles and visibility.
      if connected?(socket), do: Events.subscribe_to_all_data()

      {:noreply,
       socket
       |> assign(:current_locale, locale)
       |> assign(:page_title, record.title)
       |> assign(
         :page_subtitle,
         gettext("Record of the %{entity} entity", entity: entity.display_name)
       )
       |> assign(:page_section, gettext("Entities"))
       |> assign(
         :page_section_path,
         Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
       )
       |> assign(:page_crumbs, crumbs(entity, record, socket.assigns.current_locale_base))
       |> assign(:entity, entity)
       |> assign_record(record)}
    else
      {:noreply, redirect_to_owning_entity(socket, record)}
    end
  end

  @impl true
  def handle_info({:data_updated, entity_uuid, data_uuid}, socket) do
    cond do
      entity_uuid == socket.assigns.entity.uuid and data_uuid == socket.assigns.record.uuid ->
        case EntityData.get(data_uuid, lang: socket.assigns.current_locale) do
          nil ->
            {:noreply, socket}

          record ->
            {:noreply,
             socket
             |> assign(:page_title, record.title)
             |> assign(
               :page_crumbs,
               crumbs(socket.assigns.entity, record, socket.assigns.current_locale_base)
             )
             |> assign_record(record)}
        end

      linked_record?(socket, data_uuid) ->
        {:noreply, assign_record(socket, socket.assigns.record)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:data_deleted, entity_uuid, data_uuid}, socket) do
    if entity_uuid == socket.assigns.entity.uuid and data_uuid == socket.assigns.record.uuid do
      {:noreply,
       socket
       |> put_flash(:error, gettext("This record was removed in another session."))
       |> push_navigate(to: back_path(socket.assigns.entity, socket.assigns.current_locale_base))}
    else
      if linked_record?(socket, data_uuid),
        do: {:noreply, assign_record(socket, socket.assigns.record)},
        else: {:noreply, socket}
    end
  end

  # The blueprint changed: re-read it so the labels, option translations and
  # field list match, and re-resolve the relation labels against the record.
  def handle_info({:entity_updated, entity_uuid}, socket) do
    if entity_uuid == socket.assigns.entity.uuid do
      case Entities.get_entity(entity_uuid, lang: socket.assigns.current_locale) do
        nil ->
          {:noreply, socket}

        entity ->
          socket = assign(socket, :entity, entity)

          {:noreply,
           socket
           |> assign(
             :page_subtitle,
             gettext("Record of the %{entity} entity", entity: entity.display_name)
           )
           |> assign(
             :page_crumbs,
             crumbs(entity, socket.assigns.record, socket.assigns.current_locale_base)
           )
           |> assign_record(socket.assigns.record)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entity_deleted, entity_uuid}, socket) do
    if entity_uuid == socket.assigns.entity.uuid do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Entity was deleted in another session."))
       |> push_navigate(
         to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
       )}
    else
      {:noreply, socket}
    end
  end

  # Entity-definition and other lifecycle broadcasts reach every entities page
  # through `Web.Hooks`; this page has nothing to refresh for them.
  def handle_info(_message, socket), do: {:noreply, socket}

  # The record is loaded by uuid and the entity comes from the URL; a mismatch
  # would show the record against another blueprint's `fields_definition`.
  defp owns_record?(%{uuid: entity_uuid}, %EntityData{entity_uuid: entity_uuid}), do: true
  defp owns_record?(_entity, _record), do: false

  defp redirect_to_owning_entity(socket, record) do
    owner = Entities.get_entity!(record.entity_uuid)

    socket
    |> put_flash(:info, gettext("That record belongs to %{entity}.", entity: owner.display_name))
    |> push_navigate(
      to:
        Routes.path("/admin/entities/#{owner.name}/data/#{record.uuid}",
          locale: socket.assigns.current_locale_base
        )
    )
  end

  defp crumbs(entity, record, locale) do
    [
      %{
        label: entity.display_name_plural || entity.display_name,
        path: back_path(entity, locale)
      },
      %{label: record.title}
    ]
  end

  defp back_path(entity, locale),
    do: Routes.path("/admin/entities/#{entity.name}/data", locale: locale)

  defp assign_record(socket, record) do
    entity = socket.assigns.entity
    data = record.data || %{}

    link_labels =
      entity
      |> Relations.relation_fields()
      |> Enum.flat_map(&Relations.uuids(data[&1["key"]]))
      |> Relations.labels_for(lang: socket.assigns.current_locale)
      |> Map.reject(fn {_uuid, label} -> label.status == "trashed" end)

    socket
    |> assign(:record, record)
    |> assign(:link_labels, link_labels)
  end

  # Include hidden targets too, so restoring one makes its label reappear.
  defp linked_record?(socket, uuid) do
    socket.assigns.entity
    |> Relations.relation_fields()
    |> Enum.any?(&(uuid in Relations.uuids((socket.assigns.record.data || %{})[&1["key"]])))
  end

  # Splits the fields at each `heading`: a heading is not a label/value pair,
  # so it cannot sit inside the `<dl>`; each section gets its own list.
  defp sections(fields) do
    Enum.chunk_while(
      fields,
      {nil, []},
      fn
        %{"type" => "heading"} = heading, {nil, []} ->
          {:cont, {heading, []}}

        %{"type" => "heading"} = heading, {h, acc} ->
          {:cont, {h, Enum.reverse(acc)}, {heading, []}}

        field, {h, acc} ->
          {:cont, {h, [field | acc]}}
      end,
      fn
        {nil, []} -> {:cont, []}
        {h, acc} -> {:cont, {h, Enum.reverse(acc)}, {nil, []}}
      end
    )
  end

  defp field_label(field, locale), do: FormBuilder.translated_label(field, locale) || field["key"]

  defp media_ref?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp media_ref?(_), do: false

  defp http_url?(value) when is_binary(value), do: String.match?(value, ~r{\Ahttps?://}i)
  defp http_url?(_), do: false

  defp file_entries(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp file_entries(_), do: []

  defp status_badge_class("published"), do: "badge-success"
  defp status_badge_class("draft"), do: "badge-warning"
  defp status_badge_class("archived"), do: "badge-neutral"
  defp status_badge_class("trashed"), do: "badge-error"
  defp status_badge_class(_), do: "badge-outline"

  defp scalar_text(value) when is_binary(value), do: value
  defp scalar_text(value) when is_number(value) or is_atom(value), do: to_string(value)

  defp scalar_text(value) when is_list(value),
    do:
      value |> Enum.filter(&(is_binary(&1) or is_number(&1))) |> Enum.map_join(", ", &to_string/1)

  defp scalar_text(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex flex-col mx-auto px-4 py-6 max-w-4xl space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <span id="data-show-status" class={["badge", status_badge_class(@record.status)]}>
            {Relations.status_label(@record.status)}
          </span>
          <code :if={@record.slug} class="text-xs text-base-content/60">{@record.slug}</code>
        </div>
        <div class="flex gap-2">
          <.link id="data-show-back" navigate={back_path(@entity, @current_locale_base)} class="btn btn-ghost">
            <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
          </.link>
          <.link
            id="data-show-edit"
            navigate={Entities.admin_edit_path(@entity, @record, locale: @current_locale_base)}
            class="btn btn-primary"
          >
            <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit")}
          </.link>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-2xl break-words">{@record.title}</h2>

          <%= for {heading, fields} <- sections(@entity.fields_definition || []) do %>
            <h3 :if={heading} class="pt-4 pb-2 text-lg font-semibold">
              {field_label(heading, @current_locale)}
            </h3>
            <dl :if={fields != []} class="divide-y divide-base-200">
              <div
                :for={field <- fields}
                class="py-3 sm:grid sm:grid-cols-3 sm:gap-4"
                data-field={field["key"]}
              >
                <dt class="text-sm font-medium text-base-content/70">
                  {field_label(field, @current_locale)}
                </dt>
                <dd class="mt-1 sm:col-span-2 sm:mt-0 break-words">
                  <.field_value
                    field={field}
                    value={(@record.data || %{})[field["key"]]}
                    link_labels={@link_labels}
                    locale={@current_locale}
                  />
                </dd>
              </div>
            </dl>
          <% end %>
        </div>
      </div>

      <div class="text-xs text-base-content/60 flex flex-wrap gap-x-6 gap-y-1">
        <span :if={@record.date_created}>
          {gettext("Created")}: {UtilsDate.format_datetime_with_user_format(@record.date_created)}
        </span>
        <span :if={@record.date_updated}>
          {gettext("Updated")}: {UtilsDate.format_datetime_with_user_format(@record.date_updated)}
        </span>
      </div>
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:value, :any, default: nil)
  attr(:link_labels, :map, default: %{})
  attr(:locale, :string, default: nil)

  defp field_value(%{field: %{"type" => "boolean"}, value: value} = assigns)
       when not is_nil(value) do
    assigns = assign(assigns, :on?, value in [true, "true"])

    ~H"""
    <span class={["badge badge-sm", if(@on?, do: "badge-success", else: "badge-ghost")]}>
      {if @on?, do: gettext("Yes"), else: gettext("No")}
    </span>
    """
  end

  defp field_value(%{value: value} = assigns) when value in [nil, "", [], %{}] do
    ~H"""
    <span class="text-base-content/40">—</span>
    """
  end

  defp field_value(%{field: %{"type" => "rich_text"}} = assigns) do
    assigns = assign(assigns, :html, HtmlSanitizer.sanitize(scalar_text(assigns.value)))

    ~H"""
    <div class="prose prose-sm max-w-none">{Phoenix.HTML.raw(@html)}</div>
    """
  end

  defp field_value(%{field: %{"type" => type}} = assigns)
       when type in ["select", "radio", "checkbox"] do
    labels =
      assigns.value
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&FormBuilder.translated_option_label(assigns.field, &1, assigns.locale))

    assigns = assign(assigns, :labels, labels)

    ~H"""
    <span :if={@labels != []}>{Enum.join(@labels, ", ")}</span>
    <span :if={@labels == []} class="text-base-content/40">—</span>
    """
  end

  defp field_value(%{field: %{"type" => "textarea"}} = assigns) do
    ~H"""
    <p class="whitespace-pre-wrap">{scalar_text(@value)}</p>
    """
  end

  defp field_value(%{field: %{"type" => "url"}, value: value} = assigns) do
    assigns = assign(assigns, :linkable?, http_url?(value))

    ~H"""
    <a :if={@linkable?} href={@value} target="_blank" rel="noopener noreferrer" class="link link-primary">
      {@value}
    </a>
    <span :if={not @linkable?}>{scalar_text(@value)}</span>
    """
  end

  defp field_value(%{field: %{"type" => "image"}, value: value} = assigns) do
    assigns = assign(assigns, :media?, media_ref?(value))

    ~H"""
    <img
      :if={@media?}
      src={URLSigner.signed_url(@value, "thumbnail")}
      alt={field_label(@field, @locale)}
      class="w-24 h-24 object-cover rounded border border-base-content/10"
    />
    <span :if={not @media?} class="text-base-content/40">—</span>
    """
  end

  defp field_value(%{field: %{"type" => "video"}, value: value} = assigns) do
    assigns = assign(assigns, :media?, media_ref?(value))

    ~H"""
    <span :if={@media?} class="inline-flex items-center gap-2">
      <.icon name="hero-video-camera" class="w-5 h-5 text-base-content/60" /> {gettext("Video attached")}
    </span>
    <span :if={not @media?} class="text-base-content/40">—</span>
    """
  end

  defp field_value(%{field: %{"type" => "file"}} = assigns) do
    assigns = assign(assigns, :files, file_entries(assigns.value))

    ~H"""
    <ul :if={@files != []} class="space-y-1">
      <li :for={file <- @files} class="flex items-center gap-2 text-sm">
        <.icon name="hero-document" class="w-4 h-4 text-base-content/60" />
        <span class="truncate">{file["filename"] || gettext("Unknown file")}</span>
        <span :if={file["size"]} class="text-xs text-base-content/60">{Format.bytes(file["size"])}</span>
      </li>
    </ul>
    <span :if={@files == []} class="text-base-content/40">—</span>
    """
  end

  defp field_value(%{field: %{"type" => "relation"}} = assigns) do
    linked =
      assigns.value
      |> Relations.uuids()
      |> Enum.flat_map(fn uuid ->
        case assigns.link_labels[uuid] do
          nil -> []
          label -> [label]
        end
      end)

    assigns = assign(assigns, :linked, linked)

    ~H"""
    <ul :if={@linked != []} class="space-y-1">
      <li :for={link <- @linked} class="flex items-center gap-2">
        <span>{link.title}</span>
        <span :if={link.status != "published"} class="badge badge-ghost badge-sm">
          {Relations.status_label(link.status)}
        </span>
      </li>
    </ul>
    <span :if={@linked == []} class="text-base-content/40">—</span>
    """
  end

  defp field_value(assigns) do
    ~H"""
    <span>{scalar_text(@value)}</span>
    """
  end
end
