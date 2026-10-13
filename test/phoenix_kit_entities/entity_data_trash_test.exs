defmodule PhoenixKitEntities.EntityDataTrashTest do
  @moduledoc """
  Soft-delete (trash) + restore + permanent-delete behaviour for
  EntityData. Pinned by issue #12: parent apps with FK columns
  pointing at `phoenix_kit_entity_data(uuid)` need a way to retire a
  record without invalidating those FKs. The soft-delete flow keeps
  the row alive so the FK stays satisfied; default list/search
  queries hide trashed rows; the trash bin surfaces them for restore
  or permanent deletion.
  """

  use PhoenixKitEntities.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.UUID
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.ActivityLogAssertions
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events

  import ActivityLogAssertions
  import Ecto.Query, only: [from: 2]

  setup do
    actor_uuid = UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "trash_test",
          display_name: "Trash Test",
          display_name_plural: "Trash Tests",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    records =
      for n <- 1..3 do
        {:ok, r} =
          EntityData.create(
            %{
              entity_uuid: entity.uuid,
              title: "Record #{n}",
              slug: "record-#{n}",
              status: "published",
              data: %{"name" => "Item #{n}"},
              created_by_uuid: actor_uuid
            },
            actor_uuid: actor_uuid
          )

        r
      end

    {:ok, entity: entity, records: records, actor_uuid: actor_uuid}
  end

  describe "trash/2" do
    test "flips status to trashed and logs entity_data.trashed", ctx do
      [record | _] = ctx.records

      assert {:ok, %EntityData{status: "trashed"}} =
               EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.trashed",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )
    end

    test "refuses with :already_trashed when called twice", ctx do
      [record | _] = ctx.records
      {:ok, trashed} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      assert {:error, :already_trashed} = EntityData.trash(trashed, actor_uuid: ctx.actor_uuid)
    end

    test "row stays in DB — get/1 still resolves the uuid (so parent FKs hold)", ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      assert %EntityData{uuid: same_uuid, status: "trashed"} = EntityData.get(record.uuid)
      assert same_uuid == record.uuid
    end

    test "trashed records hide from list_by_entity by default but surface with include_trashed",
         ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record)

      uuids_default = Enum.map(EntityData.list_by_entity(ctx.entity.uuid), & &1.uuid)

      uuids_with =
        Enum.map(EntityData.list_by_entity(ctx.entity.uuid, include_trashed: true), & &1.uuid)

      refute record.uuid in uuids_default
      assert record.uuid in uuids_with
    end

    test "single-arg trash/1 works (default opts)", ctx do
      [record | _] = ctx.records
      assert {:ok, %EntityData{status: "trashed"}} = EntityData.trash(record)
    end

    test "trash without actor_uuid still logs activity (actor_uuid falls back to creator)", ctx do
      [record | _] = ctx.records
      assert {:ok, _} = EntityData.trash(record)
      # log_data_activity uses entity_data.created_by_uuid as the fallback
      # actor when opts[:actor_uuid] is nil. This keeps the audit row
      # populated even on programmatic / system-triggered trashes.
      assert_activity_logged("entity_data.trashed",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )
    end

    test "broadcasts data_updated PubSub event after trash", ctx do
      [record | _] = ctx.records
      Events.subscribe_to_entity_data(ctx.entity.uuid)

      {:ok, _} = EntityData.trash(record)

      assert_receive {:data_updated, entity_uuid, data_uuid}, 1_000
      assert entity_uuid == ctx.entity.uuid
      assert data_uuid == record.uuid
    end

    test "date_updated bumps when trashing", ctx do
      [record | _] = ctx.records
      original = record.date_updated

      # Manually backdate so the change is observable on a second-precision
      # timestamp (dev_docs notes utc_datetime is second-precision; tests
      # near-instant inserts can collide).
      backdated = DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)

      from(d in EntityData, where: d.uuid == ^record.uuid)
      |> repo().update_all(set: [date_updated: backdated])

      reloaded = EntityData.get(record.uuid)
      assert {:ok, trashed} = EntityData.trash(reloaded)
      assert DateTime.compare(trashed.date_updated, original) in [:gt, :eq]
      refute DateTime.compare(trashed.date_updated, backdated) == :eq
    end
  end

  describe "restore_from_trash/2" do
    test "moves a trashed record back to published and logs entity_data.restored", ctx do
      [record | _] = ctx.records
      {:ok, trashed} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      assert {:ok, %EntityData{status: "published"}} =
               EntityData.restore_from_trash(trashed, actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.restored",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )
    end

    test "refuses with :not_trashed for a non-trashed record", ctx do
      [record | _] = ctx.records
      assert {:error, :not_trashed} = EntityData.restore_from_trash(record)
    end

    test "refuses :not_trashed for draft and archived records too (only trash→published)",
         ctx do
      [r1, r2, _] = ctx.records
      {:ok, draft} = EntityData.update(r1, %{status: "draft"})
      {:ok, archived} = EntityData.update(r2, %{status: "archived"})

      assert {:error, :not_trashed} = EntityData.restore_from_trash(draft)
      assert {:error, :not_trashed} = EntityData.restore_from_trash(archived)
    end

    test "single-arg restore_from_trash/1 works", ctx do
      [record | _] = ctx.records
      {:ok, trashed} = EntityData.trash(record)
      assert {:ok, %EntityData{status: "published"}} = EntityData.restore_from_trash(trashed)
    end

    test "broadcasts data_updated PubSub event after restore", ctx do
      [record | _] = ctx.records
      {:ok, trashed} = EntityData.trash(record)
      Events.subscribe_to_entity_data(ctx.entity.uuid)

      {:ok, _} = EntityData.restore_from_trash(trashed)

      assert_receive {:data_updated, entity_uuid, data_uuid}, 1_000
      assert entity_uuid == ctx.entity.uuid
      assert data_uuid == record.uuid
    end

    # `bulk_trash/2` stashes the previous status the way `trash/2` does, so
    # the single-record restore returns a bulk-trashed row to where it was.
    test "restores a bulk-trashed row to the status it was trashed from", ctx do
      [record | _] = ctx.records
      {1, _} = EntityData.bulk_trash([record.uuid], actor_uuid: ctx.actor_uuid)

      trashed = EntityData.get!(record.uuid)
      assert trashed.status == "trashed"
      assert trashed.metadata["trashed_from_status"] == "published"

      assert {:ok, %EntityData{status: "published"} = restored} =
               EntityData.restore_from_trash(trashed, actor_uuid: ctx.actor_uuid)

      refute Map.has_key?(restored.metadata, "trashed_from_status")
    end
  end

  describe "list_trashed_by_entity/2" do
    test "returns only trashed records, ordered by most recently updated", ctx do
      [r1, r2, r3] = ctx.records
      {:ok, _} = EntityData.trash(r1)
      {:ok, _} = EntityData.trash(r3)

      result = EntityData.list_trashed_by_entity(ctx.entity.uuid)
      uuids = Enum.map(result, & &1.uuid)

      assert r1.uuid in uuids
      assert r3.uuid in uuids
      refute r2.uuid in uuids
    end

    test "returns empty list when nothing is trashed", ctx do
      assert EntityData.list_trashed_by_entity(ctx.entity.uuid) == []
    end
  end

  describe "trashed_count/1 + count_by_entity/2" do
    test "trashed_count returns only trashed", ctx do
      [r1, r2, _r3] = ctx.records
      {:ok, _} = EntityData.trash(r1)
      {:ok, _} = EntityData.trash(r2)

      assert EntityData.trashed_count(ctx.entity.uuid) == 2
    end

    test "count_by_entity excludes trashed by default; include_trashed flips it", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      assert EntityData.count_by_entity(ctx.entity.uuid) == 2
      assert EntityData.count_by_entity(ctx.entity.uuid, include_trashed: true) == 3
    end
  end

  describe "get_data_stats/1" do
    test "exposes trashed_records and excludes them from total_records", ctx do
      [r1, r2, _r3] = ctx.records
      {:ok, _} = EntityData.trash(r1)
      {:ok, _} = EntityData.trash(r2)

      stats = EntityData.get_data_stats(ctx.entity.uuid)

      assert stats.trashed_records == 2
      assert stats.total_records == 1
      assert stats.published_records == 1
    end
  end

  describe "bulk_trash/2 + bulk_restore_from_trash/2" do
    test "bulk_trash flips selected records to trashed and logs ONE summary row", ctx do
      uuids = Enum.map(ctx.records, & &1.uuid)

      assert {3, _} = EntityData.bulk_trash(uuids, actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.bulk_trashed",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"count" => 3, "uuid_count" => 3}
      )

      Enum.each(uuids, fn uuid ->
        assert EntityData.get(uuid).status == "trashed"
      end)
    end

    test "bulk_trash skips already-trashed rows (count reflects only newly-trashed)", ctx do
      [r1 | rest] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids = [r1.uuid | Enum.map(rest, & &1.uuid)]
      assert {2, _} = EntityData.bulk_trash(uuids)
    end

    test "bulk_restore_from_trash flips trashed→published and logs ONE summary row", ctx do
      uuids = Enum.map(ctx.records, & &1.uuid)
      {3, _} = EntityData.bulk_trash(uuids, actor_uuid: ctx.actor_uuid)

      assert {3, _} = EntityData.bulk_restore_from_trash(uuids, actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.bulk_restored",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"count" => 3, "uuid_count" => 3}
      )

      Enum.each(uuids, fn uuid ->
        assert EntityData.get(uuid).status == "published"
      end)
    end

    test "bulk_restore_from_trash only touches trashed rows", ctx do
      [r1, _r2, _r3] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids = Enum.map(ctx.records, & &1.uuid)
      assert {1, _} = EntityData.bulk_restore_from_trash(uuids)
    end

    test "bulk_trash with empty list returns {0, _} and logs zero-count row", ctx do
      assert {0, _} = EntityData.bulk_trash([], actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.bulk_trashed",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"count" => 0, "uuid_count" => 0}
      )
    end

    test "bulk_restore_from_trash with empty list returns {0, _}", ctx do
      assert {0, _} = EntityData.bulk_restore_from_trash([], actor_uuid: ctx.actor_uuid)
    end

    test "bulk_trash broadcasts a data_updated event per affected entity", ctx do
      uuids = Enum.map(ctx.records, & &1.uuid)
      Events.subscribe_to_entity_data(ctx.entity.uuid)

      {3, _} = EntityData.bulk_trash(uuids)

      # We seeded 3 records on the same entity; expect 3 broadcasts.
      received =
        for _ <- 1..3 do
          assert_receive {:data_updated, _, uuid}, 1_000
          uuid
        end

      assert Enum.sort(received) == Enum.sort(uuids)
    end
  end

  describe "delete/2 — friendly Postgrex error" do
    test "succeeds when no parent rows reference the record", ctx do
      [record | _] = ctx.records
      assert {:ok, %EntityData{}} = EntityData.delete(record, actor_uuid: ctx.actor_uuid)
      refute EntityData.get(record.uuid)
    end

    test "returns :referenced_by_external when a parent FK violation occurs", ctx do
      # Simulate a parent app with a NOT NULL FK to phoenix_kit_entity_data.uuid:
      # set up a transient table within the sandbox transaction. This is the
      # exact shape the issue #12 author hit in their orders table.
      [record | _] = ctx.records

      SQL.query!(repo(), """
      CREATE TABLE _trash_test_parent (
        id serial primary key,
        status_uuid uuid NOT NULL REFERENCES phoenix_kit_entity_data(uuid) ON DELETE RESTRICT
      )
      """)

      SQL.query!(
        repo(),
        """
        INSERT INTO _trash_test_parent (status_uuid) VALUES ($1)
        """,
        [UUID.dump!(record.uuid)]
      )

      assert {:error, :referenced_by_external} =
               EntityData.delete(record, actor_uuid: ctx.actor_uuid)

      # Row stays in DB — soft-delete fallback path.
      assert %EntityData{} = EntityData.get(record.uuid)
    end

    test "bulk_delete returns :referenced_by_external on FK violation, no rows deleted", ctx do
      [record | _] = ctx.records

      SQL.query!(repo(), """
      CREATE TABLE _trash_test_parent_bulk (
        id serial primary key,
        status_uuid uuid NOT NULL REFERENCES phoenix_kit_entity_data(uuid) ON DELETE RESTRICT
      )
      """)

      SQL.query!(
        repo(),
        """
        INSERT INTO _trash_test_parent_bulk (status_uuid) VALUES ($1)
        """,
        [UUID.dump!(record.uuid)]
      )

      uuids = Enum.map(ctx.records, & &1.uuid)

      assert {:error, :referenced_by_external} =
               EntityData.bulk_delete(uuids, actor_uuid: ctx.actor_uuid)

      # Transaction rolled back — every record still exists.
      Enum.each(uuids, fn uuid ->
        assert %EntityData{} = EntityData.get(uuid)
      end)

      # Pin the audit row — covers the user-initiated bulk delete attempt
      # even though the DB rolled back. `db_pending: true` differentiates
      # this from a successful bulk_deleted row.
      assert_activity_logged("entity_data.bulk_deleted",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end

    test "delete/2 surfaces NOT NULL violation as :referenced_by_external (issue #12 case)",
         ctx do
      # Issue #12's documented setup: parent column NOT NULL with
      # `on_delete: :nilify_all`. PostgreSQL fires the on_delete action
      # (sets status_uuid to NULL), which then violates the NOT NULL
      # constraint, raising SQLSTATE 23502.
      [record | _] = ctx.records

      SQL.query!(repo(), """
      CREATE TABLE _trash_test_nilify_parent (
        id serial primary key,
        status_uuid uuid NOT NULL REFERENCES phoenix_kit_entity_data(uuid) ON DELETE SET NULL
      )
      """)

      SQL.query!(
        repo(),
        "INSERT INTO _trash_test_nilify_parent (status_uuid) VALUES ($1)",
        [UUID.dump!(record.uuid)]
      )

      assert {:error, :referenced_by_external} =
               EntityData.delete(record, actor_uuid: ctx.actor_uuid)

      assert %EntityData{} = EntityData.get(record.uuid)
    end

    test "delete/2 logs error activity row (db_pending: true) on FK violation", ctx do
      [record | _] = ctx.records

      SQL.query!(repo(), """
      CREATE TABLE _trash_test_audit_parent (
        id serial primary key,
        status_uuid uuid NOT NULL REFERENCES phoenix_kit_entity_data(uuid) ON DELETE RESTRICT
      )
      """)

      SQL.query!(
        repo(),
        "INSERT INTO _trash_test_audit_parent (status_uuid) VALUES ($1)",
        [UUID.dump!(record.uuid)]
      )

      {:error, :referenced_by_external} =
        EntityData.delete(record, actor_uuid: ctx.actor_uuid)

      assert_activity_logged("entity_data.deleted",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end
  end

  describe "default-list filtering" do
    test "list_all excludes trashed", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids = Enum.map(EntityData.list_all(), & &1.uuid)
      refute r1.uuid in uuids
    end

    test "search_by_title excludes trashed", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids =
        EntityData.search_by_title("Record", ctx.entity.uuid)
        |> Enum.map(& &1.uuid)

      refute r1.uuid in uuids
    end

    test "filter_by_status('trashed') returns only trashed", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids =
        EntityData.filter_by_status("trashed")
        |> Enum.map(& &1.uuid)

      assert r1.uuid in uuids
    end

    test "get_by_slug still finds trashed records (slug uniqueness preserved)", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      assert %EntityData{uuid: same_uuid} = EntityData.get_by_slug(ctx.entity.uuid, r1.slug)
      assert same_uuid == r1.uuid
    end

    test "list_all with include_trashed: true returns trashed records too", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids = Enum.map(EntityData.list_all(include_trashed: true), & &1.uuid)
      assert r1.uuid in uuids
    end

    test "search_by_title with include_trashed: true returns trashed", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids =
        EntityData.search_by_title("Record", ctx.entity.uuid, include_trashed: true)
        |> Enum.map(& &1.uuid)

      assert r1.uuid in uuids
    end

    test "list_by_entity_and_status('published') doesn't leak trashed", ctx do
      [r1 | _] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids =
        EntityData.list_by_entity_and_status(ctx.entity.uuid, "published")
        |> Enum.map(& &1.uuid)

      refute r1.uuid in uuids
    end

    test "list_by_entity_and_status('trashed') returns only trashed", ctx do
      [r1, _r2, _r3] = ctx.records
      {:ok, _} = EntityData.trash(r1)

      uuids =
        EntityData.list_by_entity_and_status(ctx.entity.uuid, "trashed")
        |> Enum.map(& &1.uuid)

      assert uuids == [r1.uuid]
    end

    test "filter_by_status('archived') doesn't leak trashed records", ctx do
      [r1, r2 | _] = ctx.records
      {:ok, _} = EntityData.update(r1, %{status: "archived"})
      {:ok, _} = EntityData.trash(r2)

      uuids =
        EntityData.filter_by_status("archived")
        |> Enum.map(& &1.uuid)

      assert r1.uuid in uuids
      refute r2.uuid in uuids
    end
  end

  describe "count_external_references/1" do
    test "returns 0 when no callbacks are registered", ctx do
      [record | _] = ctx.records
      Application.delete_env(:phoenix_kit_entities, :reverse_references)

      assert EntityData.count_external_references(record) == 0
    end

    test "sums counts across registered callbacks for the matching entity name", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> 7 end},
        {"trash_test", fn _uuid -> 3 end},
        {"other_entity", fn _uuid -> 100 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(record) == 10
    end

    test "swallows DB-availability raises and logs a warning", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test",
         fn _uuid ->
           raise DBConnection.ConnectionError, message: "no connection"
         end},
        {"trash_test", fn _uuid -> 5 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert EntityData.count_external_references(record) == 5
        end)

      assert log =~ "reverse_references callback failed"
    end

    test "lets non-DB callback bugs propagate (a broken callback is a real bug)",
         ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> raise "boom" end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert_raise RuntimeError, "boom", fn ->
        EntityData.count_external_references(record)
      end
    end

    test "ignores callbacks returning negative integers", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> -10 end},
        {"trash_test", fn _uuid -> 4 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(record) == 4
    end

    test "ignores callbacks returning non-integers", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> "lots" end},
        {"trash_test", fn _uuid -> :many end},
        {"trash_test", fn _uuid -> 7 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(record) == 7
    end

    test "ignores entries that aren't {name, fun-of-arity-1}", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        # not arity 1
        {"trash_test", fn -> 99 end},
        # not a {name, fun} tuple
        :garbage,
        {"trash_test", "not a function"},
        {"trash_test", fn _uuid -> 3 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(record) == 3
    end

    test "skips callbacks bound to a different entity name", ctx do
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"some_other_entity", fn _uuid -> 1000 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(record) == 0
    end

    test "returns 0 when the entity association doesn't resolve" do
      # Synthetic struct whose entity_uuid points nowhere — the preload
      # comes back with entity: nil and the catchall branch returns 0.
      # This is reachable in practice if a parent app constructs a record
      # in-memory before the entity row exists, or after a forced delete.
      orphan = %EntityData{
        uuid: UUID.generate(),
        entity_uuid: UUID.generate()
      }

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> 99 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      assert EntityData.count_external_references(orphan) == 0
    end

    test "2-arity form accepts a preloaded entity to skip the per-call preload", ctx do
      # The single-arg form does `repo().preload(entity_data, :entity).entity`
      # on every call — N+1 when rendering many records. The 2-arity form
      # lets callers pass an already-loaded entity (or any map with a
      # binary `:name` key) to avoid the round-trip.
      [record | _] = ctx.records

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> 11 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      # Same numeric result whether we pass the entity or let it preload.
      preloaded = Entities.get_entity!(ctx.entity.uuid)
      assert EntityData.count_external_references(record, preloaded) == 11
      assert EntityData.count_external_references(record) == 11

      # A bare-shape map with the right :name still works — useful for
      # callers that have entity name in a custom struct (sitemap source,
      # mirror exporter, etc.).
      assert EntityData.count_external_references(record, %{name: "trash_test"}) == 11
    end

    test "2-arity form returns 0 when entity is nil-but-explicit (no preload, no DB hit)" do
      # Useful belt-and-suspenders for callers that want to bypass the
      # preload AND know the entity isn't in their working set.
      orphan = %EntityData{uuid: UUID.generate(), entity_uuid: UUID.generate()}

      Application.put_env(:phoenix_kit_entities, :reverse_references, [
        {"trash_test", fn _uuid -> 99 end}
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :reverse_references) end)

      # Passing a non-name-bearing value collapses to 0 without falling
      # through to the preload path.
      assert EntityData.count_external_references(orphan, %{}) == 0
      assert EntityData.count_external_references(orphan, "not a struct") == 0
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
