defmodule PhoenixKitEntities.PublicFormTurnstileTest do
  @moduledoc """
  Cloudflare Turnstile on an entity's public form: the settings helper, the
  widget in the `EntityForm` component, the `check_turnstile` step of
  `EntityFormController.submit/2` and the builder's controls.

  Cloudflare is never called. Core routes its siteverify request through
  `Req.Test`-style plug options (`config :phoenix_kit, :turnstile_req_options,
  plug: ...`); the plug here plays Cloudflare and reports every request it
  receives to the test.
  """
  use PhoenixKitEntities.DataCase, async: false

  require Phoenix.LiveViewTest

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, fetch_flash: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.EntityForm
  alias PhoenixKitEntities.Controllers.EntityFormController
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.PublicFormTurnstile
  alias PhoenixKitEntities.Test.TurnstileStub

  @field "cf-turnstile-response"

  setup do
    TurnstileStub.install()
    admin = Fixtures.admin_fixture()
    connection = TurnstileStub.verified_connection!("Contact forms", "0x4AAAA-site-key")

    {:ok, admin: admin, connection: connection}
  end

  defp create_entity(admin, settings) do
    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "turnstile_form",
          display_name: "Turnstile Form",
          display_name_plural: "Turnstile Forms",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          settings:
            Map.merge(
              %{"public_form_enabled" => true, "public_form_fields" => ["name"]},
              settings
            ),
          created_by_uuid: admin.uuid
        },
        actor_uuid: admin.uuid
      )

    entity
  end

  defp protected_entity(%{admin: admin, connection: connection}, extra \\ %{}) do
    create_entity(
      admin,
      Map.merge(
        %{"public_form_turnstile" => true, "public_form_turnstile_connection" => connection},
        extra
      )
    )
  end

  defp submit(entity, token, extra_params \\ %{}) do
    params =
      %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"name" => "Ann"}}
      }
      |> Map.merge(if token == :none, do: %{}, else: %{@field => token})
      |> Map.merge(extra_params)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> fetch_flash()
    |> EntityFormController.submit(params)
  end

  defp records(entity), do: EntityData.list_by_entity(entity.uuid)
  defp stats(entity), do: Entities.get_entity!(entity.uuid).settings["public_form_stats"] || %{}
  defp error_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)
  defp info_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)

  describe "PublicFormTurnstile settings helper" do
    test "on for true and for the string a hand-edited or imported setting would hold" do
      refute PublicFormTurnstile.enabled?(nil)
      refute PublicFormTurnstile.enabled?(%{})
      refute PublicFormTurnstile.enabled?(%{"public_form_turnstile" => false})
      refute PublicFormTurnstile.enabled?(%{"public_form_turnstile" => "false"})
      refute PublicFormTurnstile.enabled?(%{"public_form_turnstile" => 1})
      assert PublicFormTurnstile.enabled?(%{"public_form_turnstile" => true})
      assert PublicFormTurnstile.enabled?(%{"public_form_turnstile" => "true"})
    end

    test "an upper-case UUID names the same connection", %{connection: connection} do
      settings = %{
        "public_form_turnstile" => true,
        "public_form_turnstile_connection" => String.upcase(connection)
      }

      assert PublicFormTurnstile.connection(settings) == connection
      assert PublicFormTurnstile.status(settings, [{connection, "Contact forms"}]) == :ready
      assert PublicFormTurnstile.site_key(settings) == "0x4AAAA-site-key"
    end

    test "status names why a switched-on form is not protected", %{connection: connection} do
      on = %{"public_form_turnstile" => true}
      choices = [{connection, "Contact forms"}]

      assert PublicFormTurnstile.status(%{}, choices) == :off
      assert PublicFormTurnstile.status(on, []) == :no_connections
      assert PublicFormTurnstile.status(on, choices) == :no_selection

      assert PublicFormTurnstile.status(
               Map.put(on, "public_form_turnstile_connection", ""),
               choices
             ) ==
               :no_selection

      assert PublicFormTurnstile.status(
               Map.put(on, "public_form_turnstile_connection", Ecto.UUID.generate()),
               choices
             ) == :stale_selection

      assert PublicFormTurnstile.status(
               Map.put(on, "public_form_turnstile_connection", connection),
               choices
             ) == :ready
    end

    test "choices lists the verified connections only", %{connection: connection} do
      {:ok, %{uuid: unverified}} = Integrations.add_connection("cloudflare_turnstile", "Draft")

      uuids = Enum.map(PublicFormTurnstile.choices(), &elem(&1, 0))
      assert connection in uuids
      refute unverified in uuids
    end

    test "site_key is the connection's public key, and nil when off or unusable", ctx do
      assert PublicFormTurnstile.site_key(%{
               "public_form_turnstile" => true,
               "public_form_turnstile_connection" => ctx.connection
             }) == "0x4AAAA-site-key"

      assert PublicFormTurnstile.site_key(%{"public_form_turnstile_connection" => ctx.connection}) ==
               nil

      assert PublicFormTurnstile.site_key(%{"public_form_turnstile" => true}) == nil

      assert PublicFormTurnstile.site_key(%{
               "public_form_turnstile" => true,
               "public_form_turnstile_connection" => Ecto.UUID.generate()
             }) == nil
    end
  end

  describe "the widget in the component" do
    defp render_form(entity) do
      Phoenix.LiveViewTest.render_component(&EntityForm.render/1,
        attributes: %{"entity_slug" => entity.name},
        content: nil,
        variant: "default"
      )
      |> LazyHTML.from_fragment()
    end

    defp widget(document),
      do: LazyHTML.query(document, "form #entity-form-turnstile-turnstile_form")

    test "is inside the form with the connection's site key when on and configured", ctx do
      entity = protected_entity(ctx)
      widget = entity |> render_form() |> widget()

      assert [{"div", attrs, _}] = LazyHTML.to_tree(widget)
      attrs = Map.new(attrs)
      assert attrs["data-sitekey"] == "0x4AAAA-site-key"
      assert attrs["phx-hook"] == "Turnstile"
    end

    test "is absent while the option is off", %{admin: admin} do
      entity = create_entity(admin, %{})
      assert entity |> render_form() |> widget() |> Enum.empty?()
    end

    test "the form carries what the bundle finds it by, and the texts it shows", ctx do
      document = ctx |> protected_entity() |> render_form()

      assert [key] =
               LazyHTML.query(document, "form input[name=_turnstile_sitekey]") |> Enum.to_list()

      assert LazyHTML.attribute(key, "value") == ["0x4AAAA-site-key"]
      assert LazyHTML.attribute(key, "type") == ["hidden"]

      assert [_] = LazyHTML.query(document, "form .entity-turnstile-widget") |> Enum.to_list()

      assert [status] =
               LazyHTML.query(document, "form .entity-turnstile-status") |> Enum.to_list()

      assert LazyHTML.attribute(status, "role") == ["status"]
      # Empty until the JS speaks: nothing alarming on a page that never loads it.
      assert String.trim(LazyHTML.text(status)) == ""

      for {kind, words} <- [
            {"wait", "wait for the verification to finish"},
            {"blocked", "blocking challenges.cloudflare.com"},
            {"error", "could not start"}
          ] do
        assert [text] =
                 LazyHTML.query(document, "form .entity-turnstile-text-#{kind}") |> Enum.to_list()

        assert LazyHTML.text(text) =~ words
        # Hidden by an inline style, which a sanitizer keeps; `hidden` it would not.
        assert [_] =
                 LazyHTML.query(
                   document,
                   "form div[style='display: none'] .entity-turnstile-text-#{kind}"
                 )
                 |> Enum.to_list()
      end
    end

    test "none of it is drawn without the widget", %{admin: admin} do
      for settings <- [%{}, %{"public_form_turnstile" => true}] do
        entity = create_entity(admin, settings)
        document = render_form(entity)

        for selector <- ["input[name=_turnstile_sitekey]", "[class*=entity-turnstile]"] do
          assert document |> LazyHTML.query(selector) |> Enum.empty?()
        end

        {:ok, _} = Entities.delete_entity(entity)
      end
    end

    test "is absent, and the form still renders, when the option is on without a usable connection",
         %{admin: admin} do
      for settings <- [
            %{"public_form_turnstile" => true},
            %{
              "public_form_turnstile" => true,
              "public_form_turnstile_connection" => Ecto.UUID.generate()
            }
          ] do
        entity = create_entity(admin, settings)
        document = render_form(entity)

        assert document |> widget() |> Enum.empty?()
        refute document |> LazyHTML.query("form button[type=submit]") |> Enum.empty?()

        {:ok, _} = Entities.delete_entity(entity)
      end
    end

    test "is not drawn for a form that is unavailable", ctx do
      entity = protected_entity(ctx, %{"public_form_enabled" => false})
      assert entity |> render_form() |> widget() |> Enum.empty?()
    end
  end

  describe "check_turnstile in submit/2" do
    test "option off: the token is not looked at, nothing is sent to Cloudflare", %{admin: admin} do
      entity = create_entity(admin, %{})

      conn = submit(entity, :none)

      assert info_flash(conn)
      assert [_] = records(entity)
      refute_received {:siteverify, _}
    end

    test "a good token is accepted, and Cloudflare is asked with the token and the client address",
         ctx do
      entity = protected_entity(ctx)

      conn = submit(entity, "good-token")

      assert info_flash(conn)
      assert [%{status: "published"}] = records(entity)
      assert_received {:siteverify, form}
      assert form["secret"] == TurnstileStub.secret()
      assert form["response"] == "good-token"
      assert form["remoteip"] == "127.0.0.1"
    end

    test "no token: refused with the retry message, no record, no call to Cloudflare", ctx do
      entity = protected_entity(ctx)

      conn = submit(entity, :none)

      assert error_flash(conn) =~ "wait for the verification to finish"
      assert records(entity) == []
      refute_received {:siteverify, _}
      assert %{"rejected_submissions" => 1, "turnstile_missing_triggers" => 1} = stats(entity)
      refute Map.has_key?(stats(entity), "turnstile_triggers")
    end

    test "the missing-token message follows the posted form language", ctx do
      {:ok, _} = Languages.enable_system()
      entity = protected_entity(ctx)

      for {locale, message} <- [{"de-DE", "Bitte warten Sie"}, {"fr-FR", "Attendez la fin"}] do
        {:ok, _} = Languages.add_language(locale)
        assert error_flash(submit(entity, :none, %{"_locale" => locale})) =~ message
      end
    end

    test "a blank or crafted token counts as no token", ctx do
      entity = protected_entity(ctx)

      for token <- ["", "   ", %{"x" => "1"}, ["good-token"]] do
        conn = submit(entity, token)
        assert error_flash(conn) =~ "wait for the verification to finish"
      end

      assert records(entity) == []
      refute_received {:siteverify, _}
    end

    test "a token Cloudflare refuses: refused, no record", ctx do
      entity = protected_entity(ctx)

      conn = submit(entity, "forged-token")

      assert error_flash(conn) =~ "complete the verification"
      assert records(entity) == []
      assert_received {:siteverify, %{"response" => "forged-token"}}
      assert %{"turnstile_triggers" => 1} = stats(entity)
      refute Map.has_key?(stats(entity), "turnstile_missing_triggers")
    end

    test "debug mode names the check", ctx do
      entity = protected_entity(ctx, %{"public_form_debug_mode" => true})

      assert error_flash(submit(entity, "forged-token")) =~
               "[Debug] Submission rejected: Turnstile"
    end

    test "reject_silent shows a fake success and saves nothing", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "reject_silent"})

      conn = submit(entity, "forged-token")

      assert info_flash(conn)
      refute error_flash(conn)
      assert records(entity) == []
    end

    test "reject_silent never swallows a missing token: that visitor's widget did not start",
         ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "reject_silent"})

      for token <- [:none, "", "   ", %{"x" => "1"}] do
        conn = submit(entity, token)

        assert error_flash(conn) =~ "wait for the verification to finish"
        refute info_flash(conn)
      end

      assert records(entity) == []
      assert %{"turnstile_missing_triggers" => 4} = stats(entity)
    end

    test "a missing token under save_suspicious still saves, flagged", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "save_suspicious"})

      submit(entity, :none)

      assert [%{status: "draft", metadata: metadata}] = records(entity)
      assert [%{"type" => "turnstile_missing"}] = metadata["security_warnings"]
    end

    test "save_suspicious saves a draft carrying the warning", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "save_suspicious"})

      conn = submit(entity, "forged-token")

      assert info_flash(conn)
      assert [%{status: "draft", metadata: metadata}] = records(entity)

      assert %{"type" => "turnstile", "action" => "save_suspicious"} in metadata[
               "security_warnings"
             ]
    end

    test "save_log saves normally and logs a warning", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "save_log"})

      log =
        capture_log(fn ->
          conn = submit(entity, "forged-token")
          assert info_flash(conn)
        end)

      assert [%{status: "published"}] = records(entity)
      assert log =~ "security flags: [:turnstile]"
    end

    test "an unset action means reject_error", ctx do
      entity = protected_entity(ctx)
      refute Map.has_key?(entity.settings, "public_form_turnstile_action")

      assert error_flash(submit(entity, "forged-token"))
    end

    test "an action nobody understands refuses instead of opening the form", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "let_it_through"})

      assert error_flash(submit(entity, "forged-token"))
      assert records(entity) == []
    end

    test "a request another check already refuses does not cost a call to Cloudflare", ctx do
      entity =
        protected_entity(ctx, %{
          "public_form_honeypot" => true,
          "public_form_honeypot_action" => "reject_error"
        })

      conn = submit(entity, "good-token", %{"_hp_website" => "filled"})

      assert error_flash(conn)
      assert records(entity) == []
      refute_received {:siteverify, _}
    end

    test "flags from several checks are recorded together", ctx do
      entity =
        protected_entity(ctx, %{
          "public_form_honeypot" => true,
          "public_form_honeypot_action" => "save_suspicious",
          "public_form_turnstile_action" => "save_suspicious"
        })

      submit(entity, "forged-token", %{"_hp_website" => "filled"})

      assert [%{status: "draft", metadata: metadata}] = records(entity)
      types = Enum.map(metadata["security_warnings"], & &1["type"])
      assert Enum.sort(types) == ["honeypot", "turnstile"]
    end
  end

  describe "when Cloudflare gives no verdict" do
    test "the form fails closed with a try-again message", ctx do
      entity = protected_entity(ctx)

      conn = submit(entity, "cloudflare-is-down")

      assert error_flash(conn) =~ "not available right now"
      assert records(entity) == []
      assert %{"turnstile_unavailable_triggers" => 1} = stats(entity)
    end

    test "reject_silent is made loud: a real visitor is not told it worked", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "reject_silent"})

      conn = submit(entity, "cloudflare-is-down")

      assert error_flash(conn) =~ "not available right now"
      refute info_flash(conn)
      assert records(entity) == []
    end

    test "save_suspicious still saves, flagged as unavailable", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile_action" => "save_suspicious"})

      submit(entity, "cloudflare-is-down")

      assert [%{status: "draft", metadata: metadata}] = records(entity)
      assert [%{"type" => "turnstile_unavailable"}] = metadata["security_warnings"]
    end
  end

  describe "when the option is on but the connection cannot verify" do
    defp assert_unchecked(entity, log) do
      assert [%{status: "published", metadata: metadata}] = records(entity)

      assert [%{"type" => "turnstile_unchecked", "action" => "none"}] =
               metadata["security_warnings"]

      assert %{"turnstile_unchecked_triggers" => 1, "successful_submissions" => 1} = stats(entity)
      refute_received {:siteverify, _}

      # The log line says which form it was.
      assert log =~ "was not checked"
      assert log =~ entity.name
      assert log =~ entity.uuid
    end

    defp submit_logged(entity, token \\ :none) do
      capture_log(fn -> assert info_flash(submit(entity, token)) end)
    end

    test "no connection selected: the submission goes through, flagged and counted", %{
      admin: admin
    } do
      entity = create_entity(admin, %{"public_form_turnstile" => true})

      assert_unchecked(entity, submit_logged(entity))
    end

    test "a connection that was removed", ctx do
      entity = protected_entity(ctx)
      :ok = Integrations.remove_connection(ctx.connection)

      assert_unchecked(entity, submit_logged(entity))
    end

    test "a connection that exists but is no longer connected", ctx do
      entity = protected_entity(ctx)
      :ok = Integrations.record_validation(ctx.connection, {:error, "Cloudflare refused the key"})

      refute ctx.connection in Enum.map(PublicFormTurnstile.choices(), &elem(&1, 0))
      assert_unchecked(entity, submit_logged(entity))
    end

    test "a token is not looked at either", ctx do
      entity = protected_entity(ctx)
      :ok = Integrations.remove_connection(ctx.connection)

      assert_unchecked(entity, submit_logged(entity, "forged-token"))
    end

    test "the flag does not hide another check's flag", ctx do
      entity =
        protected_entity(ctx, %{
          "public_form_honeypot" => true,
          "public_form_honeypot_action" => "save_suspicious"
        })

      :ok = Integrations.remove_connection(ctx.connection)
      capture_log(fn -> submit(entity, :none, %{"_hp_website" => "filled"}) end)

      assert [%{status: "draft", metadata: metadata}] = records(entity)
      types = Enum.map(metadata["security_warnings"], & &1["type"])
      assert Enum.sort(types) == ["honeypot", "turnstile_unchecked"]
    end
  end

  describe "the option stored as a string" do
    test "is on, and checks the token", ctx do
      entity = protected_entity(ctx, %{"public_form_turnstile" => "true"})

      assert error_flash(submit(entity, "forged-token"))
      assert records(entity) == []
    end
  end
end
