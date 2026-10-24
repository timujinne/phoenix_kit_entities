defmodule PhoenixKitEntities.Web.FormStateRulesLiveTest do
  @moduledoc """
  What an open form holds versus what is stored: unsaved state — a peer's
  typing, a setting toggled but not saved, text typed into the form — never
  reaches the row before a save, and a write that happens outside the save
  (the backup switches) touches only its own keys.
  """
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Test.MirrorDir

  setup do
    creator = Ecto.UUID.generate()
    acting = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "fsr_#{System.unique_integer([:positive])}",
          display_name: "Stored Name",
          display_name_plural: "Stored Names",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: creator
        },
        actor_uuid: creator
      )

    {:ok, entity: entity, creator: creator, acting: acting}
  end

  defp as(conn, user_uuid), do: put_test_scope(conn, fake_scope(user_uuid: user_uuid))

  defp entity_form_params(entity, overrides) do
    %{
      "entities" =>
        Map.merge(
          %{
            "display_name" => entity.display_name,
            "display_name_plural" => entity.display_name_plural,
            "name" => entity.name
          },
          overrides
        )
    }
  end

  describe "a record open in two tabs" do
    test "saving in the tab that received the other's unsaved typing writes it",
         %{conn: conn} = ctx do
      {:ok, record} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Old",
            slug: "old",
            status: "published",
            data: %{"name" => "old-name"},
            created_by_uuid: ctx.creator
          },
          actor_uuid: ctx.creator
        )

      url = "/en/admin/entities/#{ctx.entity.name}/data/#{record.uuid}/edit"
      conn = as(conn, ctx.acting)
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      typed = %{
        "phoenix_kit_entity_data" => %{
          "title" => "New",
          "slug" => "old",
          "status" => "published",
          "data" => %{"name" => "new-name"}
        }
      }

      render_change(tab_a, "validate", typed)

      # Tab B shows the typing, and nothing has been written yet.
      assert render(tab_b) =~ "new-name"
      assert EntityData.get!(record.uuid).title == "Old"

      render_submit(tab_b, "save", typed)

      stored = EntityData.get!(record.uuid)
      assert stored.title == "New"
      assert stored.data["name"] == "new-name"
    end
  end

  describe "an entity open in two tabs" do
    test "a newly opened tab receives pending settings and a statistics reset",
         %{conn: conn} = ctx do
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)

      render_hook(tab_a, "toggle_public_form", %{})
      render_hook(tab_a, "toggle_public_form_field", %{"field" => "name"})
      render_hook(tab_a, "reset_form_stats", %{})
      {:ok, tab_b, _} = live(conn, url)

      assert has_element?(tab_b, ~s(input[name="public_form_enabled"][checked]))
      assert Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"]

      render_submit(tab_b, "save", entity_form_params(ctx.entity, %{}))
      saved = Entities.get_entity!(ctx.entity.uuid)
      assert saved.settings["public_form_enabled"] == true
      assert saved.settings["public_form_fields"] == ["name"]
      refute saved.settings["public_form_stats"]
    end

    test "settings received from another tab survive validation and save", %{conn: conn} = ctx do
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      render_hook(tab_a, "toggle_public_form", %{})
      render_hook(tab_a, "toggle_public_form_field", %{"field" => "name"})
      render(tab_b)
      assert Entities.get_entity!(ctx.entity.uuid).settings in [nil, %{}]

      params = entity_form_params(ctx.entity, %{"display_name" => "Saved from second tab"})
      render_change(tab_b, "validate", params)
      render_submit(tab_b, "save", params)

      stored = Entities.get_entity!(ctx.entity.uuid)
      assert stored.display_name == "Saved from second tab"
      assert stored.settings["public_form_enabled"] == true
      assert stored.settings["public_form_fields"] == ["name"]
    end

    test "a statistics reset can be saved from the receiving tab and is consumed",
         %{conn: conn} = ctx do
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      render_hook(tab_a, "reset_form_stats", %{})
      render(tab_b)
      assert Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"]

      render_submit(tab_b, "save", entity_form_params(ctx.entity, %{}))
      refute Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"]

      # Saving the reset clears it in both tabs; later submissions survive
      # the next save even in the tab that originally requested the reset.
      render(tab_a)
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      render_submit(tab_a, "save", entity_form_params(ctx.entity, %{}))

      assert Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"][
               "total_submissions"
             ] ==
               1
    end

    test "discarding a statistics reset in another tab cancels it everywhere",
         %{conn: conn} = ctx do
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      render_hook(tab_a, "reset_form_stats", %{})
      render(tab_b)
      render_hook(tab_b, "reset", %{})
      render(tab_a)
      render_submit(tab_a, "save", entity_form_params(ctx.entity, %{}))

      assert Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"][
               "total_submissions"
             ] ==
               1
    end

    test "a new tab does not revive a reset another tab already saved", %{conn: conn} = ctx do
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      render_hook(tab_a, "reset_form_stats", %{})
      render(tab_b)
      render_submit(tab_b, "save", entity_form_params(ctx.entity, %{}))
      render(tab_a)

      {:ok, tab_c, _} = live(conn, url)
      Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
      render_submit(tab_c, "save", entity_form_params(ctx.entity, %{}))

      assert Entities.get_entity!(ctx.entity.uuid).settings["public_form_stats"][
               "total_submissions"
             ] ==
               1
    end
  end

  describe "the backup switches while editing an entity" do
    # Switching a mirror on starts a supervised export. Point it at a
    # scratch directory and let it finish before the sandbox goes away.
    setup do
      MirrorDir.use!(MirrorDir.path("form_state_rules"))

      :ok
    end

    defp await_exports do
      for pid <- Task.Supervisor.children(PhoenixKit.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, _, _, _}, 5_000
      end
    end

    test "keep what was typed and write only their own key", %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(as(conn, ctx.acting), "/en/admin/entities/#{ctx.entity.uuid}/edit")

      html =
        render_change(
          view,
          "validate",
          entity_form_params(ctx.entity, %{"display_name" => "TYPED UNSAVED"})
        )

      assert html =~ "TYPED UNSAVED"

      # Another setting, toggled and not saved.
      html = render_hook(view, "toggle_public_form", %{})
      assert html =~ "TYPED UNSAVED"
      render_hook(view, "toggle_public_form_field", %{"field" => "name"})

      html = render_hook(view, "toggle_backup_definitions", %{})
      assert html =~ "TYPED UNSAVED"

      stored = Entities.get_entity!(ctx.entity.uuid)
      assert stored.display_name == "Stored Name"
      assert stored.settings == %{"mirror_definitions" => true}

      html = render_hook(view, "toggle_backup_data", %{})
      assert html =~ "TYPED UNSAVED"
      stored = Entities.get_entity!(ctx.entity.uuid)
      assert stored.settings == %{"mirror_definitions" => true, "mirror_data" => true}

      # The unsaved setting is still in the form, and a save writes all of it.
      render_submit(
        view,
        "save",
        entity_form_params(ctx.entity, %{"display_name" => "TYPED UNSAVED"})
      )

      saved = Entities.get_entity!(ctx.entity.uuid)
      assert saved.display_name == "TYPED UNSAVED"
      await_exports()

      assert %{
               "mirror_definitions" => true,
               "mirror_data" => true,
               "public_form_enabled" => true,
               "public_form_fields" => ["name"]
             } = saved.settings
    end

    test "are attributed to the admin who flipped them, not the entity's creator",
         %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(as(conn, ctx.acting), "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "toggle_backup_definitions", %{})

      assert_activity_logged("entity.updated",
        actor_uuid: ctx.acting,
        resource_uuid: ctx.entity.uuid
      )

      await_exports()
    end

    test "a second tab's save keeps backup settings switched in the first tab",
         %{conn: conn} = ctx do
      conn = as(conn, ctx.acting)
      url = "/en/admin/entities/#{ctx.entity.uuid}/edit"
      {:ok, tab_a, _} = live(conn, url)
      {:ok, tab_b, _} = live(conn, url)

      render_change(
        tab_b,
        "validate",
        entity_form_params(ctx.entity, %{"display_name" => "UNSAVED NAME"})
      )

      render(tab_a)
      render_hook(tab_a, "toggle_backup_definitions", %{})
      render_hook(tab_a, "toggle_backup_data", %{})
      render(tab_b)

      stored = Entities.get_entity!(ctx.entity.uuid)
      assert stored.display_name == "Stored Name"
      assert stored.settings == %{"mirror_definitions" => true, "mirror_data" => true}

      render_submit(
        tab_b,
        "save",
        entity_form_params(ctx.entity, %{"display_name" => "UNSAVED NAME"})
      )

      saved = Entities.get_entity!(ctx.entity.uuid)
      await_exports()

      assert saved.display_name == "UNSAVED NAME"
      assert saved.settings == %{"mirror_definitions" => true, "mirror_data" => true}
    end
  end

  describe "every unsaved settings control on the entity form" do
    for {event, params} <- [
          {"toggle_public_form", %{}},
          {"toggle_public_form_field", %{"field" => "name"}},
          {"toggle_security_setting", %{"setting" => "public_form_honeypot"}},
          {"update_security_action",
           %{
             "setting" => "public_form_honeypot_action",
             "public_form_honeypot_action" => "save_log"
           }},
          {"reset_form_stats", %{}}
        ] do
      test "#{event} keeps what was typed", %{conn: conn} = ctx do
        {:ok, view, _html} =
          live(as(conn, ctx.acting), "/en/admin/entities/#{ctx.entity.uuid}/edit")

        render_change(
          view,
          "validate",
          entity_form_params(ctx.entity, %{"display_name" => "TYPED UNSAVED"})
        )

        html = render_hook(view, unquote(event), unquote(Macro.escape(params)))

        assert html =~ "TYPED UNSAVED"
        assert Entities.get_entity!(ctx.entity.uuid).settings in [nil, %{}]
      end
    end
  end

  describe "the modals on the entity form" do
    # A click is dispatched to the nearest common ancestor of the press and
    # the release, so a close handler on an ANCESTOR of the inputs fires when
    # a text selection that began in a field is released outside the box.
    defp ancestors_with_click(html, input_selector, event) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|[phx-click="#{event}"]:has(#{input_selector})|)
      |> Enum.count()
    end

    test "the field editor closes from a sibling backdrop, never from an ancestor of its inputs",
         %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(as(conn, ctx.acting), "/en/admin/entities/#{ctx.entity.uuid}/edit")

      html = render_hook(view, "add_field", %{})

      assert has_element?(view, ~s(.modal.modal-open > .modal-box input[name="field[label]"]))

      assert has_element?(
               view,
               ~s(.modal.modal-open > .modal-box + .modal-backdrop[phx-click="cancel_field"])
             )

      assert ancestors_with_click(html, ~s(input[name="field[label]"]), "cancel_field") == 0

      view |> element(~s(.modal-backdrop[phx-click="cancel_field"])) |> render_click()
      refute has_element?(view, ~s(input[name="field[label]"]))
    end

    test "the icon picker closes from a sibling backdrop, never from an ancestor of its search box",
         %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(as(conn, ctx.acting), "/en/admin/entities/#{ctx.entity.uuid}/edit")

      html = render_hook(view, "open_icon_picker", %{})

      assert has_element?(
               view,
               ~s(div.absolute.inset-0[phx-click="close_icon_picker"] + div.relative input[name="search"])
             )

      assert ancestors_with_click(html, ~s(input[name="search"]), "close_icon_picker") == 0

      view |> element(~s(div.absolute.inset-0[phx-click="close_icon_picker"])) |> render_click()
      refute has_element?(view, ~s(div.absolute.inset-0[phx-click="close_icon_picker"]))
    end
  end
end
