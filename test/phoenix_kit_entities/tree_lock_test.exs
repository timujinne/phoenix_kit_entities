defmodule PhoenixKitEntities.TreeLockTest do
  @moduledoc """
  A re-parent holds the entity's tree lock through its cycle check, so two
  in opposite directions at once cannot both pass and commit a loop. The
  sandbox runs every test on one connection and cannot race, so this holds
  the lock from a second, real connection and watches a re-parent wait. That
  pins the key and that the lock is taken; the two-writer race itself was
  proved on a live node, not here.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKitEntities.EntityData

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp record!(entity, title) do
    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: title,
        status: "published",
        created_by_uuid: entity.created_by_uuid
      })

    record
  end

  setup do
    {:ok, entity} =
      PhoenixKitEntities.create_entity(%{
        name: "lock_#{System.unique_integer([:positive])}",
        display_name: "Lock",
        display_name_plural: "Locks",
        created_by_uuid: Ecto.UUID.generate()
      })

    %{entity: entity, key: "phoenix_kit_entities:tree:#{entity.uuid}"}
  end

  test "a re-parent waits for the tree lock; a rename does not", %{entity: entity, key: key} do
    [a, b] = [record!(entity, "A"), record!(entity, "B")]
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

    assert {:ok, a} = EntityData.update(a, %{title: "A2"})

    move = Task.async(fn -> EntityData.update(a, %{parent_uuid: b.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [key])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end

  test "the status-guarded write takes it too, whatever the caller's struct says", %{
    entity: entity,
    key: key
  } do
    [a, b] = [record!(entity, "A"), record!(entity, "B")]
    # The caller's copy says A is already under B; the row says it is not.
    stale = %{a | parent_uuid: b.uuid}
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

    move =
      Task.async(fn ->
        EntityData.update(stale, %{parent_uuid: b.uuid}, require_status: ["published"])
      end)

    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [key])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end
end
