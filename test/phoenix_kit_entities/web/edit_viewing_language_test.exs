defmodule PhoenixKitEntities.Web.EditViewingLanguageTest do
  @moduledoc """
  The entity and entity-data forms open an EDIT on the language tab of the
  language the admin is viewing the page in; a new record starts on the
  main language, which holds its required fields.
  """
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")

    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "lang_test",
          display_name: "Lang Test",
          display_name_plural: "Lang Tests",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, record} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Hello",
          slug: "hello",
          status: "published",
          data: %{"name" => "Acme"},
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    conn =
      conn
      |> put_test_scope(fake_scope(user_uuid: actor_uuid))
      |> with_request_locale("fr-FR")

    %{conn: conn, entity: entity, record: record}
  end

  defp open_lang(view), do: :sys.get_state(view.pid).socket.assigns.current_lang

  test "viewed in French, the edit forms open on the French tab", ctx do
    for path <- [
          "/en/admin/entities/#{ctx.entity.uuid}/edit",
          "/en/admin/entities/#{ctx.entity.name}/data/#{ctx.record.uuid}/edit"
        ] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "fr-FR", path
    end
  end

  test "viewed in French, a new record starts on the main tab", ctx do
    for path <- ["/en/admin/entities/new", "/en/admin/entities/#{ctx.entity.name}/data/new"] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "en-US", path
    end
  end
end
