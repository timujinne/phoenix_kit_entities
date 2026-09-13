defmodule PhoenixKitEntities.SchemaOwnerGuardWiringTest do
  @moduledoc """
  I067, S014 close-out: `SchemaOwnerGuardTest` (a unit test) calls
  `check!/1`/`stamp!/1` DIRECTLY — none of that proves `test_helper.exs`
  actually wires them in, the only place the guard protects anything for
  real. Deleting the wiring calls from `test_helper.exs` leaves every
  existing unit test green; they prove the module works, not that
  anything still calls it. Ported from `phoenix_kit_crm`'s copy of this
  same test (I067) — this repo has no module-owned migration chain of its
  own (`test_helper.exs` runs only `PhoenixKit.Migration.ensure_current/2`,
  core's chain), so the crm version's extra module-migrator-row check has
  no equivalent here and is dropped; everything else carries over.

  This test runs `test_helper.exs` for real, as a fresh `mix test`
  subprocess against a scratch database, then checks the marker from
  OUTSIDE that process — closing both gaps a unit test of the module alone
  cannot: "the marker isn't stamped" and "the wiring that stamps it was
  cut" produce the exact same observable symptom here, and both fail this
  test.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  # Same tag `PhoenixKitEntities.DataCase`/`LiveCase` inject for every other
  # DB-backed test in this suite — this one drives raw Postgrex against
  # scratch databases of its own instead of the sandboxed `TestRepo`, so it
  # can't go through either case template, but it needs the same exclusion
  # when Postgres is unavailable (see `test_helper.exs`'s `exclude` list).
  @moduletag :integration
  # Clones scratch databases via the `postgres` maintenance database; excluded
  # by `test_helper.exs` when that connection is refused.
  @moduletag :maintenance_db

  # Real randomness (not a PID or node name — either could coincidentally
  # repeat across two different hosts hitting the same shared instance) so
  # two concurrent `mix test` runs against a shared Postgres never collide
  # on `DROP DATABASE IF EXISTS`/`CREATE DATABASE` for the same name — the
  # exact "shared scratch DB" scenario I067 exists for in the first place.
  defp unique_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  @scratch_db_prefix "i067_wiring_scratch"

  # Cloned from the repo's own already-migrated isolated test DB via
  # `CREATE DATABASE ... TEMPLATE`, rather than created empty. An empty
  # scratch DB forces test_helper.exs's boot to run core's full migration
  # chain from scratch before it ever reaches SchemaOwnerGuard.stamp!/1 —
  # slow, and unrelated to what this test is judging. Cloning an
  # already-migrated DB means the boot's migration step is a fast no-op
  # and this test's signal is about the guard's wiring, not about that
  # chain.
  @template_db "phoenix_kit_entities_test"

  # `CREATE DATABASE ... TEMPLATE` refuses outright while ANY session holds
  # a connection to the source database — and `PhoenixKitEntities.Test.Repo`
  # always has some, idle in its own pool, from `test_helper.exs`'s own
  # boot (independent of Sandbox mode, which only governs per-test
  # checkout, not the pool's persistent connections).
  #
  # `disconnect_all/3` releases exactly and only THIS repo's own pool
  # connections, through DBConnection — not a raw `pg_terminate_backend`
  # sweep over `pg_stat_activity`, which has no way to tell "this suite's
  # own idle connection" apart from any other session on the same
  # instance and, live in review, killed one that wasn't ours. Scoped by
  # construction to our own pool, not by a WHERE-clause guess at whose
  # session is whose. Ecto reconnects lazily on the pool's next checkout.
  #
  # `pool: DBConnection.Ownership` is required here, not optional: this
  # repo's test pool runs under Sandbox (`:manual` ownership mode), and
  # `disconnect_all/3`'s default pool module targets a plain
  # `DBConnection.ConnectionPool` — sent to `DBConnection.Ownership.Manager`
  # instead, it's not a wrong pid, it's a message shape the ownership
  # manager's `handle_call/3` has no clause for at all, and the manager
  # (and the run) crashes outright.
  #
  # `disconnect_all/3`'s `interval` is an upper bound for connections still
  # mid-checkout, not a guarantee that idle ones (what we have here) are
  # gone by the time the call returns — so the first `CREATE DATABASE`
  # attempt can still lose the race. A GENUINELY foreign session (someone
  # else entirely connected to the template db) never releases no matter
  # how long we wait, so retrying forever isn't the fix either — budget
  # is finite, and exhausting it fails with a message that names the real
  # cause instead of a bare 55006 a reader would have to go look up.
  @clone_retry_backoffs_ms [50, 100, 200, 400]

  defp clone_template!(admin, dest_db) do
    SQL.disconnect_all(PhoenixKitEntities.Test.Repo, 0, pool: DBConnection.Ownership)
    create_database_from_template!(admin, dest_db, @clone_retry_backoffs_ms)
  end

  defp create_database_from_template!(admin, dest_db, backoffs_ms) do
    Postgrex.query!(admin, "CREATE DATABASE #{dest_db} TEMPLATE #{@template_db}", [])
  rescue
    e in Postgrex.Error ->
      if match?(%{postgres: %{code: :object_in_use}}, e) do
        case backoffs_ms do
          [sleep_ms | rest] ->
            Process.sleep(sleep_ms)
            create_database_from_template!(admin, dest_db, rest)

          [] ->
            flunk(
              "CREATE DATABASE #{dest_db} TEMPLATE #{@template_db} still refused after " <>
                "#{length(@clone_retry_backoffs_ms) + 1} attempts (Postgres 55006, " <>
                "object_in_use) — some session, ours or someone else's, is still " <>
                "connected to the template database and never released it:\n" <>
                Exception.message(e)
            )
        end
      else
        reraise e, __STACKTRACE__
      end
  end

  setup do
    admin_opts = [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: "postgres"
    ]

    scratch_db = "#{@scratch_db_prefix}_#{unique_suffix()}"

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{scratch_db}", [])
    clone_template!(admin, scratch_db)

    # The template itself may already carry the "phoenix_kit_entities"
    # marker (stamped by some earlier, legitimate boot against it
    # directly) — cleared right after cloning so its presence afterward is
    # actually caused by THIS run's own boot, not inherited from the
    # template.
    {:ok, cleaner} = Postgrex.start_link(Keyword.put(admin_opts, :database, scratch_db))
    Postgrex.query!(cleaner, "COMMENT ON TABLE schema_migrations IS NULL", [])

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{scratch_db}", [])
    end)

    %{admin_opts: admin_opts, scratch_db: scratch_db}
  end

  test "a real boot through test_helper.exs stamps the owner marker", %{
    admin_opts: admin_opts,
    scratch_db: scratch_db
  } do
    env = [
      {"PGDATABASE", scratch_db},
      {"PGHOST", to_string(admin_opts[:hostname])},
      {"PGPORT", to_string(admin_opts[:port])},
      {"PGUSER", admin_opts[:username]},
      {"PGPASSWORD", admin_opts[:password]}
    ]

    # A single fast test file. test_helper.exs's boot code (which calls
    # SchemaOwnerGuard.check!/1 then, after migrating, stamp!/1) runs
    # unconditionally as part of loading the file — which target test runs
    # is irrelevant, only that `mix test` boots the suite at all. This
    # module's own unit test is as good a target as any.
    {output, exit_code} =
      System.cmd("mix", ["test", "test/phoenix_kit_entities/schema_owner_guard_test.exs"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert exit_code == 0, "real boot against a fresh scratch DB should succeed:\n#{output}"

    {:ok, checker} = Postgrex.start_link(Keyword.put(admin_opts, :database, scratch_db))

    marker =
      case Postgrex.query!(
             checker,
             "SELECT obj_description('schema_migrations'::regclass, 'pg_class')",
             []
           ) do
        %{rows: [[value]]} -> value
      end

    assert marker == "phoenix_kit_entities",
           "wiring did not stamp the owner marker (got #{inspect(marker)}) — either " <>
             "SchemaOwnerGuard.stamp!/1 was never called, or the wiring calling it was cut; " <>
             "a unit test of the module alone cannot distinguish either from a passing run"
  end

  @foreign_db_prefix "i067_wiring_scratch_foreign"

  # Templated from `phoenix_kit_entities_test` (like the stamping test)
  # for the same reason crm's version documents: an EMPTY scratch DB
  # forces `PhoenixKit.Migration.ensure_current/2` to run core's full
  # migration chain from scratch on every boot, including a boot this test
  # WANTS to crash before reaching, and that cold-boot chain carries its
  # own unrelated flakiness risk. Templating from an already-migrated DB
  # sidesteps it without touching anything the guard itself is judged on.
  #
  # What DOES need to be absent, and isn't in the raw template, is the
  # uuid-ossp extension — the step core's migration chain sets up early,
  # well before this repo's own tables. Dropped here so the extension's
  # presence afterward is a direct, order-sensitive signal: `CREATE
  # EXTENSION IF NOT EXISTS` is idempotent, so if it were already present
  # (as it is in the raw template) a late check! running after it would
  # look identical to check! never having let it run at all.
  test "a real boot through test_helper.exs refuses someone else's marker, before touching anything" do
    admin_opts = [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: "postgres"
    ]

    foreign_db = "#{@foreign_db_prefix}_#{unique_suffix()}"

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{foreign_db}", [])
    clone_template!(admin, foreign_db)

    {:ok, seeder} = Postgrex.start_link(Keyword.put(admin_opts, :database, foreign_db))
    Postgrex.query!(seeder, "DROP EXTENSION IF EXISTS \"uuid-ossp\"", [])

    # The template already carries `uuid_generate_v7/0` from its own
    # earlier boot, same as it carries uuid-ossp. `CREATE OR REPLACE
    # FUNCTION` against an unmodified clone is a genuine catalog no-op —
    # a schema-only dump is byte-identical whether the statement ran or
    # not — so the body is swapped to a placeholder first, keeping the
    # signature (name, arg types, return type) identical so every column
    # DEFAULT that uses it stays valid.
    Postgrex.query!(
      seeder,
      "CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$ " <>
        "SELECT '00000000-0000-0000-0000-000000000000'::uuid; " <>
        "$$ LANGUAGE sql",
      []
    )

    Postgrex.query!(
      seeder,
      "COMMENT ON TABLE schema_migrations IS 'some_other_package'",
      []
    )

    before_dump = schema_dump(foreign_db, admin_opts)
    before_versions = migration_versions(foreign_db, admin_opts)

    # Sanity on the fixture itself, not on the guard: if the extension is
    # somehow still present, or the function still carries its real body
    # instead of the placeholder just installed, the "untouched"
    # comparison below would be trivially satisfied by coincidence (a
    # no-op re-run) rather than by check!/1 actually stopping in time.
    refute before_dump =~ "uuid-ossp",
           "fixture still carries the uuid-ossp extension after dropping it"

    refute before_dump =~ "clock_timestamp",
           "fixture still carries the real uuid_generate_v7 body — the placeholder swap " <>
             "above didn't take, so its real (re-)creation below would be a no-op"

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{foreign_db}", [])
    end)

    env = [
      {"PGDATABASE", foreign_db},
      {"PGHOST", to_string(admin_opts[:hostname])},
      {"PGPORT", to_string(admin_opts[:port])},
      {"PGUSER", admin_opts[:username]},
      {"PGPASSWORD", admin_opts[:password]}
    ]

    {output, exit_code} =
      System.cmd("mix", ["test", "test/phoenix_kit_entities/schema_owner_guard_test.exs"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    refute exit_code == 0,
           "boot against a foreign-marked DB should refuse, not succeed:\n#{output}"

    assert output =~ "some_other_package",
           "refusal happened but without naming the actual owner — not the legible message " <>
             "the guard promises:\n#{output}"

    assert output =~ "OwnerMismatch",
           "process failed, but not with the guard's own exception — some other crash " <>
             "reached the same exit code, which this assertion exists to rule out:\n#{output}"

    after_versions = migration_versions(foreign_db, admin_opts)

    assert after_versions == before_versions,
           "the refusal should leave schema_migrations' rows untouched, but the applied-" <>
             "version list changed from #{inspect(before_versions)} to " <>
             "#{inspect(after_versions)} — the migrator recorded this migration as applied " <>
             "in someone else's bookkeeping before check!/1's refusal took effect, which is " <>
             "the exact harm I067 exists to prevent"

    after_dump = schema_dump(foreign_db, admin_opts)

    assert after_dump == before_dump, schema_diff_message(before_dump, after_dump)
  end

  # `schema_migrations` is the one table in this whole test where DATA is
  # the thing I067 actually protects (a version number recorded as
  # "applied" here IS the harm) — `pg_dump --schema-only` explicitly
  # excludes table data by design, so this gets its own row-content check
  # rather than being folded into the schema dump.
  defp migration_versions(db_name, admin_opts) do
    {:ok, conn} = Postgrex.start_link(Keyword.put(admin_opts, :database, db_name))

    %{rows: rows} =
      Postgrex.query!(conn, "SELECT version FROM schema_migrations ORDER BY version", [])

    Enum.map(rows, fn [version] -> version end)
  end

  # `pg_dump --schema-only` serializes the database's entire catalog —
  # comparing its full text before/after makes anything written between
  # check!/1 and this assertion visible by construction, not by having
  # been anticipated in a hand-picked field list.
  defp schema_dump(db_name, admin_opts) do
    args = [
      "-h",
      to_string(admin_opts[:hostname]),
      "-p",
      to_string(admin_opts[:port]),
      "-U",
      admin_opts[:username],
      "--schema-only",
      "--no-owner",
      "--no-privileges",
      db_name
    ]

    output =
      try do
        System.cmd("pg_dump", args,
          env: [{"PGPASSWORD", admin_opts[:password]}],
          stderr_to_stdout: true
        )
      rescue
        # `System.cmd/3` raises rather than returning a tuple when the
        # binary is absent from PATH — the same failure mode
        # `test_helper.exs`'s own `psql` check already guards against.
        # Without this, a machine with the Postgres client library but not
        # its CLI tools installed would crash this test with an opaque
        # ErlangError instead of a diagnosable message.
        ErlangError ->
          flunk("pg_dump not found on PATH — install the postgresql-client tools")
      end
      |> case do
        {output, 0} ->
          output

        # A version manager's shim is PRESENT and executable, so the rescue
        # above never fires for it — it runs, prints "No version is set for
        # command pg_dump", and exits 126. Matching `{output, 0}` directly
        # turned that into a bare MatchError on a tuple, which says nothing
        # about the cause; the whole point of the guard beside it is that
        # "pg_dump is unusable here" should be readable from the failure.
        {output, status} ->
          flunk("pg_dump exited #{status} — this test cannot run:\n#{output}")
      end

    # PG17's pg_dump emits a `\restrict <random-token>` / `\unrestrict
    # <same-token>` pair on every invocation — a fresh nonce gating
    # destructive psql commands on restore, unrelated to schema content.
    output
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ["\\restrict ", "\\unrestrict "]))
    |> Enum.join("\n")
  end

  # A character-level `String.myers_difference/2` on two large dumps
  # shards real SQL statements into unreadable word fragments. A line-set
  # difference loses positional context but keeps every changed line
  # whole, which is what actually matters for "what got written after
  # check!/1 raised" — this is a failure message, not an edit script.
  defp schema_diff_message(before_dump, after_dump) do
    before_lines = MapSet.new(String.split(before_dump, "\n"))
    after_lines = MapSet.new(String.split(after_dump, "\n"))

    added = MapSet.difference(after_lines, before_lines) |> Enum.sort()
    removed = MapSet.difference(before_lines, after_lines) |> Enum.sort()

    diff =
      Enum.map_join(added, "\n", &"+ #{&1}") <>
        if(added != [] and removed != [], do: "\n", else: "") <>
        Enum.map_join(removed, "\n", &"- #{&1}")

    "the refusal should leave the database's entire schema exactly as it found it, but " <>
      "pg_dump --schema-only shows a difference — something ran after check!/1 raised:\n#{diff}"
  end
end
