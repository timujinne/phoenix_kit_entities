defmodule PhoenixKitEntities.Test.LiveDatabaseGuard do
  @moduledoc """
  S014: `config/test.exs` honours `PGDATABASE` — precisely so the suite can
  target an already-provisioned database when the running role lacks
  `CREATEDB` — which means a shell that exports `PGDATABASE` for some other
  purpose (or simply forgets to unset it) makes a bare `mix test` silently
  resolve its test database to whatever that variable points at, and hand it
  straight to the Ecto sandbox to migrate and seed.

  This guard refuses by NAME, before any database connection is attempted,
  using two independent rules:

    1. The resolved name must look like a test database: it must end in
       `_test`, optionally followed by digits (`foo_test`, `foo_test2`).
       Any other shape — `foo_dev`, `foo_prod`, or just `foo` — is refused
       on sight; a database not named like a test database is exactly the
       mistake this guard exists to catch.

    2. Independently, a fleet or operator can list additional names to
       refuse (even ones that DO end in `_test`) via the
       `PHOENIX_KIT_LIVE_DATABASES` environment variable — a comma-separated
       list, read at check time. Nothing machine-specific is committed to
       this repo; each environment supplies its own list locally.

  Deliberately ADDED alongside `PhoenixKitEntities.Test.SchemaOwnerGuard`
  (I067's `schema_migrations` ownership marker), not instead of it — that
  mechanism solves a different, real problem (two guard-wearing packages
  colliding on a shared scratch database) and stays exactly as it is.
  `SchemaOwnerGuard.check!/1` reads a database it has never seen —
  comment-less `schema_migrations` included — as `:ok`. A live database
  populated by ordinary `mix ecto.migrate` is exactly that shape: nothing
  has ever stamped it, so a marker check alone would wave it through. This
  guard closes that gap by checking the name itself, before either guard
  ever opens a connection.
  """

  @test_name_pattern ~r/_test\d*$/

  defmodule LiveDatabaseError do
    defexception [:message]
  end

  @doc """
  Raises `LiveDatabaseError` if `database` does not look like a test
  database, or is explicitly listed in `PHOENIX_KIT_LIVE_DATABASES`. Takes
  the already-resolved name (what `config/test.exs` put in
  `Application.get_env/2`), not `PGDATABASE` itself — the config file's own
  fallback-when-unset logic is the single source of truth for what the
  suite will actually connect to, and duplicating it here would drift the
  moment either copy changed.
  """
  @spec check!(String.t()) :: :ok
  def check!(database) when is_binary(database) do
    cond do
      database in configured_live_databases() ->
        raise LiveDatabaseError,
          message: """
          Test database resolved to #{inspect(database)}, which is listed in \
          PHOENIX_KIT_LIVE_DATABASES as a database this environment must never \
          let a test suite touch. Point PGDATABASE at an isolated test \
          database instead (one ending in `_test`), or unset it to fall back \
          to this module's own default.\
          """

      not Regex.match?(@test_name_pattern, database) ->
        raise LiveDatabaseError,
          message: """
          Test database resolved to #{inspect(database)}, which does not look \
          like a test database (expected a name ending in `_test`, optionally \
          followed by digits, e.g. "myapp_test" or "myapp_test2"). Unset \
          PGDATABASE, or point it at an isolated test database named \
          accordingly.\
          """

      true ->
        :ok
    end
  end

  defp configured_live_databases do
    "PHOENIX_KIT_LIVE_DATABASES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end
end
