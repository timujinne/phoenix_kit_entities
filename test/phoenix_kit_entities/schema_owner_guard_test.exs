defmodule PhoenixKitEntities.SchemaOwnerGuardTest do
  @moduledoc """
  I067: proves `SchemaOwnerGuard` actually refuses a collision instead of
  silently letting a different package's migration history through, using a
  real scratch database (created and dropped here, independent of the
  sandboxed `TestRepo`).
  """

  use ExUnit.Case, async: false

  # Same tag `PhoenixKitEntities.DataCase`/`LiveCase` inject for every other
  # DB-backed test in this suite — this one drives raw Postgrex against
  # scratch databases of its own instead of the sandboxed `TestRepo`, so it
  # can't go through either case template, but it needs the same exclusion
  # when Postgres is unavailable (see `test_helper.exs`'s `exclude` list).
  @moduletag :integration
  # Creates and drops its own scratch databases via the `postgres` maintenance
  # database; excluded by `test_helper.exs` when that connection is refused.
  @moduletag :maintenance_db

  alias PhoenixKitEntities.Test.SchemaOwnerGuard

  @scratch_db "i067_schema_owner_guard_scratch_entities"

  setup do
    admin_opts = [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: "postgres"
    ]

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@scratch_db}", [])
    Postgrex.query!(admin, "CREATE DATABASE #{@scratch_db}", [])

    {:ok, scratch} = Postgrex.start_link(Keyword.put(admin_opts, :database, @scratch_db))

    original_pgdatabase = System.get_env("PGDATABASE")
    System.put_env("PGDATABASE", @scratch_db)

    on_exit(fn ->
      case original_pgdatabase do
        nil -> System.delete_env("PGDATABASE")
        value -> System.put_env("PGDATABASE", value)
      end

      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@scratch_db}", [])
    end)

    query_fn = fn sql -> Postgrex.query!(scratch, sql, []) end
    %{query_fn: query_fn, admin: admin}
  end

  test "no schema_migrations table yet (fresh DB): check! is a no-op", %{query_fn: query_fn} do
    assert SchemaOwnerGuard.check!(query_fn) == :ok
  end

  test "no marker stamped yet (pre-existing isolated DB): check! is a no-op", %{
    query_fn: query_fn
  } do
    query_fn.("CREATE TABLE schema_migrations (version bigint)")
    assert SchemaOwnerGuard.check!(query_fn) == :ok
  end

  test "stamp! then check! with matching owner: passes", %{query_fn: query_fn} do
    query_fn.("CREATE TABLE schema_migrations (version bigint)")
    assert SchemaOwnerGuard.stamp!(query_fn) == :ok
    assert SchemaOwnerGuard.check!(query_fn) == :ok
  end

  test "stamp! marks ownership even without PGDATABASE — the default DB isn't exempt", %{
    query_fn: query_fn
  } do
    query_fn.("CREATE TABLE schema_migrations (version bigint)")
    System.delete_env("PGDATABASE")

    assert SchemaOwnerGuard.stamp!(query_fn) == :ok

    %{rows: [[marker]]} =
      query_fn.("SELECT obj_description('schema_migrations'::regclass, 'pg_class')")

    assert marker == "phoenix_kit_entities"
  end

  test "a different package's marker: check! raises the legible refusal message", %{
    query_fn: query_fn
  } do
    query_fn.("CREATE TABLE schema_migrations (version bigint)")
    query_fn.("COMMENT ON TABLE schema_migrations IS 'phoenix_kit_crm'")

    error =
      assert_raise SchemaOwnerGuard.OwnerMismatch, fn ->
        SchemaOwnerGuard.check!(query_fn)
      end

    assert error.message =~
             "PGDATABASE points at a database whose migration history belongs to " <>
               "phoenix_kit_crm, not phoenix_kit_entities"

    assert error.message =~ "silently corrupt or skip"
    assert error.message =~ "Use an isolated test DB, or a fresh one, instead"
  end

  test "check! is a no-op entirely when PGDATABASE is not set", %{query_fn: query_fn} do
    query_fn.("CREATE TABLE schema_migrations (version bigint)")
    query_fn.("COMMENT ON TABLE schema_migrations IS 'someone_else'")

    System.delete_env("PGDATABASE")

    assert SchemaOwnerGuard.check!(query_fn) == :ok
  end
end
