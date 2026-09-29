# Review-only regression probes: all six intentionally fail on the 0.5.0 handoff.
# Run explicitly: PGPOOL=6 mix test dev_docs/2026-09-27-relations-review-repro.exs
# Kept outside test/ so these do not change the normal suite.

defmodule PhoenixKitEntities.RelationsReviewTest do
  use PhoenixKitEntities.DataCase, async: false
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.{EntityData, FieldTypes}
  alias PhoenixKitEntities.Components.LiveDataForm
  alias PhoenixKitEntities.Mirror.Importer

  defp entity!(name, fields) do
    {:ok, entity} =
      Entities.create_entity(%{
        name: name,
        display_name: name,
        display_name_plural: name,
        fields_definition: fields,
        created_by_uuid: Ecto.UUID.generate()
      })

    entity
  end

  defp record!(entity, data, slug \\ nil) do
    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: "Review record",
        slug: slug,
        data: data,
        created_by_uuid: Ecto.UUID.generate()
      })

    record
  end

  setup do
    target = entity!("review_target", [])
    linked = record!(target, %{})
    field = FieldTypes.relation_field("links", "Links", target.uuid, multiple: true)
    %{target: target, linked: linked, field: field}
  end

  test "required relation rejects the hidden empty checkbox value", ctx do
    source = entity!("review_source", [Map.put(ctx.field, "required", true)])

    result =
      EntityData.create(%{
        entity_uuid: source.uuid,
        title: "Blank",
        data: %{"links" => [""]},
        created_by_uuid: Ecto.UUID.generate()
      })

    assert {:error, %Ecto.Changeset{}} = result
  end

  test "picking a relation preserves an unrelated checkbox value", ctx do
    source =
      entity!("review_source", [
        ctx.field,
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ])

    record = record!(source, %{"tools" => ["Hammer"]})

    {:ok, socket} =
      LiveDataForm.update(
        %{id: "review", record: %{record | entity: source}, mode: :edit},
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    {:noreply, _} =
      LiveDataForm.handle_event(
        "relation_pick",
        %{"id" => "relation-picker-#{record.uuid}-links", "uuid" => ctx.linked.uuid},
        socket
      )

    assert EntityData.get(record.uuid).data["links"] == [ctx.linked.uuid]
    assert EntityData.get(record.uuid).data["tools"] == ["Hammer"]
  end

  test "stale source form cannot resurrect a permanently deleted link", ctx do
    source =
      entity!("review_source", [
        ctx.field,
        %{"type" => "text", "key" => "note", "label" => "Note"}
      ])

    record = record!(source, %{"links" => [ctx.linked.uuid], "note" => "before"})
    {:ok, _} = EntityData.delete(ctx.linked)
    assert EntityData.get(record.uuid).data["links"] == []
    EntityData.update(record, %{data: Map.put(record.data, "note", "after")})
    assert EntityData.get(record.uuid).data["links"] == []
  end

  test "required forward reference imports when target record follows source in the same file" do
    user_uuid = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO phoenix_kit_users (uuid, email, hashed_password, is_active, account_type, inserted_at, updated_at) VALUES ($1::uuid, $2, $3, true, 'person', NOW(), NOW())",
      [Ecto.UUID.dump!(user_uuid), "review@example.com", valid_test_password_hash()]
    )

    field =
      FieldTypes.relation_field("links", "Links", "review_self", multiple: true)
      |> Map.put("required", true)

    payload = %{
      "definition" => %{
        "name" => "review_self",
        "display_name" => "Self",
        "display_name_plural" => "Selves",
        "fields_definition" => [field]
      },
      "data" => [
        %{"title" => "First", "slug" => "first", "data" => %{"links" => [%{"slug" => "second"}]}},
        %{"title" => "Second", "slug" => "second", "data" => %{"links" => [%{"slug" => "first"}]}}
      ]
    }

    {:ok, result} = Importer.import_from_data(payload, :skip)
    assert Enum.all?(result.data, &match?({:ok, :created, _}, &1))
  end

  test "pending picker selection survives an unchanged parent update", ctx do
    source = entity!("review_source", [ctx.field])
    record = record!(source, %{})

    {:ok, source} =
      Entities.update_entity(source, %{
        fields_definition: [
          ctx.field,
          %{"type" => "text", "key" => "required", "label" => "Required", "required" => true}
        ]
      })

    assigns = %{id: "review", record: %{record | entity: source}, mode: :edit}

    {:ok, socket} =
      LiveDataForm.update(assigns, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    {:noreply, socket} =
      LiveDataForm.handle_event(
        "relation_pick",
        %{"id" => "relation-picker-#{record.uuid}-links", "uuid" => ctx.linked.uuid},
        socket
      )

    assert Ecto.Changeset.get_field(socket.assigns.form.source, :data)["links"] == [
             ctx.linked.uuid
           ]

    {:ok, socket} = LiveDataForm.update(assigns, socket)

    assert Ecto.Changeset.get_field(socket.assigns.form.source, :data)["links"] == [
             ctx.linked.uuid
           ]
  end

  test "pruning preserves a write made after candidate selection", ctx do
    source =
      entity!("review_source", [
        ctx.field,
        %{"type" => "text", "key" => "note", "label" => "Note"}
      ])

    record = record!(source, %{"links" => [ctx.linked.uuid], "note" => "before"})
    handler = "review-prune-interleaving"
    marker = make_ref()
    Process.put(marker, true)

    :telemetry.attach(
      handler,
      [:phoenix_kit_entities, :test, :repo, :query],
      fn _, _, meta, _ ->
        if String.starts_with?(meta.query, "SELECT") and String.contains?(meta.query, "::text ~") and
             Process.delete(marker) do
          # Deterministically inject the competing write after SELECT has captured its result.
          # This models a committed concurrent writer; it is not a multi-connection test.
          Repo.query!(
            "UPDATE phoenix_kit_entity_data SET data = jsonb_set(data, '{note}', '\"after\"') WHERE uuid = $1",
            [Ecto.UUID.dump!(record.uuid)]
          )
        end
      end,
      nil
    )

    try do
      {:ok, _} = EntityData.delete(ctx.linked)
    after
      :telemetry.detach(handler)
      Process.delete(marker)
    end

    assert EntityData.get(record.uuid).data["links"] == []
    assert EntityData.get(record.uuid).data["note"] == "after"
  end
end
