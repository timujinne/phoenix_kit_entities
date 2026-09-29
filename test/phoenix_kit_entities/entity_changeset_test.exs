defmodule PhoenixKitEntities.EntityChangesetTest do
  use PhoenixKitEntities.DataCase, async: true

  alias PhoenixKitEntities

  @valid_attrs %{
    name: "product",
    display_name: "Product",
    display_name_plural: "Products",
    created_by_uuid: "01912345-6789-7abc-def0-123456789abc"
  }

  defp changeset(attrs \\ %{}) do
    PhoenixKitEntities.changeset(%PhoenixKitEntities{}, Map.merge(@valid_attrs, attrs))
  end

  describe "required fields" do
    test "valid with all required fields" do
      cs = changeset()
      assert cs.valid?
    end

    test "invalid without name" do
      cs = changeset(%{name: nil})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "invalid without display_name" do
      cs = changeset(%{display_name: nil})
      refute cs.valid?
      assert errors_on(cs)[:display_name]
    end

    test "invalid without display_name_plural" do
      cs = changeset(%{display_name_plural: nil})
      refute cs.valid?
      assert errors_on(cs)[:display_name_plural]
    end

    test "invalid without created_by_uuid" do
      cs = changeset(%{created_by_uuid: nil})
      refute cs.valid?
      assert errors_on(cs)[:created_by_uuid]
    end
  end

  describe "name validation" do
    test "valid snake_case name" do
      cs = changeset(%{name: "blog_post"})
      refute errors_on(cs)[:name]
    end

    test "valid simple name" do
      cs = changeset(%{name: "product"})
      refute errors_on(cs)[:name]
    end

    test "valid name with numbers" do
      cs = changeset(%{name: "item2"})
      refute errors_on(cs)[:name]
    end

    test "invalid - starts with number" do
      cs = changeset(%{name: "2product"})
      assert errors_on(cs)[:name]
    end

    test "invalid - uppercase letters" do
      cs = changeset(%{name: "Product"})
      assert errors_on(cs)[:name]
    end

    test "invalid - contains hyphens" do
      cs = changeset(%{name: "blog-post"})
      assert errors_on(cs)[:name]
    end

    test "invalid - contains spaces" do
      cs = changeset(%{name: "blog post"})
      assert errors_on(cs)[:name]
    end

    test "invalid - too short (1 char)" do
      cs = changeset(%{name: "a"})
      assert errors_on(cs)[:name]
    end

    test "valid - minimum length (2 chars)" do
      cs = changeset(%{name: "ab"})
      refute errors_on(cs)[:name]
    end

    test "invalid - too long (51 chars)" do
      cs = changeset(%{name: String.duplicate("a", 51)})
      assert errors_on(cs)[:name]
    end
  end

  describe "display_name length validation" do
    test "invalid - too short (1 char)" do
      cs = changeset(%{display_name: "A"})
      assert errors_on(cs)[:display_name]
    end

    test "invalid - too long (101 chars)" do
      cs = changeset(%{display_name: String.duplicate("A", 101)})
      assert errors_on(cs)[:display_name]
    end
  end

  describe "description length validation" do
    test "valid - within limit" do
      cs = changeset(%{description: "A short description"})
      refute errors_on(cs)[:description]
    end

    test "invalid - too long (501 chars)" do
      cs = changeset(%{description: String.duplicate("x", 501)})
      assert errors_on(cs)[:description]
    end
  end

  describe "status validation" do
    test "valid - draft" do
      cs = changeset(%{status: "draft"})
      refute errors_on(cs)[:status]
    end

    test "valid - published" do
      cs = changeset(%{status: "published"})
      refute errors_on(cs)[:status]
    end

    test "valid - archived" do
      cs = changeset(%{status: "archived"})
      refute errors_on(cs)[:status]
    end

    test "invalid status" do
      cs = changeset(%{status: "deleted"})
      assert errors_on(cs)[:status]
    end
  end

  describe "fields_definition validation" do
    test "defaults to empty list when nil" do
      cs = changeset(%{fields_definition: nil})
      assert Ecto.Changeset.get_field(cs, :fields_definition) == []
    end

    test "valid field definition" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end

    test "invalid - missing type" do
      fields = [%{"key" => "name", "label" => "Name"}]
      cs = changeset(%{fields_definition: fields})
      assert errors_on(cs)[:fields_definition]
    end

    test "invalid - missing key" do
      fields = [%{"type" => "text", "label" => "Name"}]
      cs = changeset(%{fields_definition: fields})
      assert errors_on(cs)[:fields_definition]
    end

    test "invalid - missing label" do
      fields = [%{"type" => "text", "key" => "name"}]
      cs = changeset(%{fields_definition: fields})
      assert errors_on(cs)[:fields_definition]
    end

    test "invalid - unknown field type" do
      fields = [%{"type" => "unknown", "key" => "name", "label" => "Name"}]
      cs = changeset(%{fields_definition: fields})
      assert errors_on(cs)[:fields_definition]
    end

    test "invalid - field is not a map" do
      cs = changeset(%{fields_definition: ["not_a_map"]})
      assert errors_on(cs)[:fields_definition]
    end

    test "invalid - not a list" do
      cs = changeset(%{fields_definition: "not_a_list"})
      assert errors_on(cs)[:fields_definition]
    end

    test "valid - multiple fields of different types" do
      fields = [
        %{"type" => "text", "key" => "name", "label" => "Name"},
        %{"type" => "number", "key" => "price", "label" => "Price"},
        %{"type" => "boolean", "key" => "active", "label" => "Active"},
        %{"type" => "select", "key" => "category", "label" => "Category", "options" => ["A", "B"]}
      ]

      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end

    test "valid - all supported field types" do
      types =
        ~w(text textarea number boolean date email url select radio checkbox rich_text image file relation heading)

      fields =
        Enum.map(types, fn type ->
          base = %{"type" => type, "key" => "field_#{type}", "label" => "Field #{type}"}

          case type do
            type when type in ["select", "radio", "checkbox"] ->
              Map.put(base, "options", ["Option A", "Option B"])

            "relation" ->
              Map.put(base, "target_entity", "some_entity")

            _ ->
              base
          end
        end)

      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end

    test "invalid - a relation field without a target_entity" do
      fields = [%{"type" => "relation", "key" => "grades", "label" => "Grades"}]
      cs = changeset(%{fields_definition: fields})
      assert [message] = errors_on(cs)[:fields_definition]
      assert message =~ "target_entity"
    end

    test "valid - heading field type (display-only, no options needed)" do
      fields = [%{"type" => "heading", "key" => "sec_ahi", "label" => "Ahi"}]
      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end

    test "valid - a choice field carrying \"allow_other\" isn't rejected as an unknown key" do
      fields = [
        %{
          "type" => "radio",
          "key" => "color",
          "label" => "Color",
          "options" => ["Red", "Blue"],
          "allow_other" => true
        }
      ]

      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end

    test "valid - a field carrying a \"translations\" map isn't rejected as an unknown key" do
      fields = [
        %{
          "type" => "radio",
          "key" => "color",
          "label" => "Värv",
          "options" => ["Must", "Valge"],
          "translations" => %{
            "ru" => %{"label" => "Цвет", "options" => %{"Must" => "Чёрный", "Valge" => "Белый"}}
          }
        }
      ]

      cs = changeset(%{fields_definition: fields})
      refute errors_on(cs)[:fields_definition]
    end
  end
end
