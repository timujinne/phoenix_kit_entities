defmodule PhoenixKitEntities.Web.EntitiesSettingsLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.Mirror.Storage
  alias PhoenixKitEntities.Test.MirrorDir

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

    test "lives under Settings in the header trail", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/settings/entities")

      assert html =~ "<title>Entities</title>"
      assert %{section: {"Settings", settings_path}, crumbs: []} = page_trail(html)
      assert String.ends_with?(settings_path, "/admin/settings")
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
      assert Entities.get_entity!(ctx.entity.uuid).settings["mirror_definitions"] == true

      render_hook(view, "toggle_entity_data", %{"uuid" => ctx.entity.uuid})
      assert Entities.get_entity!(ctx.entity.uuid).settings["mirror_data"] == true
    end

    test "a mirror toggle is attributed to the admin who flipped it, not the entity's creator",
         %{conn: conn} = ctx do
      acting = Ecto.UUID.generate()
      conn = put_test_scope(conn, fake_scope(user_uuid: acting))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "toggle_entity_definitions", %{"uuid" => ctx.entity.uuid})

      assert_activity_logged("entity.updated", actor_uuid: acting, resource_uuid: ctx.entity.uuid)
    end

    test "enable-all is attributed to the admin who clicked it", %{conn: conn} = ctx do
      acting = Ecto.UUID.generate()
      conn = put_test_scope(conn, fake_scope(user_uuid: acting))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")

      render_hook(view, "enable_all_definitions", %{})

      assert Entities.get_entity!(ctx.entity.uuid).settings["mirror_definitions"] == true
      assert_activity_logged("entity.updated", actor_uuid: acting, resource_uuid: ctx.entity.uuid)
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

  describe "the import result flash" do
    setup do
      dir =
        MirrorDir.use!(MirrorDir.path("settings_live"))

      # The importer attributes what it creates to the first admin.
      Fixtures.admin_fixture()
      {:ok, dir: dir}
    end

    defp write_export(dir, name, fields, records) do
      File.write!(
        Path.join(dir, "#{name}.json"),
        Jason.encode!(%{
          "definition" => %{
            "name" => name,
            "display_name" => "Import #{name}",
            "display_name_plural" => "Import #{name}s",
            "status" => "published",
            "fields_definition" => fields,
            "settings" => %{}
          },
          "data" => records
        })
      )
    end

    defp import_everything(conn, actor_uuid) do
      conn = put_test_scope(conn, fake_scope(user_uuid: actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/settings/entities")
      render_hook(view, "show_import_modal", %{})
      render_hook(view, "do_import", %{})
      view
    end

    @email_field %{"type" => "email", "key" => "email", "label" => "Email"}

    test "a clean run reports what was created as info", %{conn: conn} = ctx do
      write_export(ctx.dir, "flash_ok", [@email_field], [
        %{
          "title" => "A",
          "slug" => "a",
          "status" => "published",
          "data" => %{"email" => "a@b.co"}
        }
      ])

      view = import_everything(conn, ctx.actor_uuid)

      assert view |> element("#flash-info") |> render() =~
               "Import complete. Definitions: 1 created, 0 updated, 0 skipped. Data: 1 created, 0 updated, 0 skipped."

      refute has_element?(view, "#flash-error")
      assert Entities.get_entity_by_name("flash_ok")
    end

    test "an invalid record is reported as an error next to the counts", %{conn: conn} = ctx do
      write_export(ctx.dir, "flash_bad", [@email_field], [
        %{
          "title" => "A",
          "slug" => "a",
          "status" => "published",
          "data" => %{"email" => "a@b.co"}
        },
        %{"title" => "B", "slug" => "b", "status" => "published", "data" => %{"email" => "nope"}}
      ])

      view = import_everything(conn, ctx.actor_uuid)

      error = view |> element("#flash-error") |> render()
      assert error =~ "Import finished with 1 error(s), the first: a record is not valid"
      assert error =~ "must be a valid email"
      assert view |> element("#flash-info") |> render() =~ "Data: 1 created"
    end

    test "a file that cannot be imported is an error next to the counts", %{conn: conn} = ctx do
      write_export(ctx.dir, "flash_ok", [@email_field], [])
      File.write!(Path.join(ctx.dir, "flash_broken.json"), Jason.encode!(%{"data" => "x"}))

      view = import_everything(conn, ctx.actor_uuid)

      assert view |> element("#flash-error") |> render() =~
               "Import finished with 1 error(s), the first: Invalid format."

      assert view |> element("#flash-info") |> render() =~ "Definitions: 1 created"
    end

    test "links that could not be resolved are named in a warning", %{conn: conn} = ctx do
      write_export(
        ctx.dir,
        "flash_link",
        [FieldTypes.relation_field("target", "Target", "settings_widget")],
        [
          %{
            "title" => "A",
            "slug" => "a",
            "status" => "published",
            "data" => %{"target" => %{"slug" => "not-there"}}
          }
        ]
      )

      view = import_everything(conn, ctx.actor_uuid)

      assert view |> element("#flash-warning") |> render() =~
               "1 relation field(s) pointed at records that could not be found and were left without them: flash_link/a (target)"

      assert view |> element("#flash-info") |> render() =~ "Data: 1 created"
    end
  end
end
