defmodule PhoenixKitEntities.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which is configured by core `phoenix_kit` to populate
  `socket.assigns[:phoenix_kit_current_scope]` and
  `socket.assigns[:phoenix_kit_current_user]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module replicates the same effect by pulling scope data from the
  test session.

  Tests set scope via `LiveCase.put_test_scope/2` (which calls
  `Plug.Test.init_test_session/2`); the `:assign_scope` hook below
  reads it back and mirrors it onto socket assigns.

  The hook also seeds `:current_locale` so the entity LVs (which
  thread `lang: @current_locale` through every list/get call) don't
  crash when the test runs without a session-set locale.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Modules.Languages

  @doc """
  `on_mount` callback. Reads `"phoenix_kit_test_scope"` from session and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. Always assigns `:current_locale` and
  `:current_locale_base` so admin LVs that thread the locale through
  paths and queries don't crash on missing assigns.
  """
  def on_mount(:assign_scope, _params, session, socket) do
    # The page language, as production's locale hook sets it from a `/fr/…`
    # URL — `LiveCase.with_request_locale/2` puts it in the session.
    with %{"pk_test_request_locale" => dialect} when is_binary(dialect) <- session do
      Languages.put_request_locale(dialect)
    end

    socket =
      socket
      |> assign(:current_locale, session["phoenix_kit_test_locale"] || "en-US")
      |> assign(:current_locale_base, session["phoenix_kit_test_locale_base"] || "en")
      |> assign(:url_path, "/en/admin/entities")

    socket =
      case Map.get(session, "phoenix_kit_test_scope") do
        nil ->
          socket

        %{user: user} = scope ->
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)
      end

    {:cont, socket}
  end
end
