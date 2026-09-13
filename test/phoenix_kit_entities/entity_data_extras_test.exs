defmodule PhoenixKitEntities.EntityDataExtrasTest do
  @moduledoc """
  Coverage push for `PhoenixKitEntities.EntityData` — fills gaps the
  existing changeset / activity-logging tests don't reach: list_*,
  get_by_slug, position helpers (next_position, update_position,
  bulk_update_positions, move_to_position, reorder), search_by_title,
  filter_by_status, published_records, count_by_entity, get_data_stats,
  bulk_update_status, bulk_delete, get/get_translation/get_raw_translation/
  get_all_translations, public_path/public_url/public_alternates,
  invalid-input early returns.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "ed_extras",
          display_name: "ED Extras",
          display_name_plural: "ED Extras",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, r1} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Alpha",
          slug: "alpha",
          status: "published",
          data: %{"title" => "Alpha"},
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, r2} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Beta",
          slug: "beta",
          status: "draft",
          data: %{"title" => "Beta"},
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, r3} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Gamma",
          slug: "gamma",
          status: "archived",
          data: %{"title" => "Gamma"},
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, alpha: r1, beta: r2, gamma: r3, actor_uuid: actor_uuid}
  end

  describe "list_* helpers" do
    test "list_all/0 returns every record (preloaded)", _ctx do
      results = EntityData.list_all()
      assert is_list(results)
      assert length(results) >= 3
    end

    test "list_by_entity/1 filters by entity_uuid", ctx do
      results = EntityData.list_by_entity(ctx.entity.uuid)
      assert length(results) == 3
    end

    test "list_by_entity_and_status/2 filters by both", ctx do
      results = EntityData.list_by_entity_and_status(ctx.entity.uuid, "published")
      assert length(results) == 1
      [%{slug: "alpha"}] = results
    end

    test "filter_by_status/1 returns records of a single status across entities", _ctx do
      results = EntityData.filter_by_status("draft")
      assert is_list(results)
      assert Enum.any?(results, &(&1.status == "draft"))
    end

    test "list_data_by_entity / list_data_by_status / list_all_data aliases work", ctx do
      assert length(EntityData.list_data_by_entity(ctx.entity.uuid)) == 3
      assert is_list(EntityData.list_all_data())
      assert is_list(EntityData.list_data_by_status("published"))
    end
  end

  describe "get / get! / get_by_slug" do
    test "get/1 returns record for valid UUID", ctx do
      assert %EntityData{slug: "alpha"} = EntityData.get(ctx.alpha.uuid)
    end

    test "get/1 returns nil for invalid UUID format" do
      assert EntityData.get("not-a-uuid") == nil
    end

    test "get/1 returns nil for non-binary input" do
      assert EntityData.get(123) == nil
      assert EntityData.get(nil) == nil
    end

    test "get!/1 raises for missing UUID" do
      assert_raise Ecto.NoResultsError, fn ->
        EntityData.get!(Ecto.UUID.generate())
      end
    end

    test "get_by_slug/2 returns record matching entity + slug", ctx do
      assert %EntityData{slug: "beta"} =
               EntityData.get_by_slug(ctx.entity.uuid, "beta")
    end

    test "get_by_slug/2 returns nil for unknown slug", ctx do
      assert EntityData.get_by_slug(ctx.entity.uuid, "ghost") == nil
    end
  end

  describe "secondary_slug_exists?/4" do
    test "returns false when no record has a secondary slug for the locale", ctx do
      refute EntityData.secondary_slug_exists?(ctx.entity.uuid, "es", "ghost", nil)
    end
  end

  describe "position helpers" do
    test "next_position/1 returns max(position) + 1", ctx do
      pos1 = EntityData.next_position(ctx.entity.uuid)
      assert is_integer(pos1)
      assert pos1 >= 1
    end

    test "update_position/2 updates a single record's position", ctx do
      assert {:ok, _} = EntityData.update_position(ctx.alpha, 99)
      reread = EntityData.get(ctx.alpha.uuid)
      assert reread.position == 99
    end

    test "bulk_update_positions/2 sets positions in one call", ctx do
      pairs = [{ctx.alpha.uuid, 10}, {ctx.beta.uuid, 11}]
      assert :ok = EntityData.bulk_update_positions(pairs, entity_uuid: ctx.entity.uuid)
      assert EntityData.get(ctx.alpha.uuid).position == 10
      assert EntityData.get(ctx.beta.uuid).position == 11
    end

    test "bulk_update_positions/2 rejects payloads above the 1000-uuid cap" do
      # Cheap synthetic — we never reach the DB because the guard
      # short-circuits on length. Real UUID strings aren't required.
      oversized = Enum.map(1..1001, fn idx -> {"00000000-0000-0000-0000-000000000000", idx} end)
      assert {:error, :too_many_uuids} = EntityData.bulk_update_positions(oversized)
    end

    test "bulk_update_positions/2 enforces entity_uuid scope — cross-entity uuids ignored", ctx do
      actor_uuid = Ecto.UUID.generate()

      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "ed_extras_other",
            display_name: "ED Other",
            display_name_plural: "ED Others",
            fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, foreign} =
        EntityData.create(
          %{
            entity_uuid: other_entity.uuid,
            title: "Foreign",
            slug: "foreign-row",
            status: "published",
            data: %{"title" => "Foreign"},
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      original_position = foreign.position

      # Mix the foreign uuid into a reorder scoped to ctx.entity. The
      # foreign row must NOT have its position rewritten.
      pairs = [{ctx.alpha.uuid, 1}, {foreign.uuid, 2}, {ctx.beta.uuid, 3}]
      assert :ok = EntityData.bulk_update_positions(pairs, entity_uuid: ctx.entity.uuid)

      assert EntityData.get(ctx.alpha.uuid).position == 1
      assert EntityData.get(ctx.beta.uuid).position == 3
      assert EntityData.get(foreign.uuid).position == original_position
    end

    test "bulk_update_positions/2 deduplicates — last occurrence wins", ctx do
      pairs = [{ctx.alpha.uuid, 1}, {ctx.alpha.uuid, 99}]
      assert :ok = EntityData.bulk_update_positions(pairs, entity_uuid: ctx.entity.uuid)
      assert EntityData.get(ctx.alpha.uuid).position == 99
    end

    test "bulk_update_positions/2 raises ArgumentError on non-binary scope" do
      pairs = [{"00000000-0000-0000-0000-000000000000", 1}]

      assert_raise ArgumentError,
                   ~r/expected entity_uuid scope to be a binary UUID or nil/,
                   fn ->
                     EntityData.bulk_update_positions(pairs, entity_uuid: :not_a_binary)
                   end
    end

    test "move_to_position/2 with same position is a noop", ctx do
      {:ok, _} = EntityData.update_position(ctx.alpha, 5)
      reread = EntityData.get(ctx.alpha.uuid)
      assert :ok = EntityData.move_to_position(reread, 5)
    end

    test "move_to_position/2 shifts neighbors", ctx do
      {:ok, _} = EntityData.update_position(ctx.alpha, 1)
      {:ok, _} = EntityData.update_position(ctx.beta, 2)
      {:ok, _} = EntityData.update_position(ctx.gamma, 3)

      reread = EntityData.get(ctx.alpha.uuid)
      assert :ok = EntityData.move_to_position(reread, 3)
      # Other rows shifted up.
      assert EntityData.get(ctx.alpha.uuid).position == 3
    end

    test "reorder/2 assigns positions 1, 2, 3 by ordered uuids", ctx do
      ordered = [ctx.gamma.uuid, ctx.alpha.uuid, ctx.beta.uuid]
      assert :ok = EntityData.reorder(ctx.entity.uuid, ordered)
      assert EntityData.get(ctx.gamma.uuid).position == 1
      assert EntityData.get(ctx.alpha.uuid).position == 2
      assert EntityData.get(ctx.beta.uuid).position == 3
    end
  end

  describe "search / count / stats" do
    test "search_by_title/1 finds records matching the title substring" do
      results = EntityData.search_by_title("Alph")
      assert is_list(results)
      assert Enum.any?(results, &(&1.slug == "alpha"))
    end

    test "search_by_title/2 scoped to an entity", ctx do
      results = EntityData.search_by_title("Bet", ctx.entity.uuid)
      assert Enum.any?(results, &(&1.slug == "beta"))
    end

    test "search_by_title/3 with empty term returns rows (ILIKE '%%' matches all)", ctx do
      # Empty term generates ILIKE '%%' which matches every row scoped
      # to the entity. Pin that behaviour rather than assert []; the
      # caller is expected to short-circuit before calling with "".
      results = EntityData.search_by_title("", ctx.entity.uuid)
      assert is_list(results)
    end

    test "search_data/1 + search_data/2 are aliases", ctx do
      assert is_list(EntityData.search_data("Alph"))
      assert is_list(EntityData.search_data("Bet", ctx.entity.uuid))
    end

    test "published_records/1 returns only :published status", ctx do
      results = EntityData.published_records(ctx.entity.uuid)
      assert length(results) == 1
      [%{status: "published"}] = results
    end

    test "count_by_entity/1 returns integer count", ctx do
      assert EntityData.count_by_entity(ctx.entity.uuid) == 3
    end

    test "get_data_stats/0 returns global counts" do
      stats = EntityData.get_data_stats()
      assert is_integer(stats.total_records)
      assert is_integer(stats.published_records)
      assert is_integer(stats.draft_records)
      assert is_integer(stats.archived_records)
    end

    test "get_data_stats/1 scoped to entity", ctx do
      stats = EntityData.get_data_stats(ctx.entity.uuid)
      assert stats.total_records == 3
      assert stats.published_records == 1
      assert stats.draft_records == 1
      assert stats.archived_records == 1
    end
  end

  describe "bulk_update_status / bulk_delete" do
    test "bulk_update_status/3 returns {count, nil} and logs activity", ctx do
      assert {2, nil} =
               EntityData.bulk_update_status(
                 [ctx.alpha.uuid, ctx.beta.uuid],
                 "archived",
                 actor_uuid: ctx.actor_uuid
               )

      assert EntityData.get(ctx.alpha.uuid).status == "archived"
      assert EntityData.get(ctx.beta.uuid).status == "archived"
    end

    test "bulk_delete/2 returns {count, nil} and logs activity", ctx do
      assert {2, nil} =
               EntityData.bulk_delete([ctx.alpha.uuid, ctx.beta.uuid],
                 actor_uuid: ctx.actor_uuid
               )

      assert EntityData.get(ctx.alpha.uuid) == nil
    end

    # Parent-PR review (2026-09-11): unlike the single-record `delete/2`
    # path (`notify_data_event/3`'s `:deleted` clause), `bulk_delete/2`
    # ran `delete_all` in a transaction and sent no PubSub event at all —
    # so a subscriber that prunes dangling slug references never fired
    # on the most common way to delete a value forever (emptying the
    # trash from the generic data admin).
    test "bulk_delete/2 broadcasts :data_deleted for every deleted record", ctx do
      PhoenixKitEntities.Events.subscribe_to_all_data()

      assert {2, nil} =
               EntityData.bulk_delete([ctx.alpha.uuid, ctx.beta.uuid],
                 actor_uuid: ctx.actor_uuid
               )

      alpha_uuid = ctx.alpha.uuid
      beta_uuid = ctx.beta.uuid
      entity_uuid = ctx.entity.uuid

      assert_receive {:data_deleted, ^entity_uuid, ^alpha_uuid}, 1_000
      assert_receive {:data_deleted, ^entity_uuid, ^beta_uuid}, 1_000
      # gamma was not part of the bulk_delete call — no event for it.
      refute_receive {:data_deleted, _, _}, 100
    end

    test "bulk_delete/2 on an empty list deletes nothing and broadcasts nothing", _ctx do
      PhoenixKitEntities.Events.subscribe_to_all_data()

      assert {0, nil} = EntityData.bulk_delete([])
      refute_receive {:data_deleted, _, _}, 100
    end
  end

  describe "translation helpers" do
    test "get_translation/2 returns merged data for the locale", ctx do
      result = EntityData.get_translation(ctx.alpha, "en")
      assert is_map(result)
    end

    test "get_raw_translation/2 returns raw data for the locale", ctx do
      result = EntityData.get_raw_translation(ctx.alpha, "en")
      assert is_map(result)
    end

    test "get_all_translations/1 returns all locales' merged data", ctx do
      result = EntityData.get_all_translations(ctx.alpha)
      assert is_map(result)
    end
  end

  describe "public_path / public_url / public_alternates" do
    test "public_path/3 returns nil when no pattern is configured", ctx do
      result = EntityData.public_path(ctx.entity, ctx.alpha)
      # nil if no pattern resolved, or a binary path otherwise.
      assert is_nil(result) or is_binary(result)
    end

    test "public_path/3 with locale opt", ctx do
      result = EntityData.public_path(ctx.entity, ctx.alpha, locale: "en")
      assert is_nil(result) or is_binary(result)
    end

    test "public_url/3 returns nil or full URL", ctx do
      result = EntityData.public_url(ctx.entity, ctx.alpha)
      assert is_nil(result) or is_binary(result)
    end

    test "public_alternates/3 returns a map with :canonical + :alternates", ctx do
      result = EntityData.public_alternates(ctx.entity, ctx.alpha)
      assert is_map(result)
      assert Map.has_key?(result, :canonical)
      assert Map.has_key?(result, :alternates)
      assert is_list(result.alternates)
    end
  end

  describe "delete / update path coverage" do
    test "delete_data/2 alias deletes the record", ctx do
      assert {:ok, _} = EntityData.delete_data(ctx.alpha, actor_uuid: ctx.actor_uuid)
      assert EntityData.get(ctx.alpha.uuid) == nil
    end

    test "update_data/3 alias updates the record", ctx do
      assert {:ok, updated} =
               EntityData.update_data(
                 ctx.alpha,
                 %{title: "Renamed"},
                 actor_uuid: ctx.actor_uuid
               )

      assert updated.title == "Renamed"
    end

    test "get_data!/1 alias raises when missing" do
      assert_raise Ecto.NoResultsError, fn ->
        EntityData.get_data!(Ecto.UUID.generate())
      end
    end
  end

  describe "change/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = EntityData.change(%EntityData{}, %{title: "x"})
    end
  end

  describe "update/3 with :require_status" do
    test "proceeds normally when the record's current status is in the list", ctx do
      assert {:ok, updated} =
               EntityData.update(ctx.beta, %{title: "Beta Renamed"},
                 actor_uuid: ctx.actor_uuid,
                 require_status: ["draft"]
               )

      assert updated.title == "Beta Renamed"

      reloaded = EntityData.get!(ctx.beta.uuid)
      assert reloaded.title == "Beta Renamed"

      assert_activity_logged("entity_data.updated", resource_uuid: ctx.beta.uuid)
    end

    test "rejects with :status_mismatch and touches nothing when the status isn't in the list",
         ctx do
      assert {:error, :status_mismatch} =
               EntityData.update(ctx.alpha, %{title: "Alpha Hacked"},
                 actor_uuid: ctx.actor_uuid,
                 require_status: ["draft"]
               )

      reloaded = EntityData.get!(ctx.alpha.uuid)
      assert reloaded.title == "Alpha"

      refute_activity_logged("entity_data.updated", resource_uuid: ctx.alpha.uuid)
    end

    test "checks the freshly-read DB status, not the (possibly stale) status on the passed-in struct",
         ctx do
      # `stale` represents a caller (e.g. a second browser tab) holding
      # an in-memory copy from before the record moved to "published".
      stale = ctx.beta
      {:ok, _} = EntityData.update(ctx.beta, %{status: "published"}, actor_uuid: ctx.actor_uuid)

      assert {:error, :status_mismatch} =
               EntityData.update(stale, %{title: "Should Not Land"},
                 actor_uuid: ctx.actor_uuid,
                 require_status: ["draft"]
               )

      reloaded = EntityData.get!(ctx.beta.uuid)
      assert reloaded.title != "Should Not Land"
      assert reloaded.status == "published"
    end

    test "builds the changeset against the freshly-read row, not the stale struct's other fields",
         ctx do
      stale = ctx.beta

      {:ok, _} =
        EntityData.update(ctx.beta, %{title: "Renamed Elsewhere"}, actor_uuid: ctx.actor_uuid)

      # Only `data` changes here — `title` isn't in `attrs` at all, so
      # the returned/persisted title must reflect the FRESH row
      # ("Renamed Elsewhere"), not silently revert to `stale`'s title
      # just because `stale` was the struct handed to update/3.
      assert {:ok, updated} =
               EntityData.update(stale, %{data: %{"title" => "New Data"}},
                 actor_uuid: ctx.actor_uuid,
                 require_status: ["draft"]
               )

      assert updated.title == "Renamed Elsewhere"
      assert updated.data["title"] == "New Data"
    end

    test "omitting require_status (nil) reproduces the exact pre-existing behavior", ctx do
      assert {:ok, updated} =
               EntityData.update(ctx.alpha, %{title: "Alpha Renamed"}, actor_uuid: ctx.actor_uuid)

      assert updated.title == "Alpha Renamed"
    end
  end
end
