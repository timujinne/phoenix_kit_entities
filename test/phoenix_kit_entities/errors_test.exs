defmodule PhoenixKitEntities.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEntities.Errors

  describe "message/1 plain atoms" do
    test ":cannot_remove_primary" do
      assert Errors.message(:cannot_remove_primary) == "Cannot remove the primary language."
    end

    test ":not_multilang" do
      assert Errors.message(:not_multilang) == "Multi-language support is not enabled."
    end

    test ":entity_not_found" do
      assert Errors.message(:entity_not_found) == "Entity not found."
    end

    test ":not_found" do
      assert Errors.message(:not_found) == "Record not found."
    end

    test ":invalid_format" do
      assert Errors.message(:invalid_format) == "Invalid format."
    end

    test ":unexpected" do
      assert Errors.message(:unexpected) == "An unexpected error occurred."
    end

    test ":already_trashed" do
      assert Errors.message(:already_trashed) == "This record is already in the trash."
    end

    test ":not_trashed" do
      assert Errors.message(:not_trashed) == "This record is not in the trash."
    end

    test ":referenced_by_external surfaces a friendly explanation of the FK violation" do
      msg = Errors.message(:referenced_by_external)
      assert msg =~ "Cannot permanently delete"
      assert msg =~ "referenced by other tables"
    end

    test ":has_children" do
      assert Errors.message(:has_children) ==
               "Cannot permanently delete: this record has child records. Reassign or delete its children first."
    end
  end

  describe "message/1 atoms the write path returns" do
    for {atom, text} <- [
          missing_target_entity: "Relation field requires a target entity",
          relations_not_allowed: "Relation fields are turned off in the Entities settings.",
          managed_blueprint:
            "This blueprint is managed by another module: its slug and status cannot be changed here.",
          locked_key: "This setting is locked by the module that manages the blueprint.",
          no_delete_guard:
            "This blueprint is managed by another module and cannot be deleted here.",
          delete_guard_error:
            "The module that manages this blueprint could not confirm it is safe to delete.",
          status_mismatch: "This record was changed in another session. Reload and try again.",
          too_many_uuids: "Too many records in one request."
        ] do
      test inspect(atom) do
        assert Errors.message(unquote(atom)) == unquote(text)
      end
    end
  end

  describe "message/1 mirror importer reasons" do
    defp invalid_changeset do
      {%{}, %{slug: :string}}
      |> Ecto.Changeset.cast(%{}, [:slug])
      |> Ecto.Changeset.add_error(:slug, "should be at most %{count} character(s)", count: 3)
    end

    test "{:validation_failed, changeset} names the fields and their messages" do
      assert Errors.message({:validation_failed, invalid_changeset()}) ==
               "a record is not valid (slug: should be at most 3 character(s))"
    end

    test "{:validation_failed, changeset} survives a typed %{word} with no binding" do
      changeset =
        {%{}, %{data: :map}}
        |> Ecto.Changeset.cast(%{}, [:data])
        |> Ecto.Changeset.add_error(:data, "field '50%{zz_no_such_atom_9f3}' is invalid")

      assert Errors.message({:validation_failed, changeset}) ==
               "a record is not valid (data: field '50%{zz_no_such_atom_9f3}' is invalid)"
    end

    test "{:rolled_back, _} says nothing was imported, and why" do
      assert Errors.message({:rolled_back, {:write_failed, invalid_changeset()}}) ==
               "Nothing was imported: a record is not valid (slug: should be at most 3 character(s))"
    end

    test "{:refused, atom} reads as the atom's own message" do
      assert Errors.message({:refused, :locked_key}) == Errors.message(:locked_key)
    end

    test "{:broken_links, _} counts the links" do
      assert Errors.message({:broken_links, [:a, :b]}) ==
               "2 record(s) link to records that do not exist"
    end

    test "{:file_not_found, name}" do
      assert Errors.message({:file_not_found, "brand"}) == "no export file for 'brand'"
    end

    test "{:entity_not_found, name, slug}" do
      assert Errors.message({:entity_not_found, "brand", "acme"}) ==
               "entity 'brand' does not exist"
    end
  end

  describe "message/1 tagged tuples" do
    test "{:invalid_field_type, _} interpolates the supplied type" do
      assert Errors.message({:invalid_field_type, "blob"}) == "Invalid field type: blob"
    end

    test "{:requires_options, _} interpolates the supplied type" do
      assert Errors.message({:requires_options, "select"}) ==
               "Field type 'select' requires options"
    end

    test "{:missing_required_keys, _} joins the keys" do
      assert Errors.message({:missing_required_keys, ["key", "label"]}) ==
               "Missing required keys: key, label"
    end

    test "{:user_entity_limit_reached, _} interpolates the limit" do
      assert Errors.message({:user_entity_limit_reached, 100}) ==
               "You have reached the maximum limit of 100 entities"
    end
  end

  describe "message/1 fallback shapes" do
    test "binary passes through unchanged" do
      assert Errors.message("custom legacy message") == "custom legacy message"
    end

    test "unknown atom renders as Unexpected error" do
      assert Errors.message(:totally_unknown) == "Unexpected error: :totally_unknown"
    end

    test "unknown tuple renders as Unexpected error" do
      assert Errors.message({:weird, :shape, 42}) == "Unexpected error: {:weird, :shape, 42}"
    end

    test "struct renders as Unexpected error" do
      assert Errors.message(%{some: :map}) == "Unexpected error: %{some: :map}"
    end
  end
end
