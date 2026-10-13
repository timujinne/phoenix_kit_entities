defmodule PhoenixKitEntities.EntityDataLifecycleRulesTest do
  @moduledoc """
  Rules of the record lifecycle that hold on every path: a restore returns
  a row to the status it was trashed from, a bulk status change is
  announced, and a new record's position never depends on the rows already
  there being well-formed.
  """
  use PhoenixKitEntities.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events

  @media_uuid "018f4e2a-7c1b-7d3e-9a4f-5b6c7d8e9f01"

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "rules_#{System.unique_integer([:positive])}",
          display_name: "Rules",
          display_name_plural: "Rules",
          status: "published",
          fields_definition: [
            %{"type" => "text", "key" => "name", "label" => "Name"},
            %{"type" => "date", "key" => "day", "label" => "Day"},
            %{"type" => "image", "key" => "pic", "label" => "Pic"},
            %{"type" => "file", "key" => "docs", "label" => "Docs"}
          ],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp record!(ctx, attrs \\ %{}) do
    {:ok, record} =
      EntityData.create(
        Map.merge(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "R#{System.unique_integer([:positive])}",
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          attrs
        ),
        actor_uuid: ctx.actor_uuid
      )

    record
  end

  defp trash(:single, record), do: {:ok, _} = EntityData.trash(record)
  defp trash(:bulk, record), do: {1, _} = EntityData.bulk_trash([record.uuid])

  defp restore(:single, record),
    do: {:ok, _} = record.uuid |> EntityData.get!() |> EntityData.restore_from_trash()

  defp restore(:bulk, record), do: {1, _} = EntityData.bulk_restore_from_trash([record.uuid])

  describe "trash then restore" do
    test "a stale restore cannot republish a record restored and archived meanwhile", ctx do
      record = record!(ctx, %{status: "published"})
      {:ok, stale} = EntityData.trash(record)
      {:ok, restored} = EntityData.restore_from_trash(stale)
      {:ok, _} = EntityData.update(restored, %{status: "archived"})

      assert EntityData.restore_from_trash(stale) == {:error, :not_trashed}
      assert EntityData.get!(record.uuid).status == "archived"
    end

    test "restore uses the latest stash and keeps metadata saved after the page opened", ctx do
      record = record!(ctx, %{status: "published"})
      {:ok, stale} = EntityData.trash(record)
      {:ok, restored} = EntityData.restore_from_trash(stale)
      {:ok, draft} = EntityData.update(restored, %{status: "draft"})
      {:ok, trashed} = EntityData.trash(draft)
      {:ok, _} = EntityData.update(trashed, %{metadata: Map.put(trashed.metadata, "note", "new")})

      assert {:ok, restored} = EntityData.restore_from_trash(stale)
      assert restored.status == "draft"
      assert restored.metadata == %{"note" => "new"}
      assert EntityData.get!(record.uuid).metadata == %{"note" => "new"}
    end

    for status <- ~w(draft published archived),
        trash <- [:single, :bulk],
        restore <- [:single, :bulk] do
      test "#{status}: #{trash} trash, #{restore} restore returns it to #{status}", ctx do
        record = record!(ctx, %{status: unquote(status), metadata: %{"source" => "public_form"}})

        trash(unquote(trash), record)
        trashed = EntityData.get!(record.uuid)
        assert trashed.status == "trashed"
        assert trashed.metadata["trashed_from_status"] == unquote(status)

        restore(unquote(restore), record)
        restored = EntityData.get!(record.uuid)
        assert restored.status == unquote(status)
        # The stash is consumed; the rest of the metadata is untouched.
        assert restored.metadata == %{"source" => "public_form"}
      end
    end

    for trash <- [:single, :bulk] do
      test "#{trash} trash from a stale page stashes the stored status, not the page's", ctx do
        stale = record!(ctx, %{status: "published", metadata: %{"source" => "public_form"}})

        {:ok, _} =
          EntityData.update(EntityData.get!(stale.uuid), %{
            status: "draft",
            metadata: %{"source" => "public_form", "note" => "added meanwhile"}
          })

        trash(unquote(trash), stale)

        trashed = EntityData.get!(stale.uuid)
        assert trashed.metadata["trashed_from_status"] == "draft"
        assert trashed.metadata["note"] == "added meanwhile"

        restore(:single, stale)
        assert EntityData.get!(stale.uuid).status == "draft"
      end
    end

    test "trashing from a page loaded before the row was trashed keeps the stash", ctx do
      stale = record!(ctx, %{status: "published"})
      trash(:single, EntityData.get!(stale.uuid))

      assert EntityData.trash(stale) == {:error, :already_trashed}
      assert EntityData.bulk_trash([stale.uuid]) == {0, nil}

      assert EntityData.get!(stale.uuid).metadata["trashed_from_status"] == "published"
    end

    for restore <- [:single, :bulk] do
      test "a trashed row with no stash comes back as a draft (#{restore})", ctx do
        record = record!(ctx)

        from(d in EntityData, where: d.uuid == ^record.uuid)
        |> Repo.update_all(set: [status: "trashed", metadata: nil])

        restore(unquote(restore), record)

        restored = EntityData.get!(record.uuid)
        assert restored.status == "draft"
      end

      test "a stash naming no restorable status comes back as a draft (#{restore})", ctx do
        record = record!(ctx)

        from(d in EntityData, where: d.uuid == ^record.uuid)
        |> Repo.update_all(
          set: [status: "trashed", metadata: %{"trashed_from_status" => "trashed"}]
        )

        restore(unquote(restore), record)

        assert EntityData.get!(record.uuid).status == "draft"
      end
    end
  end

  describe "bulk_update_status/3" do
    test "announces each changed record", ctx do
      [a, b] = [record!(ctx), record!(ctx)]
      Events.subscribe_to_entity_data(ctx.entity.uuid)

      assert {2, _} = EntityData.bulk_update_status([a.uuid, b.uuid], "archived")

      entity_uuid = ctx.entity.uuid
      for uuid <- [a.uuid, b.uuid], do: assert_received({:data_updated, ^entity_uuid, ^uuid})
    end
  end

  describe "the next position" do
    test "a row with a NULL position does not break the next create", ctx do
      first = record!(ctx)
      second = record!(ctx)
      assert {first.position, second.position} == {1, 2}

      from(d in EntityData, where: d.uuid == ^first.uuid)
      |> Repo.update_all(set: [position: nil])

      assert record!(ctx).position == 3
    end

    test "only NULL positions present still yields 1", ctx do
      first = record!(ctx)

      from(d in EntityData, where: d.uuid == ^first.uuid)
      |> Repo.update_all(set: [position: nil])

      assert record!(ctx).position == 1
    end

    test "creates running at once get distinct, gapless positions", ctx do
      positions =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> record!(ctx).position end) end)
        |> Task.await_many()

      assert Enum.sort(positions) == Enum.to_list(1..8)
    end

    # The sandbox runs every test on one connection and cannot race, so the
    # lock is held from a second, real connection and a create is watched
    # waiting for it — as `tree_lock_test.exs` does for the tree lock.
    test "a create waits for the entity's position lock", ctx do
      opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
      {:ok, conn} = Postgrex.start_link(opts)
      key = "phoenix_kit_entities:positions:#{ctx.entity.uuid}"
      Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

      create = Task.async(fn -> record!(ctx) end)
      assert Task.yield(create, 300) == nil

      Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [key])
      assert %EntityData{position: 1} = Task.await(create)
    end
  end

  describe "value shapes the changeset refuses on every path" do
    defp create_with(ctx, data) do
      EntityData.create(%{
        entity_uuid: ctx.entity.uuid,
        title: "Shape",
        created_by_uuid: ctx.actor_uuid,
        data: data
      })
    end

    for {key, value} <- [
          {"day", "9999-99-99"},
          {"day", "2026-02-30"},
          {"day", "2026-2-3"},
          {"pic", "../../../../../x"},
          {"pic", String.duplicate("a", 16)},
          {"docs", %{"a" => %{"b" => "c"}}},
          {"docs", "a.pdf"},
          {"docs", ["a.pdf"]},
          {"docs", [%{"filename" => %{"nested" => "x"}}]},
          {"docs", [%{"filename" => String.duplicate("z", 1025)}]},
          {"docs", List.duplicate(%{"filename" => "a.pdf"}, 51)}
        ] do
      test "#{key} = #{inspect(value, printable_limit: 20, limit: 2)}", ctx do
        assert {:error, changeset} =
                 create_with(ctx, %{unquote(key) => unquote(Macro.escape(value))})

        assert Keyword.has_key?(changeset.errors, :data)
      end
    end

    for {key, value} <- [
          {"day", "2026-02-28"},
          {"pic", @media_uuid},
          {"docs", []},
          {"docs", [%{"filename" => "a.pdf", "size" => 1024, "public" => true, "note" => nil}]}
        ] do
      test "#{key} = #{inspect(value)} is accepted", ctx do
        assert {:ok, record} = create_with(ctx, %{unquote(key) => unquote(Macro.escape(value))})
        assert record.data[unquote(key)] == unquote(Macro.escape(value))
      end
    end
  end
end
