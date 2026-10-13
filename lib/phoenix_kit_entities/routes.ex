defmodule PhoenixKitEntities.Routes do
  @moduledoc """
  Route module for PhoenixKit Entities.

  Provides admin LiveView routes and public form submission endpoint.
  Called by PhoenixKit's integration via the `route_module/0` callback.

  Admin routes are registered via `admin_locale_routes/0` and `admin_routes/0`,
  which are called by `compile_external_admin_routes` in integration.ex.

  Public routes are registered via `generate/1`, called by
  `compile_module_public_routes` in integration.ex.
  """

  @doc """
  Admin LiveView routes for the localized scope.
  """
  @spec admin_locale_routes() :: Macro.t()
  def admin_locale_routes do
    quote do
      live("/admin/entities", PhoenixKitEntities.Web.Entities, :index, as: :entities_localized)

      live("/admin/entities/new", PhoenixKitEntities.Web.EntityForm, :new,
        as: :entities_new_localized
      )

      live("/admin/entities/:id/edit", PhoenixKitEntities.Web.EntityForm, :edit,
        as: :entities_edit_localized
      )

      live(
        "/admin/entities/:entity_slug/data",
        PhoenixKitEntities.Web.DataNavigator,
        :entity,
        as: :entities_data_entity_localized
      )

      live(
        "/admin/entities/:entity_slug/data/new",
        PhoenixKitEntities.Web.DataForm,
        :new,
        as: :entities_data_new_localized
      )

      live(
        "/admin/entities/:entity_slug/data/:uuid",
        PhoenixKitEntities.Web.DataShow,
        :show,
        as: :entities_data_show_localized
      )

      live(
        "/admin/entities/:entity_slug/data/:uuid/edit",
        PhoenixKitEntities.Web.DataForm,
        :edit,
        as: :entities_data_edit_localized
      )

      live(
        "/admin/settings/entities",
        PhoenixKitEntities.Web.EntitiesSettings,
        :index,
        as: :entities_settings_localized
      )
    end
  end

  @doc """
  Admin LiveView routes for the non-localized scope.
  """
  @spec admin_routes() :: Macro.t()
  def admin_routes do
    quote do
      live("/admin/entities", PhoenixKitEntities.Web.Entities, :index, as: :entities)

      live("/admin/entities/new", PhoenixKitEntities.Web.EntityForm, :new, as: :entities_new)

      live("/admin/entities/:id/edit", PhoenixKitEntities.Web.EntityForm, :edit,
        as: :entities_edit
      )

      live(
        "/admin/entities/:entity_slug/data",
        PhoenixKitEntities.Web.DataNavigator,
        :entity,
        as: :entities_data_entity
      )

      live(
        "/admin/entities/:entity_slug/data/new",
        PhoenixKitEntities.Web.DataForm,
        :new,
        as: :entities_data_new
      )

      live(
        "/admin/entities/:entity_slug/data/:uuid",
        PhoenixKitEntities.Web.DataShow,
        :show,
        as: :entities_data_show
      )

      live(
        "/admin/entities/:entity_slug/data/:uuid/edit",
        PhoenixKitEntities.Web.DataForm,
        :edit,
        as: :entities_data_edit
      )

      live(
        "/admin/settings/entities",
        PhoenixKitEntities.Web.EntitiesSettings,
        :index,
        as: :entities_settings
      )
    end
  end

  @doc """
  Public routes for entity form submissions.
  """
  @spec generate(String.t()) :: Macro.t()
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup])

        post(
          "/entities/:entity_slug/submit",
          PhoenixKitEntities.Controllers.EntityFormController,
          :submit
        )
      end
    end
  end
end
