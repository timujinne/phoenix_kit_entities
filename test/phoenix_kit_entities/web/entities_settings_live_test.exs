defmodule PhoenixKitEntities.Web.EntitiesSettingsLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Mirror.Storage

  setup do
    actor_uuid = Ecto.UUID.generate()
    {:ok, actor_uuid: actor_uuid}
  end

  describe "mount" do
    test "renders settings page with system status panel", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/settings/entities")

      assert html =~ "System Status"
    end
  end

  describe "enable_entities / disable_entities" do
    test "disable_entities toggles the setting + logs module.entities.disabled",
         %{conn: conn} = ctx do
      # Start enabled so the disable button renders
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      view
      |> element("button[phx-click='disable_entities']")
      |> render_click()

      assert_activity_logged("module.entities.disabled",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"setting" => "entities_enabled"}
      )

      assert render(view) =~ "disabled successfully"
    end

    test "enable_entities toggles the setting + logs module.entities.enabled",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.disable_system(actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      view
      |> element("button[phx-click='enable_entities']")
      |> render_click()

      assert_activity_logged("module.entities.enabled",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"setting" => "entities_enabled"}
      )

      assert render(view) =~ "enabled successfully"
    end

    test "disable_entities button has phx-disable-with set", %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/settings/entities")

      # delta-pin: phx-disable-with on every async/destructive button (C5)
      assert html =~ ~r/phx-click="disable_entities"[^>]*phx-disable-with=/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      send(view.pid, {:unrelated_message, :payload})
      assert render(view) =~ "Entities System"
    end

    test "logs at :debug level so unexpected messages stay visible in dev",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:unhandled_in_test, :payload})
          render(view)
        end)

      assert log =~ "EntitiesSettings: unhandled handle_info"
    end
  end

  describe "settings form events" do
    test "validate + save events update settings without crashing",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      # Drive the events directly via render_hook since the page may
      # have multiple forms (settings + mirror) and `form/2` on a bare
      # selector ambiguates.
      render_hook(view, "validate", %{
        "settings" => %{"auto_generate_slugs" => "true"}
      })

      render_hook(view, "save", %{
        "settings" => %{
          "auto_generate_slugs" => "true",
          "default_status" => "draft"
        }
      })

      assert render(view) =~ "Entities System"
    end

    test "reset_to_defaults event doesn't crash",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "reset_to_defaults", %{})
      assert render(view) =~ "Entities System"
    end
  end

  describe "mirror toggle / export / import events" do
    setup do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "settings_widget",
            display_name: "Settings Widget",
            display_name_plural: "Settings Widgets",
            fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, entity: entity, actor_uuid: actor_uuid}
    end

    test "toggle_entity_definitions / toggle_entity_data round-trip",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "toggle_entity_definitions", %{"uuid" => ctx.entity.uuid})
      render_hook(view, "toggle_entity_data", %{"uuid" => ctx.entity.uuid})
      assert render(view) =~ "Entities System"
    end

    test "enable_all_definitions / disable_all_definitions doesn't crash",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "enable_all_definitions", %{})
      render_hook(view, "disable_all_definitions", %{})
      assert render(view) =~ "Entities System"
    end

    test "enable_all_data / disable_all_data doesn't crash",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "enable_all_data", %{})
      render_hook(view, "disable_all_data", %{})
      assert render(view) =~ "Entities System"
    end

    test "export_now / refresh_export_stats / export_entity_now don't crash",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "export_now", %{})
      render_hook(view, "refresh_export_stats", %{})
      render_hook(view, "export_entity_now", %{"uuid" => ctx.entity.uuid})
      assert render(view) =~ "Entities System"
    end

    test "import-modal flow: show / set_tab / hide",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "show_import_modal", %{})
      render_hook(view, "set_import_tab", %{"tab" => ctx.entity.name})
      render_hook(view, "hide_import_modal", %{})
      assert render(view) =~ "Entities System"
    end

    test "import preview entity tabs render via nav_tabs and switch on phx-value-tab",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)

      a = "import_tab_a_#{System.unique_integer([:positive])}"
      b = "import_tab_b_#{System.unique_integer([:positive])}"

      for name <- [a, b] do
        payload = %{
          "definition" => %{
            "name" => name,
            "display_name" => name,
            "display_name_plural" => name,
            "fields_definition" => [%{"type" => "text", "key" => "title", "label" => "Title"}],
            "status" => "published"
          },
          "data" => [
            %{
              "title" => "#{name} record",
              "slug" => "#{name}-1",
              "status" => "published",
              "data" => %{"title" => "#{name} record"},
              "metadata" => %{}
            }
          ]
        }

        assert {:ok, _path} = Storage.write_entity(name, payload)
      end

      on_exit(fn ->
        Storage.delete_entity(a)
        Storage.delete_entity(b)
      end)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      html = render_hook(view, "show_import_modal", %{})
      assert html =~ "tabs-border"
      assert html =~ ~s(phx-click="set_import_tab")
      assert has_element?(view, ~s(button[role="tab"][phx-value-tab="#{a}"]))
      assert has_element?(view, ~s(button[role="tab"][phx-value-tab="#{b}"]))

      view
      |> element(~s(button[role="tab"][phx-value-tab="#{b}"]))
      |> render_click()

      assert has_element?(view, ~s(button.tab-active[phx-value-tab="#{b}"]))
      refute has_element?(view, ~s(button.tab-active[phx-value-tab="#{a}"]))
    end

    test "do_import event doesn't crash (no entities to import)",
         %{conn: conn} = ctx do
      {:ok, _} = Entities.enable_system(actor_uuid: ctx.actor_uuid)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "do_import", %{})
      assert render(view) =~ "Entities System"
    end
  end
end
