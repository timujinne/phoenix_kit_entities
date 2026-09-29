defmodule PhoenixKitEntities.Web.RelationFieldsLiveTest do
  @moduledoc """
  The `relation` field in the admin UI: the record form's two pickers
  (checkboxes/select for a small target, search + chips for a big one),
  the entity editor's relation settings, titles in the data browser and in
  `LiveDataForm`, and the delete-forever warning.
  """
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.LiveDataForm
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.Relations
  alias PhoenixKitEntities.Web.DataNavigator

  setup do
    actor = Ecto.UUID.generate()

    grade = entity!("rel_ui_grade", "Grade", "Grades", [], actor)
    thickness = entity!("rel_ui_thickness", "Thickness", "Thicknesses", [], actor)

    size =
      entity!(
        "rel_ui_size",
        "Size",
        "Sizes",
        [
          FieldTypes.relation_field("grades", "Grades", grade.uuid, multiple: true),
          FieldTypes.relation_field("main_grade", "Main grade", grade.uuid),
          FieldTypes.relation_field("thicknesses", "Thicknesses", thickness.uuid, multiple: true)
        ],
        actor
      )

    bb = record!(grade, "BB/BB", actor)
    cp = record!(grade, "CP/C", actor)

    # Past the list limit, so the thickness field gets the search picker.
    thicknesses =
      for n <- 1..(Relations.list_limit() + 1), do: record!(thickness, "T#{n} mm", actor)

    record = record!(size, "2500x1250", actor, data: %{"grades" => [bb.uuid]})

    %{
      actor: actor,
      grade: grade,
      size: size,
      bb: bb,
      cp: cp,
      thicknesses: thicknesses,
      record: record
    }
  end

  defp entity!(name, display, plural, fields, actor) do
    {:ok, entity} =
      Entities.create_entity(
        %{
          name: name,
          display_name: display,
          display_name_plural: plural,
          fields_definition: fields,
          status: "published",
          created_by_uuid: actor
        },
        actor_uuid: actor
      )

    entity
  end

  defp record!(entity, title, actor, attrs \\ []) do
    {:ok, record} =
      EntityData.create(
        Map.merge(
          %{
            entity_uuid: entity.uuid,
            title: title,
            status: "published",
            created_by_uuid: actor
          },
          Map.new(attrs)
        ),
        actor_uuid: actor
      )

    record
  end

  defp edit_url(entity, record), do: "/en/admin/entities/#{entity.name}/data/#{record.uuid}/edit"

  describe "record form" do
    test "a small target renders checkboxes (multiple) and a select (single) that save",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, html} = live(conn, edit_url(ctx.size, ctx.record))

      assert html =~ "BB/BB"
      assert html =~ "CP/C"
      assert html =~ ~r|type="checkbox"[^>]*value="#{ctx.bb.uuid}"[^>]*checked|

      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{
          "data" => %{
            "grades" => ["", ctx.bb.uuid, ctx.cp.uuid],
            "main_grade" => ctx.cp.uuid
          }
        }
      })
      |> render_submit()

      saved = EntityData.get(ctx.record.uuid)
      assert saved.data["grades"] == [ctx.bb.uuid, ctx.cp.uuid]
      assert saved.data["main_grade"] == ctx.cp.uuid
    end

    test "unticking every box clears the links", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, _html} = live(conn, edit_url(ctx.size, ctx.record))

      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{"data" => %{"grades" => [""]}}
      })
      |> render_submit()

      assert EntityData.get(ctx.record.uuid).data["grades"] == []
    end

    test "a big target searches, picks into chips, removes, and saves", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, html} = live(conn, edit_url(ctx.size, ctx.record))

      picker_id = "relation-picker-thicknesses"
      assert html =~ ~s|id="#{picker_id}"|

      render_hook(view, "relation_search", %{"q" => "T1", "limit" => 3, "id" => picker_id})

      assert_push_event(view, "relation_results", %{
        id: ^picker_id,
        q: "T1",
        results: [_, _, _] = rows,
        has_more: true
      })

      assert Enum.all?(rows, &String.starts_with?(&1.label, "T1"))

      [first, second | _] = ctx.thicknesses

      render_hook(view, "relation_pick", %{
        "id" => picker_id,
        "uuid" => first.uuid,
        "label" => "x"
      })

      assert_push_event(view, "relation_staged", %{id: ^picker_id})
      render_hook(view, "relation_pick", %{"id" => picker_id, "uuid" => second.uuid})

      html = render(view)
      assert html =~ first.title
      assert html =~ second.title

      render_hook(view, "relation_remove", %{"key" => "thicknesses", "uuid" => first.uuid})

      view |> form("#entity-data-form") |> render_submit()

      assert EntityData.get(ctx.record.uuid).data["thicknesses"] == [second.uuid]
    end

    test "a crafted link to another entity's record is refused on save", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, _html} = live(conn, edit_url(ctx.size, ctx.record))

      render_hook(view, "relation_pick", %{
        "id" => "relation-picker-thicknesses",
        "uuid" => ctx.bb.uuid
      })

      html = view |> form("#entity-data-form") |> render_submit()

      assert html =~ "can only link to Thicknesses records"
      refute EntityData.get(ctx.record.uuid).data["thicknesses"]
    end
  end

  describe "entity editor" do
    test "adds a relation field pointing at an entity", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.size.uuid}/edit")

      render_hook(view, "add_field", %{})
      html = render_hook(view, "update_field_form", %{"field" => %{"type" => "relation"}})
      assert html =~ "Links to"
      assert html =~ ~s|value="#{ctx.grade.uuid}"|

      html =
        render_hook(view, "save_field", %{
          "field" => %{
            "type" => "relation",
            "key" => "alt_grades",
            "label" => "Alt grades",
            "target_entity" => ctx.grade.uuid,
            "allow_multiple" => "true"
          }
        })

      assert html =~ "Links to many Grades"
    end

    test "refuses a relation field without a target", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.size.uuid}/edit")

      render_hook(view, "add_field", %{})

      html =
        render_hook(view, "save_field", %{
          "field" => %{"type" => "relation", "key" => "nowhere", "label" => "Nowhere"}
        })

      assert html =~ "Relation field requires a target entity"
    end
  end

  describe "data browser" do
    test "previews show titles, not uuids", ctx do
      [record] = EntityData.list_by_entity(ctx.size.uuid)
      labels = Relations.labels([record])

      preview =
        DataNavigator.format_data_preview(record, labels)

      assert preview =~ "BB/BB"
      refute preview =~ ctx.bb.uuid
    end

    test "delete forever warns how many records link to a trashed record",
         %{conn: conn} = ctx do
      {:ok, _} = EntityData.trash(ctx.bb)
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor))

      {:ok, _view, html} =
        live(conn, "/en/admin/entities/#{ctx.grade.name}/data?status=trashed")

      assert html =~ "1 record links to it"
    end
  end

  describe "LiveDataForm" do
    test "readonly shows titles; edit renders the picker", ctx do
      record = EntityData.get(ctx.record.uuid)

      readonly =
        render_component(LiveDataForm, %{id: "rel-ro", record: record, mode: :readonly})

      assert readonly =~ "BB/BB"
      refute readonly =~ ctx.bb.uuid

      edit = render_component(LiveDataForm, %{id: "rel-edit", record: record, mode: :edit})
      assert edit =~ ~r|type="checkbox"[^>]*value="#{ctx.bb.uuid}"[^>]*checked|
      assert edit =~ ~s|id="relation-picker-#{record.uuid}-thicknesses"|
    end
  end
end
