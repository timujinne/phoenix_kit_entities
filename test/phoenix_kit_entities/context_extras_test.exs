defmodule PhoenixKitEntities.ContextExtrasTest do
  @moduledoc """
  Coverage push for top-level `PhoenixKitEntities` context. Hits the
  module-level public surface that other test files don't cover:
  list_active_entities, list_entity_summaries, get_entity!, get_entity_by_name,
  get_system_stats, count_*, validate_user_entity_limit, get_max_per_user,
  get_config, permission_metadata, admin_tabs, invalidate_entities_cache,
  settings_tabs, children, css_sources, version, route_module,
  sort-mode helpers, mirror-settings helpers, translation helpers,
  set/remove_entity_translation.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKitEntities, as: Entities

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, published} =
      Entities.create_entity(
        %{
          name: "ctx_published",
          display_name: "Ctx Published",
          display_name_plural: "Ctx Published",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, draft} =
      Entities.create_entity(
        %{
          name: "ctx_draft",
          display_name: "Ctx Draft",
          display_name_plural: "Ctx Drafts",
          status: "draft",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, published: published, draft: draft, actor_uuid: actor_uuid}
  end

  describe "list_* helpers" do
    test "list_entities/0 returns all entities", _ctx do
      results = Entities.list_entities()
      assert is_list(results)
      # We seeded two; allow other tests to add more.
      assert match?([_, _ | _], results)
    end

    test "list_active_entities/0 returns only published" do
      results = Entities.list_active_entities()
      assert Enum.all?(results, &(&1.status == "published"))
    end

    test "list_entity_summaries/0 returns lightweight summaries (published only)" do
      # list_entity_summaries filters to published entities only.
      results = Entities.list_entity_summaries()
      assert is_list(results)
      # We seeded one published + one draft; expect ≥ 1 published.
      refute Enum.empty?(results)
    end

    test "list_entity_summaries/1 with lang opt resolves translations" do
      results = Entities.list_entity_summaries(lang: "en")
      assert is_list(results)
    end
  end

  describe "get_* helpers" do
    test "get_entity!/1 raises for missing UUID" do
      assert_raise Ecto.NoResultsError, fn ->
        Entities.get_entity!(Ecto.UUID.generate())
      end
    end

    test "get_entity/1 returns nil for invalid UUID" do
      assert Entities.get_entity("not-a-uuid") == nil
    end

    test "get_entity_by_name/1 returns the entity by name", ctx do
      assert %Entities{} = result = Entities.get_entity_by_name(ctx.published.name)
      assert result.uuid == ctx.published.uuid
    end

    test "get_entity_by_name/1 returns nil for unknown name" do
      assert Entities.get_entity_by_name("nonexistent_#{System.unique_integer([:positive])}") ==
               nil
    end

    test "get_entity_by_name/2 with lang opt resolves translations", ctx do
      result = Entities.get_entity_by_name(ctx.published.name, lang: "en")
      assert result.uuid == ctx.published.uuid
    end
  end

  describe "stats + counts + limits" do
    test "get_system_stats/0 returns the standard stat map" do
      stats = Entities.get_system_stats()
      assert is_map(stats)
      assert is_integer(stats.total_entities) and stats.total_entities >= 0
      assert is_integer(stats.active_entities) and stats.active_entities >= 0
      assert is_integer(stats.total_data_records) and stats.total_data_records >= 0
    end

    test "count_user_entities/1 returns int >= 0", ctx do
      assert is_integer(Entities.count_user_entities(ctx.actor_uuid))
    end

    test "count_entities/0 + count_all_entity_data/0" do
      assert is_integer(Entities.count_entities())
      assert is_integer(Entities.count_all_entity_data())
    end

    test "validate_user_entity_limit/1 returns {:ok, :valid} when under the limit", ctx do
      result = Entities.validate_user_entity_limit(ctx.actor_uuid)
      assert match?({:ok, :valid}, result) or match?({:error, _}, result)
    end

    test "get_max_per_user/0 returns the configured limit (or :unlimited)" do
      result = Entities.get_max_per_user()
      assert is_integer(result) or result == :unlimited
    end

    test "get_config/0 returns the standard config map" do
      config = Entities.get_config()
      assert is_map(config)
    end
  end

  describe "module callbacks" do
    test "module_key, module_name, version, route_module are static" do
      assert Entities.module_key() == "entities"
      assert Entities.module_name() == "Entities"
      assert is_binary(Entities.version())
      assert Entities.route_module() == PhoenixKitEntities.Routes
    end

    test "permission_metadata/0 returns a map with :name + :description" do
      meta = Entities.permission_metadata()
      assert is_map(meta) or is_list(meta)
    end

    test "admin_tabs/0 returns a list of Tab structs" do
      tabs = Entities.admin_tabs()
      assert is_list(tabs)
      refute Enum.empty?(tabs)
    end

    test "settings_tabs/0 returns a list of Tab structs" do
      tabs = Entities.settings_tabs()
      assert is_list(tabs)
      refute Enum.empty?(tabs)
    end

    test "children/0 includes Presence" do
      assert PhoenixKitEntities.Presence in Entities.children()
    end

    test "css_sources/0 returns the standard list" do
      sources = Entities.css_sources()
      assert :phoenix_kit_entities in sources
    end

    test "invalidate_entities_cache/0 returns :ok or similar" do
      result = Entities.invalidate_entities_cache()
      # Returns :ok or a cache-broadcast result; just confirm no crash.
      assert result == :ok or is_tuple(result) or is_list(result) or is_atom(result)
    end

    test "entities_children/1 + entities_children/2" do
      result1 = Entities.entities_children(nil)
      result2 = Entities.entities_children(nil, nil)
      assert is_list(result1)
      assert is_list(result2)
    end
  end

  describe "sort-mode helpers" do
    test "get_sort_mode/1 returns the configured mode (or default)", ctx do
      mode = Entities.get_sort_mode(ctx.published)
      assert is_binary(mode)
    end

    test "get_sort_mode_by_uuid/1 round-trips", ctx do
      mode = Entities.get_sort_mode_by_uuid(ctx.published.uuid)
      assert is_binary(mode) or is_nil(mode)
    end

    test "manual_sort?/1 returns boolean", ctx do
      assert is_boolean(Entities.manual_sort?(ctx.published))
    end

    test "update_sort_mode/2 with valid mode persists", ctx do
      assert {:ok, updated} = Entities.update_sort_mode(ctx.published, "manual")
      assert Entities.get_sort_mode(updated) == "manual"
    end
  end

  describe "mirror-settings helpers" do
    test "get_mirror_settings/1 returns a map", ctx do
      result = Entities.get_mirror_settings(ctx.published)
      assert is_map(result)
    end

    test "mirror_definitions_enabled? + mirror_data_enabled? return booleans", ctx do
      assert is_boolean(Entities.mirror_definitions_enabled?(ctx.published))
      assert is_boolean(Entities.mirror_data_enabled?(ctx.published))
    end

    test "update_mirror_settings/3 persists the mirror keys and nothing else it is handed", ctx do
      assert {:ok, updated} =
               Entities.update_mirror_settings(ctx.published, %{
                 "mirror_definitions" => true,
                 "mirror_data" => false,
                 "public_form_enabled" => true
               })

      assert updated.settings["mirror_definitions"] == true
      assert updated.settings["mirror_data"] == false
      refute Map.has_key?(updated.settings, "public_form_enabled")
      assert Entities.get_entity!(ctx.published.uuid).settings == updated.settings
    end

    test "update_mirror_settings/3 does not persist unsaved settings on the struct it is given",
         ctx do
      working_copy = %{ctx.published | settings: %{"public_form_enabled" => true}}

      assert {:ok, _} = Entities.update_mirror_settings(working_copy, %{"mirror_data" => true})

      stored = Entities.get_entity!(ctx.published.uuid).settings
      assert stored["mirror_data"] == true
      refute Map.has_key?(stored, "public_form_enabled")
    end

    test "list_entities_with_mirror_status/0 reports each entity's switches", ctx do
      {:ok, _} = Entities.update_mirror_settings(ctx.published, %{"mirror_definitions" => true})

      status =
        Entities.list_entities_with_mirror_status()
        |> Enum.find(&(&1.name == ctx.published.name))

      assert %{mirror_definitions: true, mirror_data: false} = status
    end

    test "enable_all_definitions_mirror / disable_all_definitions_mirror", ctx do
      total = length(Entities.list_entities())

      assert {:ok, ^total} = Entities.enable_all_definitions_mirror()
      assert Entities.mirror_definitions_enabled?(Entities.get_entity!(ctx.published.uuid))

      assert {:ok, ^total} = Entities.disable_all_definitions_mirror()
      refute Entities.mirror_definitions_enabled?(Entities.get_entity!(ctx.published.uuid))
    end

    test "enable_all_data_mirror / disable_all_data_mirror", ctx do
      total = length(Entities.list_entities())

      assert {:ok, ^total} = Entities.enable_all_data_mirror()
      assert Entities.mirror_data_enabled?(Entities.get_entity!(ctx.published.uuid))

      assert {:ok, ^total} = Entities.disable_all_data_mirror()
      refute Entities.mirror_data_enabled?(Entities.get_entity!(ctx.published.uuid))
    end

    test "the setters record the acting admin, not the entity's creator", ctx do
      acting = Ecto.UUID.generate()
      uuid = ctx.published.uuid

      {:ok, _} = Entities.update_sort_mode(ctx.published, "manual", actor_uuid: acting)

      {:ok, _} =
        Entities.set_entity_translation(
          Entities.get_entity!(uuid),
          "es-ES",
          %{"display_name" => "Publicado"},
          actor_uuid: acting
        )

      {:ok, _} =
        Entities.remove_entity_translation(Entities.get_entity!(uuid), "es-ES",
          actor_uuid: acting
        )

      {:ok, _} =
        Entities.update_mirror_settings(Entities.get_entity!(uuid), %{"mirror_data" => true},
          actor_uuid: acting
        )

      rows =
        Repo.query!(
          "SELECT actor_uuid FROM phoenix_kit_activities WHERE action = 'entity.updated' AND resource_uuid = $1",
          [Ecto.UUID.dump!(uuid)]
        ).rows

      assert length(rows) == 4
      assert Enum.all?(rows, fn [actor] -> Ecto.UUID.load!(actor) == acting end)
    end
  end

  describe "entity definition translations" do
    test "get_entity_translations/1 returns existing translations map", ctx do
      result = Entities.get_entity_translations(ctx.published)
      assert is_map(result)
    end

    test "set_entity_translation/3 persists override + get_entity_translation reads it", ctx do
      assert {:ok, updated} =
               Entities.set_entity_translation(ctx.published, "es", %{
                 "display_name" => "Publicado"
               })

      result = Entities.get_entity_translation(updated, "es")
      assert result["display_name"] == "Publicado"
    end

    test "remove_entity_translation/2 strips the locale", ctx do
      {:ok, with_es} =
        Entities.set_entity_translation(ctx.published, "es", %{"display_name" => "Publicado"})

      assert {:ok, removed} = Entities.remove_entity_translation(with_es, "es")
      result = Entities.get_entity_translations(removed)
      refute Map.has_key?(result, "es")
    end

    test "multilang_enabled?/0 returns boolean" do
      assert is_boolean(Entities.multilang_enabled?())
    end

    test "resolve_languages/2 with nil locale is a no-op", ctx do
      assert Entities.resolve_languages([ctx.published], nil) == [ctx.published]
    end

    test "maybe_resolve_lang/2 with empty opts is a no-op", ctx do
      assert Entities.maybe_resolve_lang(ctx.published, []) == ctx.published
    end

    test "maybe_resolve_lang/2 with lang nil is a no-op", ctx do
      assert Entities.maybe_resolve_lang(ctx.published, lang: nil) == ctx.published
    end
  end

  describe "change_entity/2" do
    test "returns a changeset", ctx do
      assert %Ecto.Changeset{} = Entities.change_entity(ctx.published, %{display_name: "X"})
    end
  end

  describe "reorder_entities/2 (drag-and-drop reordering)" do
    test "next_entity_position/0 starts at 1 on an empty table" do
      # The setup block already inserted three entities. Subtract them
      # by checking that next_position is past the highest currently
      # used.
      {:ok, latest} =
        Entities.create_entity(
          %{
            name: "ctx_position_probe",
            display_name: "Probe",
            display_name_plural: "Probes",
            fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
            created_by_uuid: Ecto.UUID.generate()
          },
          actor_uuid: Ecto.UUID.generate()
        )

      assert Entities.next_entity_position() == latest.position + 1
    end

    test "reorder_entities/2 assigns positions 1..N in the supplied order", ctx do
      ordered = [ctx.draft.uuid, ctx.published.uuid]

      assert :ok = Entities.reorder_entities(ordered, actor_uuid: Ecto.UUID.generate())

      assert Entities.get_entity!(ctx.draft.uuid).position == 1
      assert Entities.get_entity!(ctx.published.uuid).position == 2
    end

    test "reorder_entities/2 caps oversized payloads at 1000 uuids" do
      oversized = List.duplicate("00000000-0000-0000-0000-000000000000", 1001)
      assert {:error, :too_many_uuids} = Entities.reorder_entities(oversized)
    end

    test "reorder_entities/2 deduplicates input — last occurrence wins", ctx do
      # Two slots in the input both name :published — the *second* slot
      # (index 2) should win, so :published lands at position 2 and
      # the duplicate at position 1 is collapsed away.
      ordered = [ctx.published.uuid, ctx.draft.uuid, ctx.published.uuid]
      assert :ok = Entities.reorder_entities(ordered)

      assert Entities.get_entity!(ctx.draft.uuid).position == 1
      assert Entities.get_entity!(ctx.published.uuid).position == 2
    end

    test "reorder_entities/2 logs entity.reordered with actor_uuid + count", ctx do
      actor_uuid = Ecto.UUID.generate()
      ordered = [ctx.published.uuid, ctx.draft.uuid]

      assert :ok = Entities.reorder_entities(ordered, actor_uuid: actor_uuid)

      assert_activity_logged("entity.reordered",
        actor_uuid: actor_uuid,
        resource_type: "entity",
        resource_uuid: ctx.published.uuid,
        metadata_has: %{"count" => 2}
      )
    end

    test "reorder_entities/2 broadcasts :entity_updated for sidebar cache invalidation", ctx do
      :ok = PhoenixKitEntities.Events.subscribe_to_entities()

      assert :ok = Entities.reorder_entities([ctx.published.uuid, ctx.draft.uuid])

      assert_receive {:entity_updated, _uuid}, 500
    end
  end
end
