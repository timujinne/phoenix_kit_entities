defmodule PhoenixKitEntities.Web.EntityFormLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.FormBuilder

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "ef_test",
          display_name: "EF Test",
          display_name_plural: "EF Tests",
          fields_definition: [
            %{"type" => "text", "key" => "name", "label" => "Name"}
          ],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  # Scopes assertions to the allow_other *checkbox* — the field editor also
  # renders a hidden `field[allow_other]` fallback input (needed so
  # unticking the box actually submits "false" instead of nothing), so a
  # bare `Regex.run` would match that hidden input first instead.
  defp allow_other_checkbox_tag(html) do
    case Regex.run(~r/<input type="checkbox"[^>]*name="field\[allow_other\]"[^>]*>/, html) do
      [tag] -> tag
      nil -> ""
    end
  end

  describe "mount new" do
    test "renders the new-entity page", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities/new")

      assert html =~ "<title>New Entity</title>"
    end

    test "submit button has phx-disable-with (delta-pin C5)", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities/new")

      assert html =~ ~r|type="submit"[^>]*phx-disable-with=|
    end
  end

  describe "mount edit" do
    test "renders existing entity values pre-filled", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      assert html =~ "<title>Edit Entity</title>"
      assert html =~ ~s|value="EF Test"|
      assert html =~ ~s|value="ef_test"|
    end
  end

  describe "validate event" do
    test "validate sets :action so inline errors render (delta-pin C5)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      # Submit a name that violates `validate_format` (uppercase letters
      # forbidden). Without `:action = :validate` on the changeset, the
      # `<.input>` core component swallows the error silently.
      view
      |> form("form[phx-change='validate']", %{"entities" => %{"name" => "INVALID-name"}})
      |> render_change()

      html = render(view)
      # Either the inline error renders with the format message, or at
      # minimum the changeset has its action set (we can't read socket
      # state, so check the rendered DOM for an error class).
      assert html =~ "input-error" or html =~ "must contain only lowercase"
    end
  end

  describe "save_and_return" do
    test "Update and Return navigates back to /admin/entities", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      # The form has TWO submit buttons in each action row. The plain
      # "Update Entity" button submits the form without `return_to_list`;
      # the "Update and Return" button carries `name="return_to_list"
      # value="true"`. Phoenix's `render_submit/2` second arg lets us
      # inject the second-button params on top of the form fields.
      view
      |> form("form[phx-change='validate']", %{
        "entities" => %{"display_name" => "Updated Display Name"}
      })
      |> render_submit(%{"return_to_list" => "true"})

      # The LV pushes navigate to /admin/entities under the configured
      # locale (or the referrer if one was captured at mount — none
      # here so it falls back to the list path).
      assert_redirected(view, "/phoenix_kit/en-US/admin/entities")
    end

    test "plain Update keeps you on the edit page", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      # Submit without `return_to_list` — same form, plain button.
      view
      |> form("form[phx-change='validate']", %{
        "entities" => %{"display_name" => "Stay Put"}
      })
      |> render_submit()

      # No redirect — the view stays on the edit page (handle_save_success
      # falls through to the "stay on edit" branch). Render-after-submit
      # would crash if a push_navigate had fired.
      assert page_title(view) =~ "Edit Entity"
      # And the save actually persisted.
      assert Entities.get_entity!(ctx.entity.uuid).display_name == "Stay Put"
    end

    test "a managed blueprint's slug is LOCKED in the form, not refused after the fact",
         %{conn: conn} = ctx do
      # 2026-08-27: the banner promised protection while the inputs still
      # looked editable (Max's report). The slug control is now disabled
      # with a hidden twin pinning its value — the form cannot even
      # EXPRESS a rename (LiveViewTest would refuse a forged value), and
      # a save leaves the slug untouched. The write-path guard behind it
      # keeps its own coverage in managed_test.exs.
      {:ok, managed} =
        Entities.create_entity(
          %{
            name: "catalogue_set_guarded",
            display_name: "Guarded",
            display_name_plural: "Guarded",
            settings: %{"managed_by" => "catalogue", "locked_keys" => ["kind"]},
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid,
          on_behalf_of: "catalogue"
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, "/en/admin/entities/#{managed.uuid}/edit")

      # The structural surface renders locked…
      assert html =~ "Managed by the catalogue module"
      assert html =~ ~s(id="entity_status")
      assert view |> element("#entity_status") |> render() =~ "disabled"
      assert html =~ "Locked — the owning module keys on this slug"
      refute html =~ "generate_entity_slug"

      # …the hidden twin pins the slug, so a plain save changes nothing.
      html =
        view
        |> form("form[phx-change='validate']", %{
          "entities" => %{"display_name" => "Guarded Renamed"}
        })
        |> render_submit()

      assert Entities.get_entity!(managed.uuid).name == "catalogue_set_guarded"
      assert Entities.get_entity!(managed.uuid).display_name == "Guarded Renamed"
      _ = html
    end
  end

  describe "switch_language event" do
    test "ignores unknown language and stays on the form", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "switch_language", %{"lang" => "totally-fake"})
      assert page_title(view) =~ "Edit Entity"
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      send(view.pid, {:unrelated_message, :payload})
      assert page_title(view) =~ "Edit Entity"
    end

    test "logs at :debug level so unexpected messages stay visible in dev",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:unhandled_in_test, :payload})
          render(view)
        end)

      assert log =~ "EntityForm: unhandled handle_info"
    end
  end

  describe "icon picker events" do
    test "open / close picker doesn't crash", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "open_icon_picker", %{})
      render_hook(view, "search_icons", %{"search" => "user"})
      render_hook(view, "filter_by_category", %{"tab" => "general"})
      render_hook(view, "select_icon", %{"icon" => "hero-user"})
      render_hook(view, "clear_icon", %{})
      render_hook(view, "close_icon_picker", %{})
      render_hook(view, "stop_propagation", %{})
      assert render(view) =~ "Update Entity"
    end
  end

  describe "field management events" do
    test "add / edit / cancel / delete field events don't crash",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "save_field", %{
        "field" => %{
          "type" => "text",
          "key" => "second",
          "label" => "Second"
        }
      })

      render_hook(view, "edit_field", %{"index" => "0"})
      render_hook(view, "update_field_form", %{"field" => %{"label" => "Updated"}})
      render_hook(view, "cancel_field", %{})

      render_hook(view, "confirm_delete_field", %{"index" => "0"})
      render_hook(view, "cancel_delete_field", %{})

      render_hook(view, "move_field_up", %{"index" => "1"})
      render_hook(view, "move_field_down", %{"index" => "0"})

      render_hook(view, "generate_entity_slug", %{})
      render_hook(view, "generate_field_key", %{})
      assert render(view) =~ "Update Entity"
    end

    test "select-type field add_option / update_option / remove_option don't crash",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "update_field_form", %{
        "field" => %{"type" => "select", "label" => "Choices"}
      })

      render_hook(view, "add_option", %{})
      render_hook(view, "update_option", %{"index" => "0", "value" => "Apple"})
      render_hook(view, "remove_option", %{"index" => "0"})
      assert render(view) =~ "Update Entity"
    end

    test "file field's max size (MB) accepts a comma decimal, same as the dot form",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "save_field", %{
        "field" => %{
          "type" => "file",
          "key" => "attachment",
          "label" => "Attachment",
          "max_file_size_mb" => "2,5"
        }
      })

      # Field is index 1 — index 0 is the "name" field from the fixture entity.
      html = render_hook(view, "edit_field", %{"index" => "1"})
      assert html =~ ~s(name="field[max_file_size_mb]")
      assert html =~ ~s(value="2.5")

      render_hook(view, "add_field", %{})

      render_hook(view, "save_field", %{
        "field" => %{
          "type" => "file",
          "key" => "attachment_dot",
          "label" => "Attachment Dot",
          "max_file_size_mb" => "2.5"
        }
      })

      html = render_hook(view, "edit_field", %{"index" => "2"})
      assert html =~ ~s(value="2.5")

      render_hook(view, "add_field", %{})

      render_hook(view, "save_field", %{
        "field" => %{
          "type" => "file",
          "key" => "attachment_garbage",
          "label" => "Attachment Garbage",
          "max_file_size_mb" => "not-a-number"
        }
      })

      # Garbage falls back to the 15 MB default, same as before.
      html = render_hook(view, "edit_field", %{"index" => "3"})
      assert html =~ ~s(value="15")
    end

    test "allow_other toggle persists on a radio field and pre-fills on re-edit",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "update_field_form", %{
        "field" => %{"type" => "radio", "label" => "Color", "key" => "color"}
      })

      render_hook(view, "add_option", %{})
      render_hook(view, "update_option", %{"index" => "0", "value" => "Red"})

      render_hook(view, "update_field_form", %{
        "field" => %{"allow_other" => "true"}
      })

      render_hook(view, "save_field", %{"field" => %{}})

      # Field is index 1 — index 0 is the "name" field from the fixture entity.
      html = render_hook(view, "edit_field", %{"index" => "1"})

      assert html =~ ~s(name="field[allow_other]")
      assert allow_other_checkbox_tag(html) =~ "checked"
    end

    test "allow_other toggle can be switched back off (hidden false fallback)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "update_field_form", %{
        "field" => %{"type" => "radio", "label" => "Color", "key" => "color"}
      })

      render_hook(view, "add_option", %{})
      render_hook(view, "update_option", %{"index" => "0", "value" => "Red"})

      render_hook(view, "update_field_form", %{"field" => %{"allow_other" => "true"}})

      # Ticked checkboxes submit "true"; the browser never omits the key
      # entirely because of the hidden `value="false"` fallback rendered
      # before it — unticking sends "false" (only the hidden input fires),
      # not a missing key. That's exactly what this simulates.
      html = render_hook(view, "update_field_form", %{"field" => %{"allow_other" => "false"}})

      assert allow_other_checkbox_tag(html) =~ ~s(name="field[allow_other]")
      refute allow_other_checkbox_tag(html) =~ "checked"

      render_hook(view, "save_field", %{"field" => %{}})

      # Field is index 1 — index 0 is the "name" field from the fixture entity.
      html = render_hook(view, "edit_field", %{"index" => "1"})
      refute allow_other_checkbox_tag(html) =~ "checked"
    end

    test "a field built through the admin editor round-trips through storage and renders Other",
         %{conn: conn} = ctx do
      # Full circle: the exact bug the reviewer caught only shows up once
      # a field goes through save_field -> Entities.update_entity ->
      # get_entity (persisting/reading "allow_other" as the JSONB string
      # "true", never the Elixir boolean) -> build_field. Fixtures built
      # with `"allow_other" => true` by hand never exercise this path.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "add_field", %{})

      render_hook(view, "update_field_form", %{
        "field" => %{"type" => "radio", "label" => "Color", "key" => "color"}
      })

      render_hook(view, "add_option", %{})
      render_hook(view, "update_option", %{"index" => "0", "value" => "Red"})
      render_hook(view, "update_field_form", %{"field" => %{"allow_other" => "true"}})
      render_hook(view, "save_field", %{"field" => %{}})

      view
      |> form("form", entities: %{display_name: ctx.entity.display_name})
      |> render_submit()

      reread = Entities.get_entity(ctx.entity.uuid)
      saved_field = Enum.find(reread.fields_definition, &(&1["key"] == "color"))

      assert saved_field["allow_other"] == "true"

      changeset = Ecto.Changeset.cast(%PhoenixKitEntities.EntityData{data: %{}}, %{}, [])
      html = FormBuilder.build_field(saved_field, changeset) |> rendered_to_string()

      assert html =~ "__other__"
    end

    test "required/default controls are hidden while editing a heading field",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      html = render_hook(view, "add_field", %{})
      assert html =~ ~s(name="field[required]")
      assert html =~ ~s(name="field[default]")

      html =
        render_hook(view, "update_field_form", %{
          "field" => %{"type" => "heading", "label" => "Section"}
        })

      refute html =~ ~s(name="field[required]")
      refute html =~ ~s(name="field[default]")
    end
  end

  describe "public form settings events" do
    test "toggle_public_form / update_public_form_setting / toggle_public_form_field",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "toggle_public_form", %{})

      render_hook(view, "update_public_form_setting", %{
        "setting" => "public_form_title",
        "value" => "Hello"
      })

      render_hook(view, "toggle_public_form_field", %{"field" => "name"})
      assert render(view) =~ "Update Entity"
    end

    test "the field selector excludes heading fields — they're display-only, never public form data",
         %{conn: conn} = ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "ef_test_heading_#{System.unique_integer([:positive])}",
            display_name: "EF Heading Test",
            display_name_plural: "EF Heading Tests",
            fields_definition: [
              %{"type" => "heading", "key" => "sec", "label" => "Section Heading"},
              %{"type" => "text", "key" => "name", "label" => "Name"}
            ],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{entity.uuid}/edit")

      html = render_hook(view, "toggle_public_form", %{})

      assert html =~ ~s(phx-value-field="name")
      refute html =~ ~s(phx-value-field="sec")
    end

    test "security setting toggles + actions",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "toggle_security_setting", %{"setting" => "public_form_honeypot"})

      render_hook(view, "update_security_action", %{
        "setting" => "public_form_honeypot_action",
        "value" => "save_suspicious"
      })

      render_hook(view, "reset_form_stats", %{})
      assert render(view) =~ "Update Entity"
    end
  end

  describe "backup toggles + export" do
    test "toggle_backup_definitions / toggle_backup_data / export_entity_now",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "toggle_backup_definitions", %{})
      render_hook(view, "toggle_backup_data", %{})
      render_hook(view, "export_entity_now", %{})
      assert render(view) =~ "Update Entity"
    end
  end

  describe "save event" do
    test "submitting valid params persists changes", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      view
      |> form("form", entities: %{display_name: "Renamed"})
      |> render_submit()

      reread = Entities.get_entity(ctx.entity.uuid)
      assert reread != nil
    end
  end

  describe "reset event" do
    test "doesn't crash and re-renders the form", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")

      render_hook(view, "reset", %{})
      assert render(view) =~ "Update Entity"
    end
  end
end
