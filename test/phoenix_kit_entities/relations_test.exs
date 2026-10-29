defmodule PhoenixKitEntities.RelationsTest do
  @moduledoc """
  The `relation` field type end to end below the UI: the write-path gate
  in `EntityData.changeset/2`, `EntityData.resolve_relations/3`, cleanup
  when a target is deleted, the `entities_allow_relations` setting, the
  admin picker's data, and the mirror's slug-based export/import.

  The fixture is the request that motivated the feature: panel sizes that
  are each sold in a subset of grades and thicknesses.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.LiveDataForm
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.FormBuilder
  alias PhoenixKitEntities.Mirror.Importer
  alias PhoenixKitEntities.Relations

  setup do
    actor = Ecto.UUID.generate()

    grade = entity!("rel_grade", "Grade", "Grades", [], actor)
    thickness = entity!("rel_thickness", "Thickness", "Thicknesses", [], actor)

    size =
      entity!(
        "rel_size",
        "Size",
        "Sizes",
        [
          FieldTypes.relation_field("grades", "Grades", grade.uuid, multiple: true),
          # Targets may be named instead of uuid'd (seeds, hand-written
          # definitions).
          FieldTypes.relation_field("thicknesses", "Thicknesses", "rel_thickness",
            multiple: true
          ),
          FieldTypes.relation_field("main_grade", "Main grade", grade.uuid)
        ],
        actor
      )

    {:ok, _} = Entities.update_sort_mode(grade, "manual")

    grades =
      for {code, position} <- [{"B/BB", 1}, {"BB/BB", 2}, {"CP/C", 3}],
          into: %{},
          do: {code, record!(grade, code, actor, position: position)}

    thin = record!(thickness, "12 mm", actor)

    %{actor: actor, grade: grade, thickness: thickness, size: size, grades: grades, thin: thin}
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
    {:ok, record} = create(entity, title, actor, attrs)
    record
  end

  defp create(entity, title, actor, attrs) do
    EntityData.create(
      Map.merge(
        %{
          entity_uuid: entity.uuid,
          title: title,
          slug: Slug.slugify(title) <> "-#{System.unique_integer([:positive])}",
          status: "published",
          created_by_uuid: actor
        },
        Map.new(attrs)
      ),
      actor_uuid: actor
    )
  end

  defp uuid(ctx, code), do: ctx.grades[code].uuid

  describe "registry and definitions" do
    test "relation is a registry type with target/multiple props" do
      assert "relation" in FieldTypes.list_types()

      assert FieldTypes.default_props("relation") == %{
               "target_entity" => nil,
               "allow_multiple" => false
             }

      assert FieldTypes.label_for("relation") == "Relation"
    end

    test "FieldTypes.validate_field requires a target" do
      field = %{"type" => "relation", "key" => "g", "label" => "G"}
      assert {:error, :missing_target_entity} = FieldTypes.validate_field(field)

      assert {:ok, _} =
               FieldTypes.validate_field(Map.put(field, "target_entity", Ecto.UUID.generate()))
    end

    test "entities_allow_relations off: no new relation field, existing ones keep working",
         ctx do
      {:ok, _} = Settings.update_setting("entities_allow_relations", "false")
      on_exit(fn -> Settings.update_setting("entities_allow_relations", "true") end)

      field = FieldTypes.relation_field("grade", "Grade", ctx.grade.uuid)

      assert {:error, changeset} =
               Entities.create_entity(%{
                 name: "rel_blocked",
                 display_name: "Blocked",
                 display_name_plural: "Blocked",
                 fields_definition: [field],
                 created_by_uuid: ctx.actor
               })

      assert [message] = errors_on(changeset)[:fields_definition]
      assert message =~ "turned off"

      # The size entity already has its relation fields: editing it is fine.
      assert {:ok, _} = Entities.update_entity(ctx.size, %{description: "Still editable"})
    end
  end

  describe "writes" do
    test "stores uuids in canonical shape", ctx do
      bb = uuid(ctx, "BB/BB")

      assert {:ok, size} =
               create(ctx.size, "2500x1250", ctx.actor,
                 data: %{
                   # A single uuid for a multiple field, a duplicate, and the
                   # empty entry an empty checkbox list submits.
                   "grades" => ["", bb, bb, uuid(ctx, "B/BB")],
                   "thicknesses" => ctx.thin.uuid,
                   "main_grade" => [bb]
                 }
               )

      assert size.data["grades"] == [bb, uuid(ctx, "B/BB")]
      assert size.data["thicknesses"] == [ctx.thin.uuid]
      assert size.data["main_grade"] == bb
    end

    test "refuses a uuid that is not a record of the target", ctx do
      assert {:error, cs} =
               create(ctx.size, "Wrong", ctx.actor, data: %{"grades" => [ctx.thin.uuid]})

      assert [message] = errors_on(cs)[:data]
      assert message =~ "can only link to Grades records"

      assert {:error, _} =
               create(ctx.size, "Missing", ctx.actor, data: %{"grades" => [Ecto.UUID.generate()]})
    end

    test "refuses junk shapes and two links in a single field", ctx do
      assert {:error, cs} = create(ctx.size, "Junk", ctx.actor, data: %{"grades" => ["B/BB"]})
      assert [message] = errors_on(cs)[:data]
      assert message =~ "must link to records by their id"

      assert {:error, cs} =
               create(ctx.size, "Two", ctx.actor,
                 data: %{"main_grade" => [uuid(ctx, "B/BB"), uuid(ctx, "CP/C")]}
               )

      assert [message] = errors_on(cs)[:data]
      assert message =~ "one record only"
    end

    test "a new link to a trashed record is refused; an existing one survives", ctx do
      cp = ctx.grades["CP/C"]
      size = record!(ctx.size, "Keeps link", ctx.actor, data: %{"grades" => [cp.uuid]})

      {:ok, _} = EntityData.trash(cp)

      assert {:ok, updated} = EntityData.update(size, %{title: "Renamed"})
      assert updated.data["grades"] == [cp.uuid]

      assert {:error, cs} =
               create(ctx.size, "New link", ctx.actor, data: %{"grades" => [cp.uuid]})

      assert [message] = errors_on(cs)[:data]
      assert message =~ "trash"
    end

    test "required relation refuses no link", ctx do
      {:ok, entity} =
        Entities.update_entity(ctx.size, %{
          fields_definition: [
            ctx.size.fields_definition |> hd() |> Map.put("required", true)
          ]
        })

      assert {:error, _} = create(entity, "None", ctx.actor, data: %{"grades" => []})
      assert {:error, %{"grades" => _}} = FormBuilder.validate_data(entity, %{"grades" => [""]})
    end

    test "links live in the primary language only", ctx do
      bb = uuid(ctx, "BB/BB")

      assert {:ok, size} =
               create(ctx.size, "Multilang", ctx.actor,
                 data: %{
                   "_primary_language" => "en-US",
                   "en-US" => %{"grades" => [bb]},
                   "et-EE" => %{"grades" => [uuid(ctx, "CP/C")]}
                 }
               )

      assert size.data["en-US"]["grades"] == [bb]
      refute Map.has_key?(size.data["et-EE"], "grades")
    end
  end

  describe "FormBuilder (DB-free)" do
    test "validate_data casts relation values; secondary languages skip them", ctx do
      bb = uuid(ctx, "BB/BB")

      assert {:ok, %{"grades" => [^bb], "main_grade" => nil}} =
               FormBuilder.validate_data(ctx.size, %{
                 "grades" => ["", bb],
                 "main_grade" => ""
               })

      assert {:error, %{"grades" => [_]}} =
               FormBuilder.validate_data(ctx.size, %{"grades" => ["not-a-uuid"]})

      assert {:ok, data} =
               FormBuilder.validate_data(ctx.size, %{"grades" => [bb]}, "zz-secondary")

      refute Map.has_key?(data, "grades")
    end

    test "cast_field normalizes like the form does", ctx do
      field = hd(ctx.size.fields_definition)
      bb = uuid(ctx, "BB/BB")
      assert {:ok, [^bb]} = FormBuilder.cast_field(field, bb)
      assert {:ok, []} = FormBuilder.cast_field(field, [""])
    end
  end

  describe "resolve_relations/3" do
    setup ctx do
      small =
        record!(ctx.size, "Small", ctx.actor,
          data: %{
            # Stored out of the grades' own order on purpose.
            "grades" => [uuid(ctx, "CP/C"), uuid(ctx, "B/BB")],
            "thicknesses" => [ctx.thin.uuid]
          }
        )

      big = record!(ctx.size, "Big", ctx.actor, data: %{"grades" => [uuid(ctx, "BB/BB")]})
      none = record!(ctx.size, "None", ctx.actor, data: %{})
      %{small: small, big: big, none: none}
    end

    test "loads links for many records, in the target's order", ctx do
      result = EntityData.resolve_relations([ctx.small, ctx.big, ctx.none], "grades")

      assert Enum.map(result[ctx.small.uuid], & &1.title) == ["B/BB", "CP/C"]
      assert Enum.map(result[ctx.big.uuid], & &1.title) == ["BB/BB"]
      assert result[ctx.none.uuid] == []
    end

    test "one record, a named target, and trashed targets skipped", ctx do
      assert [%{title: "12 mm"}] = EntityData.resolve_relations(ctx.small, "thicknesses")

      {:ok, _} = EntityData.trash(ctx.grades["CP/C"])
      assert [%{title: "B/BB"}] = EntityData.resolve_relations(ctx.small, "grades")
    end

    test ":statuses filters the linked records", ctx do
      {:ok, _} = EntityData.update(ctx.grades["B/BB"], %{status: "draft"})

      assert [%{title: "CP/C"}] =
               EntityData.resolve_relations(ctx.small, "grades", statuses: ["published"])
    end

    test "raises on a key that is not a relation field", ctx do
      assert_raise ArgumentError, fn -> EntityData.resolve_relations(ctx.small, "nope") end
    end

    test "one query per target however many records", ctx do
      records = [ctx.small, ctx.big, ctx.none]
      ref = make_ref()
      handler = "rel-query-count-#{inspect(ref)}"
      parent = self()

      :telemetry.attach(
        handler,
        [:phoenix_kit_entities, :test, :repo, :query],
        fn _event, _measure, meta, _ ->
          if meta.source == "phoenix_kit_entity_data", do: send(parent, {ref, :query})
        end,
        nil
      )

      try do
        EntityData.resolve_relations(records, "grades")
      after
        :telemetry.detach(handler)
      end

      assert_received {^ref, :query}
      refute_received {^ref, :query}
    end
  end

  describe "deleting a target" do
    test "a permanent delete removes the link everywhere", ctx do
      bb = ctx.grades["BB/BB"]

      size =
        record!(ctx.size, "Linked", ctx.actor,
          data: %{"grades" => [bb.uuid, uuid(ctx, "B/BB")], "main_grade" => bb.uuid}
        )

      assert EntityData.count_relation_references(bb) == 1

      {:ok, _} = EntityData.delete(bb)

      fresh = EntityData.get(size.uuid)
      assert fresh.data["grades"] == [uuid(ctx, "B/BB")]
      assert fresh.data["main_grade"] == nil
    end

    test "bulk delete prunes too; trashing does not", ctx do
      cp = ctx.grades["CP/C"]
      size = record!(ctx.size, "Bulk", ctx.actor, data: %{"grades" => [cp.uuid]})

      {:ok, _} = EntityData.trash(cp)
      assert EntityData.get(size.uuid).data["grades"] == [cp.uuid]

      assert {1, nil} = EntityData.bulk_delete([cp.uuid])
      assert EntityData.get(size.uuid).data["grades"] == []
    end
  end

  describe "admin picker data" do
    test "small targets list every live record; linked trashed ones keep a label", ctx do
      cp = ctx.grades["CP/C"]
      {:ok, _} = EntityData.trash(cp)

      contexts = Relations.picker_contexts(ctx.size, %{"grades" => [cp.uuid]})

      assert %{mode: :list, options: options, labels: labels} = contexts["grades"]
      assert Enum.map(options, & &1.title) == ["B/BB", "BB/BB"]
      assert labels[cp.uuid].status == "trashed"
      assert %{mode: :list} = contexts["thicknesses"]
    end

    test "big targets switch to search", ctx do
      for n <- 1..Relations.list_limit(), do: record!(ctx.thickness, "T#{n}", ctx.actor)

      assert %{mode: :search} = Relations.picker_contexts(ctx.size, %{})["thicknesses"]

      field = Enum.find(ctx.size.fields_definition, &(&1["key"] == "thicknesses"))
      {rows, more?} = Relations.search(field, "T1", 5)
      assert length(rows) == 5
      assert more?
      assert Enum.all?(rows, &String.starts_with?(&1.label, "T1"))

      {rows, _} = Relations.search(field, "12 mm", 5, [ctx.thin.uuid])
      assert rows == []
    end

    test "a missing target entity", ctx do
      data = %{}
      entity = %{ctx.size | fields_definition: [FieldTypes.relation_field("x", "X", "gone")]}
      assert %{"x" => %{mode: :missing}} = Relations.picker_contexts(entity, data)
    end
  end

  describe "mirror export/import" do
    setup do
      user_uuid = Ecto.UUID.generate()

      {:ok, _} =
        Repo.query(
          "INSERT INTO phoenix_kit_users (uuid, email, hashed_password, is_active, account_type, inserted_at, updated_at) " <>
            "VALUES ($1::uuid, $2, $3, true, 'person', NOW(), NOW()) ON CONFLICT (uuid) DO NOTHING",
          [Ecto.UUID.dump!(user_uuid), "relations-test@example.com", valid_test_password_hash()]
        )

      :ok
    end

    test "exports targets by name and links by slug", ctx do
      bb = ctx.grades["BB/BB"]
      size = record!(ctx.size, "Export", ctx.actor, data: %{"grades" => [bb.uuid]})

      [field | _] = Relations.export_fields(ctx.size.fields_definition)
      assert field["target_entity"] == "rel_grade"

      assert [%{"grades" => [%{"slug" => slug}]}] = Relations.export_data(ctx.size, [size.data])
      assert slug == bb.slug
    end

    test "imports links whatever order the files come in" do
      # A fresh pair: the source's file is imported BEFORE its target's.
      source = %{
        "definition" => %{
          "name" => "rel_imp_size",
          "display_name" => "Imported size",
          "display_name_plural" => "Imported sizes",
          "fields_definition" => [
            FieldTypes.relation_field("grades", "Grades", "rel_imp_grade", multiple: true)
          ]
        },
        "data" => [
          %{
            "title" => "Imported",
            "slug" => "imported",
            "data" => %{"grades" => [%{"slug" => "a"}, %{"slug" => "b"}]}
          }
        ]
      }

      target = %{
        "definition" => %{
          "name" => "rel_imp_grade",
          "display_name" => "Imported grade",
          "display_name_plural" => "Imported grades",
          "fields_definition" => []
        },
        "data" => [
          %{"title" => "A", "slug" => "a", "data" => %{}},
          %{"title" => "B", "slug" => "b", "data" => %{}}
        ]
      }

      # Per file, the source's links cannot resolve yet: they are left out
      # rather than failing the record.
      assert {:ok, %{data: [{:ok, :created, record}], unresolved_links: [unresolved]}} =
               Importer.import_from_data(source, :skip)

      assert record.data["grades"] == []
      assert %{slug: "imported", field: "grades", refs: [_, _]} = unresolved

      assert {:ok, _} = Importer.import_from_data(target, :skip)

      # A second run of the source (what `import_all/1`'s final pass does
      # across files) fills them in and points the field at the uuid.
      assert {:ok, _} = Importer.import_from_data(source, :overwrite)

      entity = Entities.get_entity_by_name("rel_imp_size")
      assert [field] = entity.fields_definition
      assert field["target_entity"] == Entities.get_entity_by_name("rel_imp_grade").uuid

      imported = EntityData.get_by_slug(entity.uuid, "imported")

      assert imported
             |> EntityData.resolve_relations("grades")
             |> Enum.map(& &1.title)
             |> Enum.sort() == ["A", "B"]
    end
  end

  # Regression tests from the Codex review (dev_docs/2026-09-27-relations-codex-review.md).
  describe "review regressions" do
    setup ctx do
      user_uuid = Ecto.UUID.generate()

      {:ok, _} =
        Repo.query(
          "INSERT INTO phoenix_kit_users (uuid, email, hashed_password, is_active, account_type, inserted_at, updated_at) " <>
            "VALUES ($1::uuid, $2, $3, true, 'person', NOW(), NOW()) ON CONFLICT (uuid) DO NOTHING",
          [Ecto.UUID.dump!(user_uuid), "relations-review@example.com", valid_test_password_hash()]
        )

      field = FieldTypes.relation_field("links", "Links", ctx.grade.uuid, multiple: true)
      %{field: field}
    end

    test "#4 a required relation refuses the empty hidden-input list", ctx do
      source =
        entity!("rev_required", "Req", "Reqs", [Map.put(ctx.field, "required", true)], ctx.actor)

      assert {:error, cs} = create(source, "Blank", ctx.actor, data: %{"links" => [""]})
      assert [message] = errors_on(cs)[:data]
      assert message =~ "required"

      single =
        entity!(
          "rev_required_one",
          "Req one",
          "Req ones",
          [FieldTypes.relation_field("one", "One", ctx.grade.uuid) |> Map.put("required", true)],
          ctx.actor
        )

      assert {:error, _} = create(single, "Blank", ctx.actor, data: %{"one" => [""]})
    end

    test "#5 a stale copy saved after a permanent delete does not bring the link back", ctx do
      source = entity!("rev_stale", "Stale", "Stales", [ctx.field, text_field()], ctx.actor)
      cp = ctx.grades["CP/C"]

      record =
        record!(source, "Stale", ctx.actor,
          data: %{"links" => [cp.uuid, uuid(ctx, "B/BB")], "note" => "before"}
        )

      {:ok, _} = EntityData.delete(cp)

      assert {:ok, saved} =
               EntityData.update(record, %{data: Map.put(record.data, "note", "after")})

      assert saved.data["links"] == [uuid(ctx, "B/BB")]

      assert EntityData.get(record.uuid).data == %{
               "links" => [uuid(ctx, "B/BB")],
               "note" => "after"
             }
    end

    test "#5 a link to a missing record the copy never held is still refused", ctx do
      source = entity!("rev_stale2", "Stale", "Stales", [ctx.field], ctx.actor)
      record = record!(source, "Stale", ctx.actor, data: %{"links" => []})

      assert {:error, _} =
               EntityData.update(record, %{data: %{"links" => [Ecto.UUID.generate()]}})
    end

    test "#2 pruning edits the current value, not a snapshot of the whole map", ctx do
      source = entity!("rev_prune", "Prune", "Prunes", [ctx.field, text_field()], ctx.actor)
      cp = ctx.grades["CP/C"]

      record =
        record!(source, "Prune", ctx.actor, data: %{"links" => [cp.uuid], "note" => "before"})

      # Once the candidate rows are read, another write lands before the prune's own.
      handler = "rev-prune-#{System.unique_integer([:positive])}"
      marker = make_ref()
      Process.put(marker, true)

      :telemetry.attach(
        handler,
        [:phoenix_kit_entities, :test, :repo, :query],
        fn _, _, meta, _ ->
          if String.starts_with?(meta.query, "SELECT") and
               String.contains?(meta.query, "::text ~") and
               Process.delete(marker) do
            Repo.query!(
              "UPDATE phoenix_kit_entity_data SET data = jsonb_set(data, '{note}', '\"after\"') WHERE uuid = $1",
              [Ecto.UUID.dump!(record.uuid)]
            )
          end
        end,
        nil
      )

      try do
        {:ok, _} = EntityData.delete(cp)
      after
        :telemetry.detach(handler)
      end

      assert EntityData.get(record.uuid).data == %{"links" => [], "note" => "after"}
    end

    test "#2 pruning a multilang record touches only the primary language's link", ctx do
      cp = ctx.grades["CP/C"]

      size =
        record!(ctx.size, "Multilang prune", ctx.actor,
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"grades" => [cp.uuid, uuid(ctx, "B/BB")], "main_grade" => cp.uuid},
            "et-EE" => %{"_title" => "Mitmekeelne"}
          }
        )

      {:ok, _} = EntityData.delete(cp)

      data = EntityData.get(size.uuid).data
      assert data["en-US"] == %{"grades" => [uuid(ctx, "B/BB")], "main_grade" => nil}
      assert data["et-EE"] == %{"_title" => "Mitmekeelne"}
    end

    test "#3 required links import in any order, cycles included" do
      field =
        FieldTypes.relation_field("links", "Links", "rev_self", multiple: true)
        |> Map.put("required", true)

      payload = %{
        "definition" => %{
          "name" => "rev_self",
          "display_name" => "Self",
          "display_name_plural" => "Selves",
          "fields_definition" => [field]
        },
        "data" => [
          %{
            "title" => "First",
            "slug" => "first",
            "data" => %{"links" => [%{"slug" => "second"}]}
          },
          %{
            "title" => "Second",
            "slug" => "second",
            "data" => %{"links" => [%{"slug" => "first"}]}
          }
        ]
      }

      assert {:ok,
              %{data: [{:ok, :created, first}, {:ok, :created, second}], unresolved_links: []}} =
               Importer.import_from_data(payload, :skip)

      assert first.data["links"] == [second.uuid]
      assert second.data["links"] == [first.uuid]
    end

    test "#3 a record that fails takes the records linking to it along, and nothing else" do
      field = FieldTypes.relation_field("links", "Links", "rev_chain", multiple: true)

      payload = %{
        "definition" => %{
          "name" => "rev_chain",
          "display_name" => "Chain",
          "display_name_plural" => "Chains",
          "fields_definition" => [field]
        },
        "data" => [
          # No title: invalid, never written.
          %{"title" => nil, "slug" => "broken", "data" => %{}},
          %{
            "title" => "Links broken",
            "slug" => "a",
            "data" => %{"links" => [%{"slug" => "broken"}]}
          },
          %{"title" => "Links a", "slug" => "b", "data" => %{"links" => [%{"slug" => "a"}]}},
          %{"title" => "Alone", "slug" => "c", "data" => %{"links" => []}}
        ]
      }

      assert {:ok, %{data: [broken, a, b, c]}} = Importer.import_from_data(payload, :skip)
      assert {:error, {:validation_failed, _}} = broken
      assert {:error, {:broken_links, [_]}} = a
      assert {:error, {:broken_links, [_]}} = b
      assert {:ok, :created, _} = c

      entity = Entities.get_entity_by_name("rev_chain")
      assert [%{slug: "c"}] = EntityData.list_by_entity(entity.uuid)
    end

    test "#1 a search pick keeps the saved answers of fields it did not touch", ctx do
      source =
        entity!(
          "rev_pick",
          "Pick",
          "Picks",
          [
            ctx.field,
            %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
          ],
          ctx.actor
        )

      record = record!(source, "Pick", ctx.actor, data: %{"tools" => ["Hammer"]})
      socket = live_data_form(record, source)

      {:noreply, _} =
        LiveDataForm.handle_event(
          "relation_pick",
          %{"id" => "relation-picker-#{record.uuid}-links", "uuid" => uuid(ctx, "B/BB")},
          socket
        )

      assert EntityData.get(record.uuid).data == %{
               "links" => [uuid(ctx, "B/BB")],
               "tools" => ["Hammer"]
             }
    end

    @tag :capture_log
    test "#6 an unsaved pick survives the parent re-rendering the component", ctx do
      source = entity!("rev_pending", "Pending", "Pendings", [ctx.field], ctx.actor)
      record = record!(source, "Pending", ctx.actor, data: %{})

      # A required field added later: the pick's own save is refused.
      {:ok, source} =
        Entities.update_entity(source, %{
          fields_definition: [ctx.field, Map.put(text_field(), "required", true)]
        })

      assigns = %{id: "rev-pending", record: %{record | entity: source}, mode: :edit}
      socket = live_data_form(record, source, assigns)

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "relation_pick",
          %{"id" => "relation-picker-#{record.uuid}-links", "uuid" => uuid(ctx, "B/BB")},
          socket
        )

      assert form_links(socket) == [uuid(ctx, "B/BB")]
      refute EntityData.get(record.uuid).data["links"]

      {:ok, socket} = LiveDataForm.update(assigns, socket)
      assert form_links(socket) == [uuid(ctx, "B/BB")]

      # Removing it again is kept the same way.
      {:noreply, socket} =
        LiveDataForm.handle_event(
          "relation_remove",
          %{"key" => "links", "uuid" => uuid(ctx, "B/BB")},
          socket
        )

      {:ok, socket} = LiveDataForm.update(assigns, socket)
      assert form_links(socket) == []
    end
  end

  defp text_field, do: %{"type" => "text", "key" => "note", "label" => "Note"}

  defp live_data_form(record, entity, assigns \\ nil) do
    assigns = assigns || %{id: "rev", record: %{record | entity: entity}, mode: :edit}

    {:ok, socket} =
      LiveDataForm.update(assigns, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    socket
  end

  defp form_links(socket),
    do: Ecto.Changeset.get_field(socket.assigns.form.source, :data)["links"]
end
