defmodule PhoenixKitEntities.AdminEditPathTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  @uuid "0197d8f0-1111-7222-8333-444455556666"

  defp expected(slug, uuid), do: Routes.path("/admin/entities/#{slug}/data/#{uuid}/edit")

  describe "admin_edit_path/2" do
    test "takes a slug and a record uuid" do
      assert Entities.admin_edit_path("product", @uuid) == expected("product", @uuid)
    end

    test "takes an entity struct and a record struct" do
      entity = %Entities{name: "product"}
      record = %EntityData{uuid: @uuid}

      assert Entities.admin_edit_path(entity, record) == expected("product", @uuid)
    end

    test "mixes structs and binaries freely" do
      assert Entities.admin_edit_path(%Entities{name: "product"}, @uuid) ==
               expected("product", @uuid)

      assert Entities.admin_edit_path("product", %EntityData{uuid: @uuid}) ==
               expected("product", @uuid)
    end

    test "points at the edit form under the admin segment" do
      assert String.ends_with?(
               Entities.admin_edit_path("product", @uuid),
               "/admin/entities/product/data/#{@uuid}/edit"
             )
    end

    test "honours :locale like Routes.path/2" do
      assert Entities.admin_edit_path("product", @uuid, locale: "ru") ==
               Routes.path("/admin/entities/product/data/#{@uuid}/edit", locale: "ru")
    end

    test "refuses a slug that is not an entity name" do
      for bad <- ["../x", "Prod uct", "a/b", "", "1abc"] do
        assert_raise ArgumentError, fn -> Entities.admin_edit_path(bad, @uuid) end
      end
    end

    test "refuses a record id that is not a uuid" do
      for bad <- ["new", "../edit", "123", ""] do
        assert_raise ArgumentError, fn -> Entities.admin_edit_path("product", bad) end
      end

      assert_raise ArgumentError, fn ->
        Entities.admin_edit_path("product", %EntityData{uuid: nil})
      end
    end
  end
end
