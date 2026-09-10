# Test helper for PhoenixKitEntities test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_entities_test
#
# Test infrastructure:
# - PhoenixKitEntities.Test.Repo (test/support/test_repo.ex)
# - PhoenixKitEntities.Test.Endpoint + Router + Layouts + Hooks
#   (test/support/test_*.ex)
# - PhoenixKitEntities.LiveCase (test/support/live_case.ex)
# - PhoenixKitEntities.DataCase (test/support/data_case.ex)
# - PhoenixKitEntities.ActivityLogAssertions
#   (test/support/activity_log_assertions.ex)
# - Schema setup runs core's versioned migrations directly via
#   `PhoenixKit.Migration`, then this module's own V1 chain via
#   `PhoenixKitEntities.Test.Migration` (test/support/test_migration.ex).

require Logger

alias PhoenixKitEntities.Test.Repo, as: TestRepo
alias PhoenixKitEntities.Test.SchemaOwnerGuard

# Pin URL prefix to "/" via persistent_term so PhoenixKit.Utils.Routes.path/2
# doesn't try to read the unset application env. Tests can override this
# value if they need a non-empty prefix.
:persistent_term.put(PhoenixKit.Config, %{url_prefix: "/"})

# Check if the test database exists before trying to connect
db_config = Application.get_env(:phoenix_kit_entities, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_entities_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # I067: PGDATABASE (opted into below, not the default) can point at a
      # database another package's Ecto.Migrator already owns. Check the
      # schema_migrations owner marker before trusting this DB with any
      # migration — see PhoenixKitEntities.Test.SchemaOwnerGuard.
      SchemaOwnerGuard.check!(&TestRepo.query!/1)

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. The entities tables come from
      # core (V17 creates them; V40/V58/V67/V74/V81 evolve them), and this
      # module's own V1 chain then ADOPTS them (see the Ecto.Migrator.up/4
      # call below).
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies
      # any newly-shipped Vxxx migrations on every boot by passing a
      # fresh wall-clock version to Ecto.Migrator. Replaces the
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`
      # pattern, which silently stopped re-applying once `0` was
      # recorded in `schema_migrations`. See the docstring on
      # `PhoenixKit.Migration.ensure_current/2` for the full staleness
      # story (clock-skew window, schema_migrations row accumulation,
      # prefix forwarding).
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # Then this module's own chain, through the same coordinator a real host
      # runs via `mix phoenix_kit.update` — so the suite can never pass against
      # a schema that differs from what installs get, and a statement that
      # merely looks right but does not parse fails here instead of on a host.
      # The wall-clock version makes the wrapper re-run on every boot rather
      # than being short-circuited by a stale `schema_migrations` row; the
      # coordinator is idempotent, so a re-run is a no-op.
      Ecto.Migrator.up(
        TestRepo,
        :os.system_time(:microsecond),
        PhoenixKitEntities.Test.Migration,
        log: false
      )

      # Migrations for this run succeeded — stamp ownership so a future run
      # against this same DB (still opted in via PGDATABASE) can tell it's
      # ours vs. having been silently repurposed by another package.
      SchemaOwnerGuard.stamp!(&TestRepo.query!/1)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

      # Compile the require_file paths in elixirc_paths(:test) — needed so
      # support modules are loaded before tests reference them.
      Code.require_file("support/data_case.ex", __DIR__)
      Code.require_file("support/live_case.ex", __DIR__)
      Code.require_file("support/activity_log_assertions.ex", __DIR__)

      true
    rescue
      e in SchemaOwnerGuard.OwnerMismatch ->
        reraise e, __STACKTRACE__

      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_entities, :test_repo_available, repo_available)

# Start minimal PhoenixKit services needed for tests. Web.Hooks (which
# the admin LVs install via on_mount) tracks page visits via
# SimplePresence — without the GenServer running every LV mount crashes
# with "no process" during the on_mount phase.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
{:ok, _pid} = PhoenixKit.Admin.SimplePresence.start_link([])

# Mirror enable_all_*_mirror flows spawn supervised tasks under
# PhoenixKit.TaskSupervisor (mirror file writes after definition
# changes). Without this the publishing-precedent
# GenServer.call(:noproc) bubbles up to the LV / context fn caller.
{:ok, _pid} = Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor)

# DataForm and EntityForm mount presence tracking via
# `PhoenixKitEntities.Presence` (the module's own Phoenix.Tracker for
# editing locks). Without this, every DataForm/EntityForm LV test
# crashes during mount with "the table identifier does not refer to an
# existing ETS table". Phoenix.Presence is supervised, not start_link'd
# directly, so wrap in a tiny supervisor for the test boot sequence.
{:ok, _pid} =
  Supervisor.start_link([PhoenixKitEntities.Presence],
    strategy: :one_for_one,
    name: PhoenixKitEntities.Test.PresenceSupervisor
  )

# Start the test endpoint so Phoenix.LiveViewTest can render LVs.
# Skipped if the repo isn't available — LV tests need both.
if repo_available do
  {:ok, _pid} = PhoenixKitEntities.Test.Endpoint.start_link()
end

# The `gettext_backend`/`gettext_domain` API on PhoenixKit.Dashboard.Tab
# (phoenix_kit core PR #522) is required by the i18n smoke test. This
# module's floor already requires phoenix_kit ~> 2.0, which ships the API,
# but the check stays in place so a future floor relaxation degrades
# gracefully instead of raising UndefinedFunctionError.
i18n_api_available =
  Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
    function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)

unless i18n_api_available do
  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )
end

# `PhoenixKit.Test.Fixtures.user_fixture/1` and friends go through
# `PhoenixKit.Users.Auth.register_user/2`, which calls the Hammer-backed rate
# limiter. Without this its ETS table does not exist and every fixture dies with
# "the table identifier does not refer to an existing ETS table". Mirrors core's
# `phoenix_kit/test/test_helper.exs` and the same lines in billing, calendar,
# ecommerce, projects and staff.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Tests for behaviour that exists in local core but not in the released pin.
# They fail against Hex because the feature isn't there yet, so the default run
# skips them:
#
#     PHOENIX_KIT_PATH=../phoenix_kit PGDATABASE=phoenix_kit_entities_v169_test \
#       mix test --include needs_unreleased_core
#
# Currently: core V169, which makes `phoenix_kit_entity_data.created_by_uuid`
# nullable so an anonymous public submission stores NULL instead of being
# attributed to the first admin. Point that run at its OWN database — the suite
# migrates whatever it is given, so reusing the normal test database would move
# it to V169 and flip the default run's expectations.
#
# Delete each from the tests and this line once the pin catches up.
exclude =
  [
    if(!repo_available, do: :integration),
    if(!i18n_api_available, do: :requires_phoenix_kit_i18n_api),
    :needs_unreleased_core
  ]
  |> Enum.filter(& &1)

ExUnit.start(exclude: exclude)
