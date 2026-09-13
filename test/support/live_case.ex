defmodule PhoenixKitEntities.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitEntities.Web.EntitiesLiveTest do
        use PhoenixKitEntities.LiveCase

        test "renders the entity list", %{conn: conn} do
          conn = put_test_scope(conn, fake_scope())
          {:ok, _view, html} = live(conn, "/en/admin/entities")
          assert html =~ "All Entities"
        end
      end

  ## Scope assigns

  Entities admin LiveViews thread `socket.assigns[:phoenix_kit_current_scope]`
  through every mutation context call (`actor_opts/1`). Tests can plug a
  fake scope via `put_test_scope/2` (a Plug-style helper that sets the
  scope on the conn before `live/2`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitEntities.Test.Endpoint

      require Logger

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitEntities.ActivityLogAssertions
      import PhoenixKitEntities.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEntities.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Most admin LiveViews check `Scope.can_access_admin_area?(scope)`
  (pattern-matched on `%PhoenixKit.Users.Auth.Scope{}`). The struct's
  `:cached_roles` / `:authenticated?` drive `can_access_admin_area?/1`;
  `:cached_permissions` is a MapSet consulted by `has_module_access?/2`.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4 (good enough for tests)
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `can_access_admin_area?/1` true
    * `:permissions` — list of module-key strings; `["entities"]`
      grants admin access to entities pages
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope(permissions: ["entities"]))
      {:ok, _view, html} = live(conn, "/en/admin/entities")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, ["entities"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    # Use a real `%PhoenixKit.Users.Auth.User{}` struct rather than a
    # plain map. Production hooks call `Scope.user_uuid/1` which has
    # function clauses pattern-matching on `%User{}` — a map raises
    # `FunctionClauseError` during on_mount.
    user = %PhoenixKit.Users.Auth.User{uuid: user_uuid, email: email}

    # `cached_roles` is a LIST (the production code stores role *names*
    # like `"Owner"`/`"Admin"` from `Role.system_roles/0`, NOT atoms or a
    # MapSet) — `Scope.can_access_admin_area?/1` pattern-matches
    # `is_list(cached_roles)`.
    # `cached_permissions` is a MapSet checked via membership.
    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/entities")
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
