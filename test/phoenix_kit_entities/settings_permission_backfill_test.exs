defmodule PhoenixKitEntities.SettingsPermissionBackfillTest do
  @moduledoc """
  `entities.settings` narrowed what the base key allows, so
  `migrate_legacy/0` grants it once to every role that already held
  `entities` — and never again, so later roles get the narrow meaning.
  """

  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitEntities.Test.Repo, as: TestRepo

  @flag "entities_settings_backfilled"
  @sub "entities.settings"

  setup do
    {:ok, _} = Settings.update_setting("entities_enabled", "true")
    :ok
  end

  defp role_with_base! do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{"name" => "EntitiesRole-#{n}", "description" => "test"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "entities", nil)
    role
  end

  defp holds?(role, key), do: key in Permissions.get_permissions_for_role(role.uuid)

  test "grants the sub-key once to roles holding the base key, then sets the flag" do
    holder = role_with_base!()
    {:ok, bystander} = Roles.create_role(%{"name" => "NoEntities-#{System.unique_integer()}"})

    assert {:ok, %{settings_backfill: :backfilled}} = PhoenixKitEntities.migrate_legacy()
    assert holds?(holder, @sub)
    refute holds?(bystander, @sub)
    assert Settings.get_setting(@flag) == "true"

    late = role_with_base!()

    assert {:ok, %{settings_backfill: :already_backfilled}} =
             PhoenixKitEntities.migrate_legacy()

    refute holds?(late, @sub)
  end

  test "a revoke after the backfill sticks across boots" do
    holder = role_with_base!()
    PhoenixKitEntities.migrate_legacy()
    :ok = Permissions.revoke_permission(holder.uuid, @sub)

    PhoenixKitEntities.migrate_legacy()
    refute holds?(holder, @sub)
  end

  test "a failed grant leaves the flag unset so the next boot retries" do
    holder = role_with_base!()

    # Without the module registered the sub-key is not a known permission,
    # so the grant's changeset rejects it.
    ModuleRegistry.unregister(PhoenixKitEntities)
    on_exit(fn -> ModuleRegistry.register(PhoenixKitEntities) end)

    assert {:error, _} = PhoenixKitEntities.migrate_legacy()
    refute holds?(holder, @sub)
    refute Settings.get_setting(@flag) == "true"

    ModuleRegistry.register(PhoenixKitEntities)

    assert {:ok, %{settings_backfill: :backfilled}} = PhoenixKitEntities.migrate_legacy()
    assert holds?(holder, @sub)
  end

  test "the sub-key is declared on the module" do
    %{sub_permissions: subs} = PhoenixKitEntities.permission_metadata()
    assert Enum.any?(subs, &(&1.key == "settings"))
  end

  # Core's `get_permissions_for_role/1` rescues a query error to `[]`, which
  # would read as "nobody holds the base key" and set the flag for good.
  test "a failed grant lookup is an error, and the flag stays unset" do
    _holder = role_with_base!()

    # DDL inside the test's sandbox transaction, undone with it.
    TestRepo.query!("ALTER TABLE phoenix_kit_role_permissions RENAME TO pk_rp_hidden")
    result = PhoenixKitEntities.migrate_legacy()
    TestRepo.query!("ALTER TABLE pk_rp_hidden RENAME TO phoenix_kit_role_permissions")

    assert result == {:error, :lookup_failed}
    refute Settings.get_setting(@flag) == "true"
  end
end
