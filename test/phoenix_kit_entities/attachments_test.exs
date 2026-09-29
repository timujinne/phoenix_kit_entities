defmodule PhoenixKitEntities.AttachmentsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEntities.Attachments

  @products_folder "0190d7a4-0000-7000-8000-000000000001"
  @two_arity_folder "0190d7a4-0000-7000-8000-000000000002"

  defmodule Hook3 do
    def parent_for(:entity_file, "actor-1", %{entity_name: "products"}),
      do: {:ok, "0190d7a4-0000-7000-8000-000000000001"}

    def parent_for(:entity_file, _actor_uuid, %{entity_name: "not-a-uuid"}),
      do: {:ok, "folder-for-products"}

    def parent_for(:entity_file, _actor_uuid, _subject), do: nil
  end

  defmodule Hook2 do
    def parent_for(:entity_file, "actor-1"), do: {:ok, "0190d7a4-0000-7000-8000-000000000002"}
  end

  defmodule RaisingHook do
    def parent_for(_kind, _actor_uuid, _subject), do: raise("boom")
  end

  defmodule ExitingHook do
    def parent_for(_kind, _actor_uuid, _subject), do: exit(:timeout)
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_entities, :attachments_parent_folder) end)
  end

  describe "scope_folder/2" do
    test "returns nil when no hook is configured" do
      assert Attachments.scope_folder("products", "actor-1") == nil
    end

    test "returns the folder uuid from a 3-arg hook, scoped by entity_name" do
      Application.put_env(:phoenix_kit_entities, :attachments_parent_folder, {Hook3, :parent_for})

      assert Attachments.scope_folder("products", "actor-1") == @products_folder
    end

    test "drops an answer that is not a uuid" do
      Application.put_env(:phoenix_kit_entities, :attachments_parent_folder, {Hook3, :parent_for})

      assert Attachments.scope_folder("not-a-uuid", "actor-1") == nil
    end

    test "returns nil when the 3-arg hook resolves nil for a different entity" do
      Application.put_env(:phoenix_kit_entities, :attachments_parent_folder, {Hook3, :parent_for})

      assert Attachments.scope_folder("other", "actor-1") == nil
    end

    test "calls a 2-arg hook when the module exports no 3-arity function" do
      Application.put_env(:phoenix_kit_entities, :attachments_parent_folder, {Hook2, :parent_for})

      assert Attachments.scope_folder("products", "actor-1") == @two_arity_folder
    end

    test "returns nil when the hook raises" do
      Application.put_env(
        :phoenix_kit_entities,
        :attachments_parent_folder,
        {RaisingHook, :parent_for}
      )

      assert Attachments.scope_folder("products", "actor-1") == nil
    end

    test "returns nil when the hook exits" do
      Application.put_env(
        :phoenix_kit_entities,
        :attachments_parent_folder,
        {ExitingHook, :parent_for}
      )

      assert Attachments.scope_folder("products", "actor-1") == nil
    end

    test "returns nil when the configured module/function is undefined" do
      Application.put_env(
        :phoenix_kit_entities,
        :attachments_parent_folder,
        {NoSuchModule, :parent_for}
      )

      assert Attachments.scope_folder("products", "actor-1") == nil
    end
  end
end
