defmodule PhoenixKitEntities.Web.DataShowLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Test.Repo, as: TestRepo
  alias PhoenixKitEntities.Web.{DataForm, DataShow}
  alias PhoenixKitWeb.Users.Auth

  @media_uuid "0197d8f0-aaaa-7bbb-8ccc-ddddeeeeffff"

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, target_entity} =
      Entities.create_entity(
        %{
          name: "ds_target",
          display_name: "DS Target",
          display_name_plural: "DS Targets",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, target} =
      EntityData.create(
        %{
          entity_uuid: target_entity.uuid,
          title: "Linked thing",
          slug: "linked-thing",
          status: "published",
          data: %{"name" => "t"},
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "ds_test",
          display_name: "DS Test",
          display_name_plural: "DS Tests",
          fields_definition: [
            %{"type" => "heading", "key" => "section", "label" => "Section A"},
            %{"type" => "text", "key" => "name", "label" => "Name"},
            %{"type" => "boolean", "key" => "active", "label" => "Active"},
            %{"type" => "boolean", "key" => "paused", "label" => "Paused"},
            %{"type" => "textarea", "key" => "notes", "label" => "Notes"},
            %{"type" => "url", "key" => "site", "label" => "Site"},
            %{"type" => "rich_text", "key" => "body", "label" => "Body"},
            %{"type" => "image", "key" => "cover", "label" => "Cover"},
            %{"type" => "file", "key" => "docs", "label" => "Docs"},
            %{
              "type" => "relation",
              "key" => "ref",
              "label" => "Ref",
              "target_entity" => target_entity.uuid
            }
          ],
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
          data: %{
            "name" => "Acme",
            "active" => true,
            "paused" => false,
            "notes" => "first line\nsecond <b>line</b>",
            "site" => "https://example.com/x?a=1",
            "body" => "<p>Rich <strong>text</strong></p>",
            "cover" => @media_uuid,
            "docs" => [%{"filename" => "spec.pdf", "size" => 2048}],
            "ref" => target.uuid
          },
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid,
        relation_check: :defer
      )

    {:ok, entity: entity, record: record, target: target, actor_uuid: actor_uuid}
  end

  describe "render" do
    test "shows title, status, field labels and values — and no form", %{conn: conn} = ctx do
      {:ok, _view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert html =~ "Hello"
      assert html =~ "Published"
      assert html =~ "Name"
      assert html =~ "Acme"
      assert html =~ "Section A"
      refute html =~ "<form"
      refute html =~ "<input"
      refute html =~ ~s|type="submit"|
    end

    test "the page trail is Entities / <plural> / <record>", %{conn: conn} = ctx do
      {:ok, _view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert %{section: {"Entities", _}, crumbs: [{"DS Tests", path}, {"Hello", nil}]} =
               page_trail(html)

      assert String.ends_with?(path, "/admin/entities/ds_test/data")
    end

    test "booleans read Yes/No", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="active"]|, "Yes")
    end

    test "a false boolean reads No, not a dash", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="paused"]|, "No")
      refute has_element?(view, ~s|[data-field="paused"]|, "—")
    end

    test "a textarea keeps its line breaks and escapes markup", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="notes"] p.whitespace-pre-wrap|)

      html = view |> element(~s|[data-field="notes"] p|) |> render()
      assert html =~ "first line\nsecond &lt;b&gt;line&lt;/b&gt;"
    end

    test "an http(s) url is a link that opens safely in a new tab", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(
               view,
               ~s|[data-field="site"] a[href="https://example.com/x?a=1"][rel="noopener noreferrer"][target="_blank"]|
             )
    end

    for {label, value} <- [
          {"javascript:", "javascript:alert(1)"},
          {"mixed-case javascript:", "JaVaScRiPt:alert(1)"},
          {"data:", "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="},
          {"vbscript:", "vbscript:msgbox(1)"},
          {"a space before the scheme", " https://example.com"},
          {"a scheme-less value", "example.com/page"}
        ] do
      test "a url with #{label} is plain text, never a link", %{conn: conn} = ctx do
        value = unquote(value)

        # Forge a row the write path may have let through: the view must not trust it.
        ctx.record
        |> Ecto.Changeset.change(data: Map.put(ctx.record.data, "site", value))
        |> TestRepo.update!()

        {:ok, view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

        refute has_element?(view, ~s|[data-field="site"] a|)
        assert has_element?(view, ~s|[data-field="site"] span|, String.trim(value))
        refute html =~ ~s|href="#{value}"|
      end
    end

    test "rich text renders as markup", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="body"] strong|, "text")
    end

    test "rich text is sanitized again on the way out", %{conn: conn} = ctx do
      # Forge a row the write path would have cleaned: the view must not trust it.
      bad = ~s|<p>ok</p><script>alert(1)</script>|

      ctx.record
      |> Ecto.Changeset.change(data: Map.put(ctx.record.data, "body", bad))
      |> TestRepo.update!()

      {:ok, _view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      refute html =~ "<script>alert(1)"
      assert html =~ "ok"
    end

    test "an image shows its thumbnail", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="cover"] img[src*="#{@media_uuid}"]|)
    end

    test "files list their names and sizes; non-map entries are skipped",
         %{conn: conn} = ctx do
      # The write path refuses a non-map file entry, so forge the row: the
      # view must still skip it.
      ctx.record
      |> Ecto.Changeset.change(
        data:
          Map.put(ctx.record.data, "docs", [
            %{"filename" => "spec.pdf", "size" => 2048},
            "stray-string-entry"
          ])
      )
      |> TestRepo.update!()

      {:ok, view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="docs"]|, "spec.pdf")
      assert html =~ "2.0 KB" or html =~ "2 KB" or html =~ "2048"
      refute html =~ "stray-string-entry"
    end

    test "a relation shows the linked record's title, not its uuid", %{conn: conn} = ctx do
      {:ok, view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="ref"]|, "Linked thing")
      refute html =~ ctx.target.uuid
    end

    test "empty values show a dash", %{conn: conn} = ctx do
      {:ok, bare} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Bare",
            slug: "bare",
            status: "draft",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, bare))

      assert has_element?(view, ~s|[data-field="name"]|, "—")
    end

    test "a trashed record is still viewable and flagged", %{conn: conn} = ctx do
      {:ok, _} = EntityData.update(ctx.record, %{status: "trashed"}, actor_uuid: ctx.actor_uuid)

      {:ok, _view, html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert html =~ "In trash"
    end
  end

  describe "navigation" do
    test "a linked record's title and trash status refresh without editing this record",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))
      {:ok, target} = EntityData.update(ctx.target, %{title: "New linked title"})
      assert has_element?(view, ~s|[data-field="ref"]|, "New linked title")

      {:ok, trashed} = EntityData.trash(target)
      assert has_element?(view, ~s|[data-field="ref"]|, "—")
      refute has_element?(view, ~s|[data-field="ref"]|, "New linked title")

      {:ok, _} = EntityData.restore_from_trash(trashed)
      assert has_element?(view, ~s|[data-field="ref"]|, "New linked title")
    end

    test "a relation to an already trashed target is hidden", %{conn: conn} = ctx do
      {:ok, _} = EntityData.trash(ctx.target)
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, ~s|[data-field="ref"]|, "—")
      refute has_element?(view, ~s|[data-field="ref"]|, "Linked thing")
    end

    test "Edit points at the edit form, Back at the entity's records",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      edit = Entities.admin_edit_path(ctx.entity, ctx.record)
      back = Routes.path("/admin/entities/ds_test/data")

      assert has_element?(view, ~s|a#data-show-edit[href="#{edit}"]|)
      assert has_element?(view, ~s|a#data-show-back[href="#{back}"]|)
    end

    test "a record viewed under another entity's URL is sent to its owner",
         %{conn: conn} = ctx do
      url = "/en/admin/entities/ds_target/data/#{ctx.record.uuid}"

      assert {:error, {:live_redirect, %{to: to}}} = live(admin_conn(conn, ctx), url)
      assert to =~ "/admin/entities/ds_test/data/#{ctx.record.uuid}"
    end

    test "an unknown record raises like the edit form does", %{conn: conn} = ctx do
      url = "/en/admin/entities/ds_test/data/#{Ecto.UUID.generate()}"

      assert_raise Ecto.NoResultsError, fn -> live(admin_conn(conn, ctx), url) end
    end

    test "a title change elsewhere refreshes the title and the page title", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))
      assert page_title(view) =~ "Hello"

      {:ok, _} = EntityData.update(ctx.record, %{title: "Renamed"}, actor_uuid: ctx.actor_uuid)

      assert render(view) =~ "Renamed"
      assert page_title(view) =~ "Renamed"
      refute page_title(view) =~ "Hello"
    end

    test "deleting this record elsewhere sends the viewer back to the list",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      {:ok, _} = EntityData.delete(ctx.record, actor_uuid: ctx.actor_uuid)

      assert_redirect(view, Routes.path("/admin/entities/ds_test/data"))
    end

    test "deleting another record leaves the view alone", %{conn: conn} = ctx do
      {:ok, other} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Other",
            slug: "other",
            status: "draft",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      {:ok, _} = EntityData.delete(other, actor_uuid: ctx.actor_uuid)

      assert render(view) =~ "Hello"
      refute_redirected(view, Routes.path("/admin/entities/ds_test/data"))
    end

    test "a record update elsewhere refreshes the view", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      {:ok, _} =
        EntityData.update(
          ctx.record,
          %{data: Map.put(ctx.record.data, "name", "Renamed Co")},
          actor_uuid: ctx.actor_uuid
        )

      assert render(view) =~ "Renamed Co"
    end
  end

  describe "markup" do
    test "headings sit outside the definition lists", %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))

      assert has_element?(view, "h3", "Section A")
      refute has_element?(view, "dl h3")
      refute has_element?(view, "dl > :not(div)")
      # every label is a <dt> with its value in a <dd>, one pair per field
      assert has_element?(view, ~s|dl > div[data-field="name"] > dt|)
      assert has_element?(view, ~s|dl > div[data-field="name"] > dd|)
    end

    test "fields before the first heading and between headings are all listed",
         %{conn: conn} = ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "ds_sections",
            display_name: "DS Sections",
            display_name_plural: "DS Sections",
            fields_definition: [
              %{"type" => "text", "key" => "a", "label" => "A"},
              %{"type" => "heading", "key" => "h1", "label" => "First"},
              %{"type" => "text", "key" => "b", "label" => "B"},
              %{"type" => "heading", "key" => "h2", "label" => "Empty section"},
              %{"type" => "heading", "key" => "h3", "label" => "Last"},
              %{"type" => "text", "key" => "c", "label" => "C"}
            ],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, record} =
        EntityData.create(
          %{
            entity_uuid: entity.uuid,
            title: "Sectioned",
            slug: "sectioned",
            status: "draft",
            data: %{"a" => "va", "b" => "vb", "c" => "vc"},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(entity, record))

      for {key, value} <- [{"a", "va"}, {"b", "vb"}, {"c", "vc"}] do
        assert has_element?(view, ~s|dl > div[data-field="#{key}"]|, value)
      end

      for heading <- ["First", "Empty section", "Last"] do
        assert has_element?(view, "h3", heading)
      end
    end
  end

  describe "choice fields and blueprint changes" do
    setup %{actor_uuid: actor_uuid} do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "ds_choice",
            display_name: "DS Choice",
            display_name_plural: "DS Choices",
            fields_definition: [
              %{
                "type" => "select",
                "key" => "size",
                "label" => "Size",
                "options" => ["small", "large"],
                "translations" => %{"es" => %{"options" => %{"small" => "pequeño"}}}
              },
              %{
                "type" => "checkbox",
                "key" => "tags",
                "label" => "Tags",
                "options" => ["a", "b", "c"]
              },
              %{"type" => "radio", "key" => "tone", "label" => "Tone", "options" => ["x", "y"]}
            ],
            status: "published",
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, record} =
        EntityData.create(
          %{
            entity_uuid: entity.uuid,
            title: "Choosy",
            slug: "choosy",
            status: "published",
            data: %{"size" => "small", "tags" => ["a", "c"], "tone" => ""},
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, choice_entity: entity, choice_record: record}
    end

    test "select, radio and checkbox values read as their option labels",
         %{conn: conn, choice_entity: entity, choice_record: record} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(entity, record))

      assert has_element?(view, ~s|[data-field="size"]|, "small")
      assert has_element?(view, ~s|[data-field="tags"]|, "a, c")
      # an empty radio is a dash, not a blank cell
      assert has_element?(view, ~s|[data-field="tone"]|, "—")
    end

    test "a secondary locale resolves option labels and preserves navigation paths",
         %{conn: conn, choice_entity: entity, choice_record: record} = ctx do
      conn =
        conn
        |> admin_conn(ctx)
        |> Plug.Test.init_test_session(%{
          "phoenix_kit_test_locale" => "es-ES",
          "phoenix_kit_test_locale_base" => "es"
        })

      {:ok, view, html} = live(conn, show_url(entity, record))
      assert has_element?(view, ~s|[data-field="size"]|, "pequeño")

      back = Routes.path("/admin/entities/#{entity.name}/data", locale: "es")
      section = Routes.path("/admin/entities", locale: "es")
      edit = Entities.admin_edit_path(entity, record, locale: "es")
      assert has_element?(view, ~s|#data-show-back[href="#{back}"]|)
      assert has_element?(view, ~s|#data-show-edit[href="#{edit}"]|)
      assert %{section: {"Entities", ^section}, crumbs: [{_, ^back}, _]} = page_trail(html)

      {:ok, _} = EntityData.delete(record)
      assert_redirect(view, back)
    end

    test "secondary-language record values and titles are shown", %{conn: conn} = ctx do
      data = %{
        "_primary_language" => "en-US",
        "en-US" => %{"_title" => "Hello", "name" => "Primary name"},
        "es-ES" => %{"_title" => "Hola", "name" => "Nombre traducido"}
      }

      {:ok, _} = EntityData.update(ctx.record, %{data: data})

      conn =
        conn
        |> admin_conn(ctx)
        |> Plug.Test.init_test_session(%{
          "phoenix_kit_test_locale" => "es-ES",
          "phoenix_kit_test_locale_base" => "es"
        })

      {:ok, view, _html} = live(conn, show_url(ctx.entity, ctx.record))
      assert page_title(view) =~ "Hola"
      assert has_element?(view, ~s|[data-field="name"]|, "Nombre traducido")
      assert EntityData.get!(ctx.record.uuid).data == data
    end

    test "deleting a linked record removes its label without navigating away",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(ctx.entity, ctx.record))
      {:ok, _} = EntityData.delete(ctx.target)

      assert has_element?(view, ~s|[data-field="ref"]|, "—")
      assert render(view) =~ "Hello"
    end

    test "a schema change elsewhere refreshes the labels",
         %{conn: conn, choice_entity: entity, choice_record: record} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(entity, record))
      refute render(view) =~ "Dimension"

      fields =
        Enum.map(entity.fields_definition, fn
          %{"key" => "size"} = f -> Map.put(f, "label", "Dimension")
          f -> f
        end)

      {:ok, _} = Entities.update_entity(entity, %{fields_definition: fields})

      assert render(view) =~ "Dimension"
    end

    test "deleting the entity elsewhere sends the viewer to the entities list",
         %{conn: conn, choice_entity: entity, choice_record: record} = ctx do
      {:ok, view, _html} = live(admin_conn(conn, ctx), show_url(entity, record))

      send(view.pid, {:entity_deleted, entity.uuid})

      assert_redirect(view, Routes.path("/admin/entities"))
    end
  end

  describe "route and gate" do
    test "the view URL is the read-only page in both route blocks, not the edit form" do
      source = routes_source()

      assert length(Regex.scan(~r|:uuid",\s*PhoenixKitEntities\.Web\.DataShow,\s*:show|, source)) ==
               2

      refute source =~ ~r|:uuid",\s*PhoenixKitEntities\.Web\.DataForm,\s*:show|
    end

    test "core maps the view to the same permission key as the edit form" do
      assert Auth.permission_key_for_admin_view(DataShow, :show) == "entities"

      assert Auth.permission_key_for_admin_view(DataShow, :show) ==
               Auth.permission_key_for_admin_view(DataForm, :edit)
    end

    test "an admin holding \"entities\" may open it; one without may not; a non-admin may not" do
      # Core refuses every role while the module itself is switched off.
      {:ok, _} = Entities.enable_system()

      with_key = fake_scope(roles: ["Admin"], permissions: ["entities"])
      without_key = fake_scope(roles: ["Admin"], permissions: ["shop"])
      # Core counts any permission holder as an admin-area user, so a visitor
      # is one who holds no admin role and no permission at all.
      plain_user = fake_scope(roles: ["User"], permissions: [])

      assert Auth.can_access_admin_view?(with_key, DataShow, :show)
      refute Auth.can_access_admin_view?(without_key, DataShow, :show)
      refute Auth.can_access_admin_view?(plain_user, DataShow, :show)
      refute Auth.can_access_admin_view?(nil, DataShow, :show)
    end
  end

  defp routes_source, do: File.read!("lib/phoenix_kit_entities/routes.ex")

  defp admin_conn(conn, ctx), do: put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))

  defp show_url(entity, record), do: "/en/admin/entities/#{entity.name}/data/#{record.uuid}"
end
