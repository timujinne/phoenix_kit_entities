defmodule PhoenixKitEntities.Web.EntityFormTurnstileLiveTest do
  @moduledoc """
  The builder's Cloudflare Turnstile controls (`Web.EntityForm`): the option
  sits with the other security options, saves with the entity, and warns while
  it is on but there is nothing to verify with.
  """
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Test.TurnstileStub

  setup do
    TurnstileStub.install()
    actor_uuid = Ecto.UUID.generate()
    connection = TurnstileStub.verified_connection!("Contact forms", "0x4AAAA-site-key")

    {:ok, actor_uuid: actor_uuid, connection: connection}
  end

  defp create_entity(actor_uuid, settings) do
    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "ts_builder",
          display_name: "TS Builder",
          display_name_plural: "TS Builders",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          settings:
            Map.merge(
              %{"public_form_enabled" => true, "public_form_fields" => ["name"]},
              settings
            ),
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    entity
  end

  defp edit(conn, entity, actor_uuid) do
    conn = put_test_scope(conn, fake_scope(user_uuid: actor_uuid))
    {:ok, view, html} = live(conn, "/en/admin/entities/#{entity.uuid}/edit")
    {view, html}
  end

  # What a browser sends when a select with its own `phx-change` changes: that
  # select's name and value, nothing else. Driven through the real element.
  defp change_select(view, name, value) do
    view |> element("select[name=#{name}]") |> render_change(%{name => value})
  end

  defp pick_connection(view, uuid),
    do: change_select(view, "public_form_turnstile_connection", uuid)

  defp save(view) do
    view
    |> form("form[phx-change='validate']", %{"entities" => %{"display_name" => "Saved"}})
    |> render_submit()
  end

  defp socket_settings(view), do: :sys.get_state(view.pid).socket.assigns.entity.settings

  test "the option is offered next to the other security options, off by default",
       %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{})
    {view, _html} = edit(conn, entity, actor_uuid)

    assert has_element?(view, "#public-form-turnstile input[name=public_form_turnstile]")

    refute has_element?(
             view,
             "#public-form-turnstile input[name=public_form_turnstile][checked]"
           )

    refute has_element?(view, "#public-form-turnstile select")
  end

  test "the switch only toggles its setting and treats an imported false as off",
       %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{"public_form_turnstile" => "false"})
    {view, _html} = edit(conn, entity, actor_uuid)
    settings = socket_settings(view)
    render_click(view, "toggle_security_setting", %{"setting" => "public_form_title"})
    assert socket_settings(view) == settings

    view |> element("input[name=public_form_turnstile]") |> render_click()
    assert socket_settings(view)["public_form_turnstile"] == true
  end

  test "the switch, the connection and the action save with the entity",
       %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
    entity = create_entity(actor_uuid, %{})
    {view, _html} = edit(conn, entity, actor_uuid)

    view |> element("#public-form-turnstile input[name=public_form_turnstile]") |> render_click()

    assert has_element?(
             view,
             "#public-form-turnstile select[name=public_form_turnstile_connection] option",
             "Contact forms"
           )

    pick_connection(view, connection)

    change_select(view, "public_form_turnstile_action", "save_log")

    save(view)

    assert %{
             "public_form_turnstile" => true,
             "public_form_turnstile_connection" => ^connection,
             "public_form_turnstile_action" => "save_log"
           } = Entities.get_entity!(entity.uuid).settings
  end

  test "warns while the option is on and no connection is selected",
       %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
    entity = create_entity(actor_uuid, %{"public_form_turnstile" => true})
    {view, _html} = edit(conn, entity, actor_uuid)

    assert has_element?(view, "#turnstile-not-ready", "Select a Turnstile connection")

    pick_connection(view, connection)

    refute has_element?(view, "#turnstile-not-ready")
  end

  test "warns when no verified connection exists at all",
       %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
    :ok = Integrations.remove_connection(connection)
    entity = create_entity(actor_uuid, %{"public_form_turnstile" => true})
    {view, _html} = edit(conn, entity, actor_uuid)

    assert has_element?(view, "#turnstile-not-ready", "No verified Cloudflare Turnstile")
  end

  test "warns about a selected connection that is gone",
       %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
    entity =
      create_entity(actor_uuid, %{
        "public_form_turnstile" => true,
        "public_form_turnstile_connection" => connection
      })

    # Another verified connection remains, so the form can be fixed by picking it.
    TurnstileStub.verified_connection!("Other site", "0x4AAAA-other-key")
    :ok = Integrations.remove_connection(connection)
    {view, _html} = edit(conn, entity, actor_uuid)

    assert has_element?(view, "#turnstile-not-ready", "gone or no longer verified")
  end

  test "no warning while the option is off", %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{})
    {view, _html} = edit(conn, entity, actor_uuid)

    refute has_element?(view, "#turnstile-not-ready")
  end

  test "the trigger counters show", %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{})

    Entities.bump_public_form_stats(entity.uuid, [
      "turnstile_triggers",
      "turnstile_unavailable_triggers"
    ])

    {_view, html} = edit(conn, entity, actor_uuid)

    assert html =~ "Turnstile: 1"
    assert html =~ "Turnstile unavailable: 1"
  end

  test "the older action selects save from a real change event too, and survive Save",
       %{conn: conn, actor_uuid: actor_uuid} do
    entity =
      create_entity(actor_uuid, %{
        "public_form_honeypot" => true,
        "public_form_time_check" => true,
        "public_form_rate_limit" => true
      })

    {view, _html} = edit(conn, entity, actor_uuid)

    change_select(view, "public_form_honeypot_action", "save_suspicious")
    change_select(view, "public_form_time_check_action", "save_log")
    change_select(view, "public_form_rate_limit_action", "reject_silent")

    save(view)

    stored = Entities.get_entity!(entity.uuid).settings
    assert stored["public_form_honeypot_action"] == "save_suspicious"
    assert stored["public_form_time_check_action"] == "save_log"
    assert stored["public_form_rate_limit_action"] == "reject_silent"
    refute Map.has_key?(stored, "nil")
    refute Map.has_key?(stored, nil)
  end

  test "a change event that is not one of the selects' own is ignored",
       %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{"public_form_turnstile" => true})
    {view, _html} = edit(conn, entity, actor_uuid)
    before = socket_settings(view)

    select = view |> element("select[name=public_form_turnstile_action]")
    render_change(select, %{"public_form_turnstile_action" => "let_it_through"})
    render_change(select, %{"public_form_turnstile_action" => %{"x" => "1"}})
    render_hook(view, "update_security_action", %{"somebody_elses_setting" => "x"})
    render_hook(view, "update_security_action", %{"setting" => "sort_mode", "value" => "manual"})

    connection = view |> element("select[name=public_form_turnstile_connection]")
    render_change(connection, %{"public_form_turnstile_connection" => Ecto.UUID.generate()})
    render_change(connection, %{"public_form_turnstile_connection" => ["x"]})

    assert socket_settings(view) == before
  end

  test "clearing the connection removes it", %{
    conn: conn,
    actor_uuid: actor_uuid,
    connection: connection
  } do
    entity =
      create_entity(actor_uuid, %{
        "public_form_turnstile" => true,
        "public_form_turnstile_connection" => connection
      })

    {view, _html} = edit(conn, entity, actor_uuid)
    pick_connection(view, "")
    save(view)

    refute Map.has_key?(
             Entities.get_entity!(entity.uuid).settings,
             "public_form_turnstile_connection"
           )

    assert has_element?(view, "#turnstile-not-ready")
  end

  test "the connections are read only while the option is on, and when it is switched on",
       %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
    entity = create_entity(actor_uuid, %{})
    {view, _html} = edit(conn, entity, actor_uuid)

    assert :sys.get_state(view.pid).socket.assigns.turnstile_choices == []

    # One added while the page was open shows up when the option is switched on.
    other = TurnstileStub.verified_connection!("Added later", "0x4AAAA-later-key")
    view |> element("#public-form-turnstile input[name=public_form_turnstile]") |> render_click()

    uuids = Enum.map(:sys.get_state(view.pid).socket.assigns.turnstile_choices, &elem(&1, 0))
    assert Enum.sort(uuids) == Enum.sort([connection, other])
  end

  test "the counters of missing tokens and unchecked submissions show, the latter as an error",
       %{conn: conn, actor_uuid: actor_uuid} do
    entity = create_entity(actor_uuid, %{})

    Entities.bump_public_form_stats(entity.uuid, [
      "turnstile_missing_triggers",
      "turnstile_unchecked_triggers"
    ])

    {view, _html} = edit(conn, entity, actor_uuid)

    assert has_element?(view, "#turnstile-missing-count", "1")
    assert has_element?(view, "#turnstile-unchecked-count.badge-error", "1")
  end

  describe "the connections stay current in every copy of the page" do
    defp edit_as(conn, entity, user_uuid) do
      conn = put_test_scope(conn, fake_scope(user_uuid: user_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{entity.uuid}/edit")
      view
    end

    defp choice_ids(view),
      do: Enum.map(:sys.get_state(view.pid).socket.assigns.turnstile_choices, &elem(&1, 0))

    test "a spectator sees the connection the owner picked, not a false warning",
         %{conn: conn, actor_uuid: owner, connection: connection} do
      entity = create_entity(owner, %{})
      owner_view = edit_as(conn, entity, owner)
      spectator = edit_as(conn, entity, Ecto.UUID.generate())

      # The spectator opened with the option off, so it read no connections.
      assert choice_ids(spectator) == []

      owner_view
      |> element("#public-form-turnstile input[name=public_form_turnstile]")
      |> render_click()

      pick_connection(owner_view, connection)

      assert choice_ids(spectator) == [connection]
      refute has_element?(spectator, "#turnstile-not-ready")

      assert has_element?(
               spectator,
               "#public-form-turnstile select[name=public_form_turnstile_connection] option[selected]",
               "Contact forms"
             )
    end

    test "a spectator promoted to owner gets a picker that works",
         %{conn: conn, actor_uuid: owner, connection: connection} do
      entity = create_entity(owner, %{})
      view = edit_as(conn, entity, owner)
      assert choice_ids(view) == []

      # Meanwhile another session switched the option on and saved, then left:
      # this page, a spectator until now, is promoted and reloads the entity.
      {:ok, _} =
        Entities.update_entity(entity, %{
          settings: Map.put(entity.settings, "public_form_turnstile", true)
        })

      :sys.replace_state(view.pid, &put_in(&1.socket.assigns[:lock_owner?], false))
      send(view.pid, %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{}})
      _ = render(view)

      assert :sys.get_state(view.pid).socket.assigns.lock_owner?
      assert choice_ids(view) == [connection]

      pick_connection(view, connection)
      save(view)

      assert Entities.get_entity!(entity.uuid).settings["public_form_turnstile_connection"] ==
               connection
    end

    test "a reset keeps them", %{conn: conn, actor_uuid: actor_uuid, connection: connection} do
      entity = create_entity(actor_uuid, %{"public_form_turnstile" => true})
      {view, _html} = edit(conn, entity, actor_uuid)
      :sys.replace_state(view.pid, &put_in(&1.socket.assigns[:turnstile_choices], []))

      render_click(view, "reset", %{})

      assert choice_ids(view) == [connection]
    end
  end
end
