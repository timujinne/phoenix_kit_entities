defmodule PhoenixKitEntities.Web.EntitiesLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, published} =
      Entities.create_entity(
        %{
          name: "live_pub",
          display_name: "Live Pub",
          display_name_plural: "Live Pubs",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, archived} =
      Entities.create_entity(
        %{
          name: "live_arch",
          display_name: "Live Arch",
          display_name_plural: "Live Archs",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "archived",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, published: published, archived: archived, actor_uuid: actor_uuid}
  end

  describe "mount" do
    test "renders entity manager with both entities", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities")

      assert html =~ "All Entities"
      assert html =~ "Live Pub"
      assert html =~ "Live Arch"
    end
  end

  describe "archive_entity" do
    test "flips status, fires entity.updated activity, and shows flash",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      # Table view renders the action inside `<.table_row_menu>`; scope
      # the selector to that menu's unique id (card view has its own
      # inline button on the same uuid).
      view
      |> element("#entity-menu-#{ctx.published.uuid} button[phx-click='archive_entity']")
      |> render_click()

      # Activity row reflects the threaded actor (delta-pin: actor_opts/1).
      assert_activity_logged("entity.updated",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: ctx.published.uuid,
        metadata_has: %{"status" => "archived"}
      )

      assert render(view) =~ "archived successfully"
      assert Entities.get_entity!(ctx.published.uuid).status == "archived"
    end

    test "archive button has phx-disable-with set", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities")

      # delta-pin: phx-disable-with attr present on every async/destructive
      # phx-click button (C5). Action lives inside `<.table_row_menu>`;
      # `:global` attrs aren't source-ordered so we scope to the menu's
      # subtree by id and assert both signals appear inside it.
      menu_id = "entity-menu-#{ctx.published.uuid}"

      menu_html =
        Regex.run(~r/<div id="#{menu_id}".*?<\/div>/s, html)
        |> List.first()

      assert is_binary(menu_html), "expected dropdown markup for #{menu_id}"
      assert menu_html =~ ~s(phx-click="archive_entity")
      assert menu_html =~ "phx-disable-with="
    end
  end

  describe "restore_entity" do
    test "flips status from archived → published with the threaded actor",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      view
      |> element("#entity-menu-#{ctx.archived.uuid} button[phx-click='restore_entity']")
      |> render_click()

      assert_activity_logged("entity.updated",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: ctx.archived.uuid,
        metadata_has: %{"status" => "published"}
      )

      assert render(view) =~ "restored successfully"
    end
  end

  describe "reorder_entities (drag-and-drop)" do
    test "valid ordered_ids re-indexes positions and pins the activity actor_uuid",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      ordered = [ctx.archived.uuid, ctx.published.uuid]
      render_hook(view, "reorder_entities", %{"ordered_ids" => ordered})

      assert Entities.get_entity!(ctx.archived.uuid).position == 1
      assert Entities.get_entity!(ctx.published.uuid).position == 2

      assert_activity_logged("entity.reordered",
        actor_uuid: ctx.actor_uuid,
        resource_type: "entity",
        resource_uuid: ctx.archived.uuid,
        metadata_has: %{"count" => 2}
      )
    end

    test "managed blueprints stay hidden from the list after a reorder refresh",
         %{conn: conn} = ctx do
      {:ok, managed} =
        Entities.create_entity(
          %{
            name: "catalogue_set_reorder_hidden",
            display_name: "Catalogue Set Reorder Hidden",
            display_name_plural: "Catalogue Sets",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid,
            settings: %{"managed_by" => "catalogue", "locked_keys" => []}
          },
          on_behalf_of: "catalogue"
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, "/en/admin/entities")
      refute html =~ managed.display_name

      render_hook(view, "reorder_entities", %{
        "ordered_ids" => [ctx.archived.uuid, ctx.published.uuid]
      })

      # The reorder success path re-fetches :entities — must keep excluding
      # managed blueprints, not just the initial handle_params load.
      refute render(view) =~ managed.display_name
    end

    test "malformed payload (no ordered_ids key) flashes error without crashing",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      render_hook(view, "reorder_entities", %{"unexpected" => "shape"})

      assert render(view) =~ "Failed to save the new order"
      # LV still alive — no MatchError crash.
      assert render(view) =~ ctx.published.display_name
    end

    test "non-admin scope flashes Not authorized and leaves positions unchanged",
         %{conn: conn} = ctx do
      conn =
        put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid, roles: [], permissions: []))

      {:ok, view, _html} = live(conn, "/en/admin/entities")

      prior_published = Entities.get_entity!(ctx.published.uuid).position
      prior_archived = Entities.get_entity!(ctx.archived.uuid).position

      render_hook(view, "reorder_entities", %{
        "ordered_ids" => [ctx.archived.uuid, ctx.published.uuid]
      })

      assert render(view) =~ "Not authorized"
      assert Entities.get_entity!(ctx.published.uuid).position == prior_published
      assert Entities.get_entity!(ctx.archived.uuid).position == prior_archived
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      send(view.pid, {:unrelated_message, :payload})
      assert render(view) =~ ctx.published.display_name
    end

    test "entity_updated refresh keeps managed blueprints hidden from the list",
         %{conn: conn} = ctx do
      {:ok, managed} =
        Entities.create_entity(
          %{
            name: "catalogue_set_pubsub_hidden",
            display_name: "Catalogue Set PubSub Hidden",
            display_name_plural: "Catalogue Sets",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid,
            settings: %{"managed_by" => "catalogue", "locked_keys" => []}
          },
          on_behalf_of: "catalogue"
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, "/en/admin/entities")
      refute html =~ managed.display_name

      # Any entity lifecycle event anywhere re-fetches :entities via this
      # handle_info clause — it must keep excluding managed blueprints too.
      send(view.pid, {:entity_updated, ctx.published.uuid})
      refute render(view) =~ managed.display_name
    end

    test "logs at :debug level so unexpected messages stay visible in dev",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities")

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:unhandled_in_test, :payload})
          render(view)
        end)

      assert log =~ "Entities: unhandled handle_info"
    end
  end
end
