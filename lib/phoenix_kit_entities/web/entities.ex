defmodule PhoenixKitEntities.Web.Entities do
  @moduledoc """
  LiveView for listing and managing all entities.
  Provides interface for viewing, publishing, and deleting entity schemas.
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
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities

  @impl true
  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    project_title = Settings.get_project_title()

    # Defer DB query to handle_params/3 — mount runs twice (HTTP + WebSocket),
    # handle_params runs once. See Phoenix iron law.
    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Entities"))
      |> assign(
        :page_subtitle,
        gettext("Create and manage custom content types with dynamic fields")
      )
      |> assign(:page_section, gettext("Modules"))
      |> assign(:page_section_path, Routes.path("/admin/modules"))
      |> assign(:project_title, project_title)
      |> assign(:view_mode, "table")
      |> assign(:entities, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    view_mode = Map.get(params, "view", "table")
    locale = socket.assigns[:current_locale]

    socket =
      socket
      |> assign(:view_mode, view_mode)
      |> assign(:entities, Entities.list_entities(lang: locale))

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    base_path = current_base_path(socket)
    query = if mode != "table", do: "?view=#{mode}", else: ""

    {:noreply, push_patch(socket, to: "#{base_path}#{query}")}
  end

  def handle_event("archive_entity", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      locale = socket.assigns[:current_locale]
      entity = Entities.get_entity!(uuid, lang: locale)

      case Entities.update_entity(entity, %{status: "archived"}, actor_opts(socket)) do
        {:ok, _entity} ->
          socket =
            socket
            |> assign(:entities, Entities.list_entities(lang: locale))
            |> put_flash(
              :info,
              gettext("Entity '%{name}' archived successfully", name: entity.display_name)
            )

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to archive entity"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("restore_entity", %{"uuid" => uuid}, socket) do
    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      locale = socket.assigns[:current_locale]
      entity = Entities.get_entity!(uuid, lang: locale)

      case Entities.update_entity(entity, %{status: "published"}, actor_opts(socket)) do
        {:ok, _entity} ->
          socket =
            socket
            |> assign(:entities, Entities.list_entities(lang: locale))
            |> put_flash(
              :info,
              gettext("Entity '%{name}' restored successfully", name: entity.display_name)
            )

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to restore entity"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
    end
  end

  def handle_event("reorder_entities", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    # `moved_id` rides along on the JS side — push it back as a
    # `sortable:flash` so the SortableGrid hook flashes the dropped
    # row green on success / red on failure. Matches the
    # `phoenix_kit_projects` reorder convention.
    moved_id = params["moved_id"]

    if Scope.can_access_admin_area?(socket.assigns.phoenix_kit_current_scope) do
      case Entities.reorder_entities(ordered_ids, actor_opts(socket)) do
        :ok ->
          {:noreply,
           socket
           |> assign(
             :entities,
             Entities.list_entities(lang: socket.assigns[:current_locale])
           )
           |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Failed to save the new order"))
           |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Not authorized"))
       |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})}
    end
  end

  # Defensive catch-all: a stale browser tab or a custom client could
  # push a malformed `reorder_entities` payload (missing `ordered_ids`
  # or wrong type). Flash + no-op rather than crash the LV socket
  # with a MatchError. No `sortable:flash` here — without a `moved_id`
  # the hook can't key the highlight to a row anyway.
  def handle_event("reorder_entities", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to save the new order"))}
  end

  ## Live updates

  @impl true
  def handle_info({event, _entity_uuid}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    {:noreply,
     assign(
       socket,
       :entities,
       Entities.list_entities(lang: socket.assigns[:current_locale])
     )}
  end

  # Catch-all — log at :debug rather than crashing the socket so unexpected
  # messages stay visible during development without producing noise in prod.
  def handle_info(message, socket) do
    Logger.debug(fn ->
      "Entities: unhandled handle_info — #{inspect(message)}"
    end)

    {:noreply, socket}
  end

  # Helper Functions

  # Threads the current user UUID through to context functions that
  # accept `actor_uuid:` opts.
  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # Extracts the base path (without query string) from the current URL,
  # which already includes the correct locale and prefix segments.
  defp current_base_path(socket) do
    (socket.assigns[:url_path] || "") |> URI.parse() |> Map.get(:path) || "/"
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Action Bar --%>
        <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-6 gap-4">
          <div>
            <h2 class="text-2xl font-semibold text-base-content">{gettext("All Entities")}</h2>
            <p class="text-base-content/70">
              {gettext("Manage custom content types and field definitions")}
            </p>
          </div>

          <div class="flex gap-2 items-center">
            <%!-- View Mode Toggle (hidden on small screens — cards are forced) --%>
            <div class="join hidden md:flex">
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

            <.link
              navigate={Routes.path("/admin/entities/new")}
              class="btn btn-primary"
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("New Entity")}
            </.link>
          </div>
        </div>

        <%!-- Entities Grid --%>
        <%= if Enum.empty?(@entities) do %>
          <.empty_state
            variant="featured"
            icon="hero-cube"
            title={gettext("No Entities Yet")}
            description={
              gettext(
                "Get started by creating your first custom content type. Think brands, products, team members, or any structured content you need."
              )
            }
          >
            <.link
              navigate={Routes.path("/admin/entities/new")}
              class="btn btn-primary btn-lg"
            >
              <.icon name="hero-plus" class="w-5 h-5 mr-2" /> {gettext("Create Your First Entity")}
            </.link>
          </.empty_state>
        <% else %>
          <%!-- Table View: hidden on small screens, shown on md+ when table mode selected --%>
          <%= if @view_mode == "table" do %>
            <div class="hidden md:block">
              <.table_default variant="zebra" size="sm">
                <.table_default_header>
                  <.table_default_row>
                    <.table_default_header_cell :if={length(@entities) > 1} class="w-8"></.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Entity")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Fields")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Created")}</.table_default_header_cell>
                    <.table_default_header_cell class="w-px whitespace-nowrap text-right">
                      {gettext("Actions")}
                    </.table_default_header_cell>
                  </.table_default_row>
                </.table_default_header>
                <tbody
                  id="entities-table-body"
                  data-sortable="true"
                  data-sortable-event="reorder_entities"
                  data-sortable-items=".sortable-item"
                  data-sortable-hide-source="false"
                  data-sortable-handle=".pk-drag-handle"
                  phx-hook="SortableGrid"
                >
                  <%= for entity <- @entities do %>
                    <.table_default_row class="sortable-item" data-id={entity.uuid}>
                      <.table_default_cell
                        :if={length(@entities) > 1}
                        class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/70 transition-colors"
                        title={gettext("Drag to reorder")}
                      >
                        <.icon name="hero-bars-3" class="w-4 h-4" />
                      </.table_default_cell>
                      <.table_default_cell>
                        <.link
                          navigate={
                            Routes.locale_aware_path(
                              assigns,
                              "/admin/entities/#{entity.name}/data"
                            )
                          }
                          class="flex items-center gap-3 hover:text-primary transition-colors cursor-pointer group"
                        >
                          <div class="text-2xl">
                            <%= if entity.icon do %>
                              <.icon name={entity.icon} class="w-6 h-6" />
                            <% else %>
                              <.icon name="hero-cube" class="w-6 h-6" />
                            <% end %>
                          </div>
                          <div>
                            <div class="font-bold flex items-center gap-2">
                              {entity.display_name_plural || entity.display_name}
                              <span
                                :if={owner = PhoenixKitEntities.Managed.owner(entity)}
                                class="badge badge-outline badge-sm font-normal"
                                title={gettext("Owned by the %{owner} module — its structural settings are locked", owner: owner)}
                              >
                                {gettext("Managed by %{owner}", owner: owner)}
                              </span>
                            </div>
                            <div class="text-sm opacity-50">
                              <.icon name="hero-link" class="w-3 h-3 inline" />
                              {entity.name}
                            </div>
                            <%= if entity.description do %>
                              <div class="text-xs opacity-50 line-clamp-1 mt-1">
                                {entity.description}
                              </div>
                            <% end %>
                          </div>
                        </.link>
                      </.table_default_cell>
                      <.table_default_cell>
                        <.status_badge status={entity.status} />
                      </.table_default_cell>
                      <.table_default_cell>
                        <div class="flex items-center gap-1">
                          <.icon name="hero-list-bullet" class="w-4 h-4" />
                          <span>
                            {length(entity.fields_definition || [])}
                          </span>
                        </div>
                      </.table_default_cell>
                      <.table_default_cell>
                        <span class="text-sm">
                          {PhoenixKit.Utils.Date.format_date_with_user_format(entity.date_created)}
                        </span>
                      </.table_default_cell>
                      <.table_default_cell class="text-right whitespace-nowrap">
                        <.table_row_menu mode="auto" id={"entity-menu-#{entity.uuid}"}>
                          <.table_row_menu_link
                            navigate={
                              Routes.locale_aware_path(
                                assigns,
                                "/admin/entities/#{entity.name}/data"
                              )
                            }
                            icon="hero-arrow-right"
                            label={gettext("Go to Data")}
                          />
                          <.table_row_menu_link
                            navigate={
                              Routes.path("/admin/entities/#{entity.uuid}/edit")
                            }
                            icon="hero-pencil"
                            label={gettext("Edit")}
                          />
                          <.table_row_menu_divider />
                          <%= if entity.status == "archived" do %>
                            <.table_row_menu_button
                              phx-click="restore_entity"
                              phx-value-uuid={entity.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-arrow-path"
                              label={gettext("Restore")}
                            />
                          <% else %>
                            <.table_row_menu_button
                              phx-click="archive_entity"
                              phx-value-uuid={entity.uuid}
                              phx-disable-with={gettext("…")}
                              icon="hero-trash"
                              label={gettext("Archive")}
                            />
                          <% end %>
                        </.table_row_menu>
                      </.table_default_cell>
                    </.table_default_row>
                  <% end %>
                </tbody>
              </.table_default>
            </div>
          <% end %>

          <%!-- Card View: always shown on small screens, shown on md+ when card mode selected --%>
          <div class={if @view_mode == "table", do: "md:hidden", else: ""}>
            <.draggable_list
              id="entities-cards"
              items={@entities}
              item_id={&(&1.uuid)}
              on_reorder="reorder_entities"
              draggable={length(@entities) > 1}
              sortable_handle=".pk-drag-handle"
              layout={:grid}
              cols={1}
              gap="gap-6"
              class="md:grid-cols-2 lg:grid-cols-3"
            >
              <:item :let={entity}>
                <div class="card bg-base-100 shadow-xl hover:shadow-2xl transition-shadow h-full group/card relative">
                  <%= if length(@entities) > 1 do %>
                    <div
                      class="pk-drag-handle absolute top-2 left-2 cursor-grab active:cursor-grabbing text-base-content/0 group-hover/card:text-base-content/50 transition-colors"
                      title={gettext("Drag to reorder")}
                    >
                      <.icon name="hero-bars-3" class="w-5 h-5" />
                    </div>
                  <% end %>
                  <div class="card-body">
                    <div class="flex items-start justify-between mb-4">
                      <.link
                        navigate={Routes.path("/admin/entities/#{entity.name}/data")}
                        class="flex items-center hover:text-primary transition-colors cursor-pointer group"
                      >
                        <div class="text-2xl mr-3">
                          <%= if entity.icon do %>
                            <.icon name={entity.icon} class="w-6 h-6" />
                          <% else %>
                            <.icon name="hero-cube" class="w-6 h-6" />
                          <% end %>
                        </div>
                        <div>
                          <h3 class="card-title text-lg">
                            {entity.display_name_plural || entity.display_name}
                          </h3>
                          <p class="text-sm opacity-50">
                            <.icon name="hero-link" class="w-3 h-3 inline" />
                            {entity.name}
                          </p>
                          <span
                            :if={owner = PhoenixKitEntities.Managed.owner(entity)}
                            class="badge badge-outline badge-sm font-normal mt-1"
                          >
                            {gettext("Managed by %{owner}", owner: owner)}
                          </span>
                        </div>
                      </.link>

                      <%!-- Status Badge --%>
                      <.status_badge status={entity.status} />
                    </div>

                    <%= if entity.description do %>
                      <p class="text-sm text-base-content/70 mb-4 line-clamp-2">
                        {entity.description}
                      </p>
                    <% end %>

                    <%!-- Field Count --%>
                    <div class="flex items-center justify-between text-sm text-base-content/60 mb-4">
                      <div class="flex items-center">
                        <.icon name="hero-list-bullet" class="w-4 h-4 mr-1" />
                        <span>
                          {ngettext(
                            "%{count} field",
                            "%{count} fields",
                            length(entity.fields_definition || [])
                          )}
                        </span>
                      </div>

                      <%= if entity.creator do %>
                        <span class="badge badge-outline badge-xs h-auto">
                          {gettext("by %{email}", email: entity.creator.email)}
                        </span>
                      <% end %>
                    </div>

                    <%!-- Actions --%>
                    <div class="card-actions justify-end">
                      <.table_row_menu mode="auto" id={"entity-card-menu-#{entity.uuid}"}>
                        <.table_row_menu_link
                          navigate={
                            Routes.path("/admin/entities/#{entity.name}/data")
                          }
                          icon="hero-arrow-right"
                          label={gettext("Go to Data")}
                        />
                        <.table_row_menu_link
                          navigate={
                            Routes.path("/admin/entities/#{entity.uuid}/edit")
                          }
                          icon="hero-pencil"
                          label={gettext("Edit")}
                        />
                        <.table_row_menu_divider />
                        <%= if entity.status == "archived" do %>
                          <.table_row_menu_button
                            phx-click="restore_entity"
                            phx-value-uuid={entity.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-arrow-path"
                            label={gettext("Restore")}
                          />
                        <% else %>
                          <.table_row_menu_button
                            phx-click="archive_entity"
                            phx-value-uuid={entity.uuid}
                            phx-disable-with={gettext("…")}
                            icon="hero-trash"
                            label={gettext("Archive")}
                          />
                        <% end %>
                      </.table_row_menu>
                    </div>

                    <%!-- Created Date --%>
                    <div class="text-xs text-base-content/50 mt-2 pt-2 border-t border-base-300">
                      {gettext("Created %{date}",
                        date: PhoenixKit.Utils.Date.format_date_with_user_format(entity.date_created)
                      )}
                    </div>
                  </div>
                </div>
              </:item>
            </.draggable_list>
          </div>
        <% end %>
      </div>
    """
  end
end
