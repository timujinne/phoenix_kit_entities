defmodule PhoenixKitEntities.EntityDataDeferNotifyTest do
  @moduledoc """
  `defer_notify: true` on `EntityData.create/2` and `update/3`, and
  `EntityData.notify_committed/2`: a caller writing inside a transaction of
  its own announces the record only after that transaction commits.
  """

  use PhoenixKitEntities.DataCase, async: false

  alias Ecto.UUID
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events

  setup do
    actor_uuid = UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "defer_notify_test",
          display_name: "Defer Notify Test",
          display_name_plural: "Defer Notify Tests",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    :ok = Events.subscribe_to_entity_data(entity.uuid)

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp attrs(ctx, n) do
    %{
      entity_uuid: ctx.entity.uuid,
      title: "Record #{n}",
      slug: "record-#{n}",
      status: "published",
      data: %{"name" => "Item #{n}"},
      created_by_uuid: ctx.actor_uuid
    }
  end

  test "a plain create announces the record at once", ctx do
    {:ok, record} = EntityData.create(attrs(ctx, 1), actor_uuid: ctx.actor_uuid)

    assert_received {:data_created, entity_uuid, data_uuid}
    assert {entity_uuid, data_uuid} == {ctx.entity.uuid, record.uuid}
  end

  test "a deferred create announces nothing until notify_committed/2", ctx do
    {:ok, record} =
      EntityData.create(attrs(ctx, 1), actor_uuid: ctx.actor_uuid, defer_notify: true)

    refute_received {:data_created, _, _}

    assert :ok = EntityData.notify_committed(record, :created)
    assert_received {:data_created, entity_uuid, data_uuid}
    assert {entity_uuid, data_uuid} == {ctx.entity.uuid, record.uuid}
  end

  test "a deferred update announces nothing until notify_committed/2", ctx do
    {:ok, record} = EntityData.create(attrs(ctx, 1), actor_uuid: ctx.actor_uuid)
    assert_received {:data_created, _, _}

    {:ok, updated} =
      EntityData.update(record, %{title: "Renamed"},
        actor_uuid: ctx.actor_uuid,
        defer_notify: true
      )

    refute_received {:data_updated, _, _}

    assert :ok = EntityData.notify_committed(updated, :updated)
    assert_received {:data_updated, entity_uuid, data_uuid}
    assert {entity_uuid, data_uuid} == {ctx.entity.uuid, record.uuid}
  end

  # The sandbox turns the caller's transaction into a savepoint, so these show
  # when the broadcast is sent relative to the caller's commit, not Postgres
  # visibility.
  test "inside the caller's transaction a plain create announces before the commit, a deferred one after",
       ctx do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, record} = EntityData.create(attrs(ctx, 1))
        assert_received {:data_created, _, uuid}
        assert uuid == record.uuid
        record
      end)

    {:ok, record} =
      Repo.transaction(fn ->
        {:ok, record} = EntityData.create(attrs(ctx, 2), defer_notify: true)
        refute_received {:data_created, _, _}
        record
      end)

    refute_received {:data_created, _, _}
    :ok = EntityData.notify_committed(record, :created)
    assert_received {:data_created, _, uuid}
    assert uuid == record.uuid
  end

  test "a rolled-back deferred create leaves nothing to announce", ctx do
    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               {:ok, _record} = EntityData.create(attrs(ctx, 3), defer_notify: true)
               Repo.rollback(:rolled_back)
             end)

    refute_received {:data_created, _, _}
    assert EntityData.get_by_slug(ctx.entity.uuid, "record-3") == nil
  end

  test "a deferred write still writes its activity entry", ctx do
    {:ok, record} =
      EntityData.create(attrs(ctx, 1), actor_uuid: ctx.actor_uuid, defer_notify: true)

    assert_activity_logged("entity_data.created",
      actor_uuid: ctx.actor_uuid,
      resource_uuid: record.uuid
    )

    {:ok, _} =
      EntityData.update(record, %{title: "Renamed"},
        actor_uuid: ctx.actor_uuid,
        defer_notify: true
      )

    assert_activity_logged("entity_data.updated",
      actor_uuid: ctx.actor_uuid,
      resource_uuid: record.uuid
    )
  end

  test "a deferred update under require_status announces nothing until notify_committed/2",
       ctx do
    {:ok, record} = EntityData.create(attrs(ctx, 1))
    assert_received {:data_created, _, _}

    {:ok, updated} =
      EntityData.update(record, %{title: "Renamed"},
        require_status: ["published"],
        defer_notify: true
      )

    refute_received {:data_updated, _, _}
    :ok = EntityData.notify_committed(updated, :updated)
    assert_received {:data_updated, _, uuid}
    assert uuid == record.uuid
  end

  test "nil is accepted and does nothing" do
    assert :ok = EntityData.notify_committed(nil, :created)
    refute_received {:data_created, _, _}
  end

  test "any other event raises ArgumentError instead of a FunctionClauseError", ctx do
    {:ok, record} = EntityData.create(attrs(ctx, 1), defer_notify: true)

    assert_raise ArgumentError, ~r/accepts only :created or :updated/, fn ->
      EntityData.notify_committed(record, :deleted)
    end

    refute_received {:data_created, _, _}
  end
end
