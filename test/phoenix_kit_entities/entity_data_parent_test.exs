defmodule PhoenixKitEntities.EntityDataParentTest do
  @moduledoc """
  Parent reference (self-FK) behaviour for EntityData. Covers
  changeset validations (self-parent, same-entity, cycle), tree
  helpers (`list_tree/2`, `descendant_uuids/3`), and the
  has-live-children block on `delete/2` + `bulk_delete/2`.

  Soft-delete interplay: trashed children do NOT block hard-deleting
  their parent — the trash row stays alive only for parent-app FK
  resolution, not entity-internal tree integrity.
  """

  use PhoenixKitEntities.DataCase, async: false

  alias Ecto.UUID
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = UUID.generate()

    {:ok, entity_a} =
      Entities.create_entity(
        %{
          name: "parent_test_a",
          display_name: "Parent Test A",
          display_name_plural: "Parent Tests A",
          fields_definition: [],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity_b} =
      Entities.create_entity(
        %{
          name: "parent_test_b",
          display_name: "Parent Test B",
          display_name_plural: "Parent Tests B",
          fields_definition: [],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    %{actor_uuid: actor_uuid, entity_a: entity_a, entity_b: entity_b}
  end

  defp create_record(entity, title, attrs, actor_uuid) do
    base = %{
      entity_uuid: entity.uuid,
      title: title,
      status: "published",
      created_by_uuid: actor_uuid
    }

    {:ok, r} = EntityData.create(Map.merge(base, attrs), actor_uuid: actor_uuid)
    r
  end

  describe "changeset parent validations" do
    test "rejects a record as its own parent", %{entity_a: entity_a, actor_uuid: actor_uuid} do
      root = create_record(entity_a, "Root", %{}, actor_uuid)

      changeset = EntityData.change(root, %{parent_uuid: root.uuid})

      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:parent_uuid]
    end

    test "rejects a parent from a different entity", %{
      entity_a: entity_a,
      entity_b: entity_b,
      actor_uuid: actor_uuid
    } do
      a_root = create_record(entity_a, "A root", %{}, actor_uuid)
      b_root = create_record(entity_b, "B root", %{}, actor_uuid)

      {:error, changeset} = EntityData.update(a_root, %{parent_uuid: b_root.uuid})

      refute changeset.valid?
      assert {msg, _} = changeset.errors[:parent_uuid]
      assert msg =~ "same entity"
    end

    test "rejects a parent that is the record's descendant (cycle)", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      a = create_record(entity_a, "A", %{}, actor_uuid)
      b = create_record(entity_a, "B", %{parent_uuid: a.uuid}, actor_uuid)
      c = create_record(entity_a, "C", %{parent_uuid: b.uuid}, actor_uuid)

      # Setting A.parent_uuid = C would create A → C → B → A
      {:error, changeset} = EntityData.update(a, %{parent_uuid: c.uuid})

      refute changeset.valid?
      assert {msg, _} = changeset.errors[:parent_uuid]
      assert msg =~ "descendant"
    end

    test "accepts a NULL parent (root)", %{entity_a: entity_a, actor_uuid: actor_uuid} do
      root = create_record(entity_a, "Root", %{}, actor_uuid)
      assert {:ok, _} = EntityData.update(root, %{parent_uuid: nil})
    end

    test "refuses a cycle through a chain of any depth", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      top = create_record(entity_a, "R0", %{}, actor_uuid)

      bottom =
        Enum.reduce(1..70, top, fn i, parent ->
          create_record(entity_a, "R#{i}", %{parent_uuid: parent.uuid}, actor_uuid)
        end)

      assert {:error, changeset} = EntityData.update(top, %{parent_uuid: bottom.uuid})

      assert {"parent cannot be one of this record's descendants", _} =
               changeset.errors[:parent_uuid]
    end

    test "refuses a trashed parent being set, but not one a row already had", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      trashed = create_record(entity_a, "Gone", %{}, actor_uuid)
      {:ok, trashed} = EntityData.trash(trashed)
      child = create_record(entity_a, "C", %{}, actor_uuid)

      assert {:error, changeset} = EntityData.update(child, %{parent_uuid: trashed.uuid})
      assert {"parent record is in the trash", _} = changeset.errors[:parent_uuid]

      # A parent trashed after the fact stays; the row's other fields still save.
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      under = create_record(entity_a, "U", %{parent_uuid: parent.uuid}, actor_uuid)
      {:ok, _} = EntityData.trash(parent)
      assert {:ok, renamed} = EntityData.update(under, %{title: "Renamed"})
      assert renamed.parent_uuid == parent.uuid
    end

    test "accepts a same-entity parent", %{entity_a: entity_a, actor_uuid: actor_uuid} do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      child = create_record(entity_a, "C", %{}, actor_uuid)
      assert {:ok, updated} = EntityData.update(child, %{parent_uuid: parent.uuid})
      assert updated.parent_uuid == parent.uuid
    end
  end

  describe "list_tree/2" do
    test "returns rows depth-ordered with parents preceding children", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      root1 = create_record(entity_a, "Root1", %{}, actor_uuid)
      root2 = create_record(entity_a, "Root2", %{}, actor_uuid)
      child = create_record(entity_a, "Child of Root1", %{parent_uuid: root1.uuid}, actor_uuid)

      grandchild =
        create_record(entity_a, "Grandchild", %{parent_uuid: child.uuid}, actor_uuid)

      tree = EntityData.list_tree(entity_a.uuid)
      uuids = Enum.map(tree, & &1.record.uuid)
      depths = Map.new(tree, fn %{record: r, depth: d} -> {r.uuid, d} end)

      # Both roots are at depth 0
      assert depths[root1.uuid] == 0
      assert depths[root2.uuid] == 0
      # Child at depth 1, grandchild at depth 2
      assert depths[child.uuid] == 1
      assert depths[grandchild.uuid] == 2

      # Root1 precedes its children which precede the grandchild
      assert_index_order(uuids, [root1.uuid, child.uuid, grandchild.uuid])
    end
  end

  describe "descendant_uuids/3" do
    test "returns all descendants (children + grandchildren)", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      root = create_record(entity_a, "Root", %{}, actor_uuid)
      child = create_record(entity_a, "Child", %{parent_uuid: root.uuid}, actor_uuid)
      grandchild = create_record(entity_a, "Grand", %{parent_uuid: child.uuid}, actor_uuid)
      _sibling_root = create_record(entity_a, "Sib", %{}, actor_uuid)

      result = EntityData.descendant_uuids(root.uuid, entity_a.uuid)

      assert MapSet.new(result) == MapSet.new([child.uuid, grandchild.uuid])
    end

    test "returns [] for a leaf row", %{entity_a: entity_a, actor_uuid: actor_uuid} do
      leaf = create_record(entity_a, "Leaf", %{}, actor_uuid)
      assert EntityData.descendant_uuids(leaf.uuid, entity_a.uuid) == []
    end

    test "returns [] for nil uuid", %{entity_a: entity_a} do
      assert EntityData.descendant_uuids(nil, entity_a.uuid) == []
    end
  end

  describe "hard-delete with children" do
    test "blocks delete when a live child exists", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      _child = create_record(entity_a, "C", %{parent_uuid: parent.uuid}, actor_uuid)

      assert {:error, :has_children} = EntityData.delete(parent, actor_uuid: actor_uuid)
    end

    test "allows delete when only trashed children exist", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      child = create_record(entity_a, "C", %{parent_uuid: parent.uuid}, actor_uuid)
      {:ok, _} = EntityData.trash(child, actor_uuid: actor_uuid)

      assert {:ok, _} = EntityData.delete(parent, actor_uuid: actor_uuid)
    end

    test "allows delete when the record has no children", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      leaf = create_record(entity_a, "Leaf", %{}, actor_uuid)
      assert {:ok, _} = EntityData.delete(leaf, actor_uuid: actor_uuid)
    end
  end

  describe "bulk_delete with children" do
    test "blocks when an external live child references the set", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      _external_child = create_record(entity_a, "C", %{parent_uuid: parent.uuid}, actor_uuid)

      assert {:error, :has_children} =
               EntityData.bulk_delete([parent.uuid], actor_uuid: actor_uuid)
    end

    test "allows bulk_delete when all children are in the input set", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      child = create_record(entity_a, "C", %{parent_uuid: parent.uuid}, actor_uuid)

      assert {2, nil} =
               EntityData.bulk_delete([parent.uuid, child.uuid], actor_uuid: actor_uuid)
    end

    test "allows bulk_delete when external children are trashed", %{
      entity_a: entity_a,
      actor_uuid: actor_uuid
    } do
      parent = create_record(entity_a, "P", %{}, actor_uuid)
      child = create_record(entity_a, "C", %{parent_uuid: parent.uuid}, actor_uuid)
      {:ok, _} = EntityData.trash(child, actor_uuid: actor_uuid)

      assert {1, nil} = EntityData.bulk_delete([parent.uuid], actor_uuid: actor_uuid)
    end
  end

  # Asserts that the elements of `expected` appear in `list` in the
  # given relative order (other elements may be interleaved).
  defp assert_index_order(list, expected) do
    indexed = list |> Enum.with_index() |> Map.new()
    positions = Enum.map(expected, &Map.fetch!(indexed, &1))
    assert positions == Enum.sort(positions)
  end
end
