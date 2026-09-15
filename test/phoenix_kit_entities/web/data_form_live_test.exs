defmodule PhoenixKitEntities.Web.DataFormLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "df_test",
          display_name: "DF Test",
          display_name_plural: "DF Tests",
          fields_definition: [
            %{"type" => "text", "key" => "name", "label" => "Name"},
            %{"type" => "boolean", "key" => "active", "label" => "Active"}
          ],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, record} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Hello",
          slug: "hello",
          status: "published",
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{
              "_title" => "Hello",
              "_slug" => "hello",
              "name" => "Acme",
              "active" => true
            },
            "es-ES" => %{"_title" => "Hola"}
          },
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, record: record, actor_uuid: actor_uuid}
  end

  describe "mount edit form" do
    test "renders title + page heading", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, edit_url(ctx.entity, ctx.record))

      assert html =~ "<title>Edit DF Test</title>"
      assert html =~ ~s|value="Hello"|
    end

    test "form has phx-disable-with on submit (delta-pin C5)", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, edit_url(ctx.entity, ctx.record))

      assert html =~ ~r|type="submit"[^>]*phx-disable-with=|
    end
  end

  describe "attachments scope folder" do
    @scope_folder "22222222-2222-2222-2222-222222222222"

    # Reports every call to the test process: host hooks find-or-create
    # folders, so WHEN the form calls this is the contract under test.
    defmodule ScopeHook do
      def parent_for(:entity_file, actor_uuid, %{entity_name: name}) do
        send(
          Application.fetch_env!(:phoenix_kit_entities, :scope_hook_pid),
          {:scope_hook, actor_uuid, name}
        )

        {:ok, "22222222-2222-2222-2222-222222222222"}
      end
    end

    setup do
      Application.put_env(
        :phoenix_kit_entities,
        :attachments_parent_folder,
        {ScopeHook, :parent_for}
      )

      Application.put_env(:phoenix_kit_entities, :scope_hook_pid, self())

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_entities, :attachments_parent_folder)
        Application.delete_env(:phoenix_kit_entities, :scope_hook_pid)
      end)

      {:ok, media_entity} =
        Entities.create_entity(
          %{
            name: "df_media",
            display_name: "DF Media",
            display_name_plural: "DF Media",
            fields_definition: [
              %{"type" => "text", "key" => "name", "label" => "Name"},
              %{"type" => "image", "key" => "photo", "label" => "Photo"}
            ],
            status: "published",
            created_by_uuid: Ecto.UUID.generate()
          },
          actor_uuid: Ecto.UUID.generate()
        )

      {:ok, media_entity: media_entity}
    end

    test "rendering the form never calls the hook", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))

      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))
      {:ok, media_view, _html} = live(conn, new_url(ctx.media_entity))

      # Both the dead render (this process) and the connected one would send.
      render(view)
      render(media_view)
      refute_received {:scope_hook, _, _}
      assert scope_folder_assign(media_view) == nil
    end

    test "opening the picker scopes it to the hook's folder for this entity and actor",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, new_url(ctx.media_entity))

      render_click(view, "pick_media_field", %{"key" => "photo", "type" => "image"})

      actor_uuid = ctx.actor_uuid
      assert_receive {:scope_hook, ^actor_uuid, "df_media"}
      assert scope_folder_assign(view) == @scope_folder
    end

    test "an illegal pick does not call the hook", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, new_url(ctx.media_entity))

      render_click(view, "pick_media_field", %{"key" => "name", "type" => "image"})

      refute_received {:scope_hook, _, _}
      assert scope_folder_assign(view) == nil
    end
  end

  describe "the URL's blueprint has to be the record's blueprint" do
    test "editing a record under another entity's URL redirects to its own",
         %{conn: conn} = ctx do
      # The entity comes from the URL, the record comes from its uuid, and
      # nothing checked that they belong together. Harmless while the form
      # posted the record's own `entity_uuid` back — but the save path now
      # sets `entity_uuid` from the URL entity on purpose (so a crafted
      # payload cannot re-parent a row), which turns a mismatched URL into a
      # plain Save that MOVES the record.
      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "df_elsewhere",
            display_name: "DF Elsewhere",
            display_name_plural: "DF Elsewheres",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, edit_url(other_entity, ctx.record))

      assert to =~ "/admin/entities/#{ctx.entity.name}/data/#{ctx.record.uuid}/edit"

      # And the record did not move on the way.
      assert EntityData.get(ctx.record.uuid).entity_uuid == ctx.entity.uuid
    end
  end

  describe "a crafted save payload cannot write fields the form never renders" do
    test "created_by_uuid, date_created, metadata and position are ignored",
         %{conn: conn} = ctx do
      # EntityData.changeset/2 casts rather more than this form renders, and
      # `data_params` is whatever the client submitted. Without an allowlist a
      # crafted `save` could forge authorship, back-date the audit timestamp,
      # rewrite the ip_address / user_agent / security_warnings metadata a
      # flagged public submission was stored with, or move the row to another
      # blueprint. Admin access is required to get here — but these are the
      # columns that exist to survive an admin.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      before = EntityData.get(ctx.record.uuid)
      impostor = Ecto.UUID.generate()

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{
          "title" => "Renamed",
          "created_by_uuid" => impostor,
          "date_created" => "2020-01-01T00:00:00Z",
          "metadata" => %{"ip_address" => "wiped"},
          "position" => 999
        }
      })

      after_save = EntityData.get(ctx.record.uuid)

      # The field the form does render still takes effect…
      assert after_save.title == "Renamed"

      # …and none of the forged ones did.
      refute after_save.created_by_uuid == impostor
      assert after_save.created_by_uuid == before.created_by_uuid
      assert after_save.date_created == before.date_created
      assert after_save.metadata == before.metadata
      assert after_save.position == before.position
    end

    test "entity_uuid cannot move the record to another blueprint",
         %{conn: conn} = ctx do
      # The one field the first version of that allowlist let through, and
      # the one with the widest blast radius: the blueprint decides the
      # record's URL, its sitemap entry and which navigator it appears in.
      # `changeset/2` casts `:entity_uuid` and `validate_entity_reference/1`
      # only checks that the target EXISTS, so a valid other uuid is
      # accepted. The form renders it as a hidden input — which binds the
      # browser, not the socket.
      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "df_other",
            display_name: "DF Other",
            display_name_plural: "DF Others",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{
          "title" => "Still here",
          "entity_uuid" => other_entity.uuid,
          # `validate_parent_same_entity/1` compares against the SUBMITTED
          # entity, so clearing the parent is what makes the forged move
          # pass validation.
          "parent_uuid" => nil
        }
      })

      after_save = EntityData.get(ctx.record.uuid)

      assert after_save.title == "Still here"
      assert after_save.entity_uuid == ctx.entity.uuid
      refute after_save.entity_uuid == other_entity.uuid
    end

    test "status cannot be set to the internal trashed state", %{conn: conn} = ctx do
      # The select offers draft / published / archived. `"trashed"` is a
      # valid status it never shows, and writing it directly skips
      # `EntityData.trash/2` — where `metadata["trashed_from_status"]` is
      # stashed. The row would soft-delete without recording what it had
      # been, log `entity_data.updated` rather than `entity_data.trashed`,
      # and restore later to "draft" whatever its real status was.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Kept", "status" => "trashed"}
      })

      after_save = EntityData.get(ctx.record.uuid)

      assert after_save.title == "Kept"
      assert after_save.status == "published"
    end
  end

  describe "the edit form loads the record raw (no :lang)" do
    # `EntityData.get!/2` with `:lang` runs `resolve_language/2`, which
    # replaces the multilang `data` JSONB with the single merged map for
    # that locale — `_primary_language` and every other language are gone
    # from the struct. `handle_params/3` used to load the record that way,
    # using the admin's UI locale, which meant:
    #
    #   * every language tab rendered the SAME text (whatever the admin's
    #     own UI locale resolved to), so translations looked missing even
    #     though the row held them, and
    #   * the save path builds its `data` from this changeset, so the next
    #     save wrote the collapsed map back and permanently deleted every
    #     other translation in the row.
    #
    # These pin the record load. The LiveCase hook assigns a non-nil
    # `:current_locale`, so a reintroduced `lang:` opt fails them.

    test "changeset keeps every language, not just the admin's locale",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      data = changeset_data(view)

      assert data["_primary_language"] == "en-US"
      assert data["en-US"]["_title"] == "Hello"
      assert data["es-ES"]["_title"] == "Hola"
    end

    test "a secondary admin UI locale does not overwrite the primary language",
         %{conn: conn} = ctx do
      conn =
        conn
        |> put_test_scope(fake_scope(user_uuid: ctx.actor_uuid))
        |> Plug.Test.init_test_session(%{
          "phoenix_kit_test_locale" => "es-ES",
          "phoenix_kit_test_locale_base" => "es"
        })

      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      data = changeset_data(view)

      # Resolving to es-ES would have put "Hola" under the primary key.
      assert data["en-US"]["_title"] == "Hello"
      assert data["es-ES"]["_title"] == "Hola"
    end

    test "saving from the form leaves the other languages in the row",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      view
      |> form("form", phoenix_kit_entity_data: %{title: "Hello again"})
      |> render_submit()

      reloaded = EntityData.get(ctx.record.uuid)

      assert reloaded.title == "Hello again"
      assert reloaded.data["_primary_language"] == "en-US"
      assert reloaded.data["es-ES"]["_title"] == "Hola"
    end

    test "a remote :data_updated refresh also keeps every language",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      # The handler bails out early for the lock owner, which this LV is
      # while it holds the edit lock. Drop the flag so the reload runs.
      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns[:lock_owner?], false)
      end)

      send(view.pid, {:data_updated, ctx.entity.uuid, ctx.record.uuid})
      render(view)

      assert changeset_data(view)["es-ES"]["_title"] == "Hola"
    end
  end

  describe "single-language layout over a multilang row" do
    # The counterpart to the raw load above. With the Languages module off
    # (as it is here) the form renders the single-language layout, which
    # asks FormBuilder for `lang_code: nil` — a raw `data` read, one level
    # above where a multilang row keeps its values. Without a flattened
    # view the custom fields render blank and the next save writes those
    # blanks over the primary language, losing exactly what loading raw
    # was meant to protect.

    test "custom fields render the primary language's values", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, edit_url(ctx.entity, ctx.record))

      assert html =~ ~s|name="phoenix_kit_entity_data[data][name]"|
      assert html =~ ~s|value="Acme"|
    end

    test "saving keeps the primary language's field values", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      view
      |> form("form", phoenix_kit_entity_data: %{title: "Hello again"})
      |> render_submit()

      reloaded = EntityData.get(ctx.record.uuid)

      assert reloaded.data["en-US"]["name"] == "Acme"
      assert reloaded.data["en-US"]["active"] == true
      assert reloaded.data["es-ES"]["_title"] == "Hola"
    end
  end

  # KNOWN GAP (2026-09-11 review): every test in this file runs with the
  # Languages module off, so `@show_multilang_tabs` is always false and
  # the "multilang: unified card with language tabs" template branch in
  # data_form.ex (the `<%= if @show_multilang_tabs do %>` arm) never
  # renders here — only its "non-multilang: separate cards" sibling does.
  # Turning Languages on for one test isn't a safe way to close this:
  # `PhoenixKit.Modules.Languages.enable_system/0` writes through
  # `PhoenixKit.Cache`, an ETS table outside the SQL sandbox transaction
  # this test's `on_exit` rollback doesn't touch — the "enabled" config
  # would leak into every test that runs after it in the suite. Closing
  # this needs either a cache-reset hook run around such a test or a
  # render/1-level unit test that hand-builds `assigns` (fragile against
  # unrelated assign changes elsewhere in the LiveView). Until then, the
  # two branches are kept structurally identical by hand (see
  # `managed_blueprint?/2` and its 8 call sites, and the hidden slug
  # mirror's `|| ""`, in data_form.ex) so a fix applied to one is applied
  # to both.

  describe "switch_language event" do
    test "ignores unknown language without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_hook(view, "switch_language", %{"lang" => "totally-fake"})
      assert page_title(view) =~ "Edit DF Test"
    end

    test "accepts a known language and remains on the form", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      # Without multilang enabled the LV no-ops; the assertion is "no crash".
      render_hook(view, "switch_language", %{"lang" => "en-US"})
      assert page_title(view) =~ "Edit DF Test"
    end
  end

  describe ":data_form_change broadcast (collab editing)" do
    # This test would have caught the `:created_by` cast crash. The
    # handler runs `Ecto.Changeset.cast(params, [..., :created_by_uuid])`;
    # if any atom in that list isn't a schema field, Ecto raises
    # ArgumentError and the LV crashes the moment another tab broadcasts.
    test "applies remote params without crashing the LV", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      payload = %{
        params: %{
          "entity_uuid" => ctx.entity.uuid,
          "title" => "Hello (remote edit)",
          "slug" => "hello",
          "status" => "published",
          "data" => %{
            "_primary_language" => "en-US",
            "en-US" => %{"_title" => "Hello (remote edit)", "name" => "Acme remote"}
          }
        }
      }

      # Source string differs from this LV's `live_source` so the handler
      # treats it as an external broadcast and applies the params.
      send(view.pid, {:data_form_change, ctx.entity.uuid, ctx.record.uuid, payload, "phx-other"})

      # If the cast crashed, render/1 would raise. Title (top-level DB
      # column) is rendered in the basic-info section regardless of
      # multilang state, so we use it as the proof-of-life assertion.
      html = render(view)
      assert html =~ "Hello (remote edit)"
    end

    test "ignores broadcasts for a different record", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      other_uuid = Ecto.UUID.generate()

      send(
        view.pid,
        {:data_form_change, ctx.entity.uuid, other_uuid, %{params: %{"title" => "Other"}},
         "phx-other"}
      )

      # Original title still rendered.
      html = render(view)
      assert html =~ "Hello"
      refute html =~ "Other"
    end

    test "ignores broadcasts for a different entity", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      send(
        view.pid,
        {:data_form_change, Ecto.UUID.generate(), ctx.record.uuid,
         %{params: %{"title" => "Wrong entity"}}, "phx-other"}
      )

      refute render(view) =~ "Wrong entity"
    end

    test "ignores broadcasts from this LV's own source (echo prevention)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      # Read the live_source assign by inspecting the running socket via
      # Phoenix.LiveViewTest.run/3 — we need the actual value to forge an
      # echo. Use it as the broadcast source.
      live_source = :sys.get_state(view.pid).socket.assigns.live_source

      send(
        view.pid,
        {:data_form_change, ctx.entity.uuid, ctx.record.uuid,
         %{params: %{"title" => "Echo from self"}}, live_source}
      )

      refute render(view) =~ "Echo from self"
    end
  end

  describe ":data_updated / :data_deleted broadcasts" do
    test "data_updated for a different record is ignored", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      send(view.pid, {:data_updated, ctx.entity.uuid, Ecto.UUID.generate()})
      assert render(view) =~ "Hello"
    end

    test "data_deleted for this record redirects to the data list", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      send(view.pid, {:data_deleted, ctx.entity.uuid, ctx.record.uuid})

      # The handler issues a live_redirect with a flash; the redirect
      # surfaces as a {:live_redirect, _} exit signal when render/1 runs.
      {path, _flash} = assert_redirect(view)
      assert path =~ "/admin/entities/#{ctx.entity.name}/data"
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      send(view.pid, {:totally_unrelated, "junk", :payload})
      assert page_title(view) =~ "Edit DF Test"
    end

    test "logs at :debug level so unexpected messages stay visible in dev",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:unhandled_in_test, :payload})
          render(view)
        end)

      assert log =~ "DataForm: unhandled handle_info"
    end
  end

  describe "validate event" do
    test "renders changeset with :action set after validate", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      _html =
        view
        |> form("form", phoenix_kit_entity_data: %{title: "Updated"})
        |> render_change()

      assert page_title(view) =~ "Edit DF Test"
    end
  end

  describe "save event" do
    test "submits form params + persists changes", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      view
      |> form("form", phoenix_kit_entity_data: %{title: "Saved"})
      |> render_submit()

      # Process didn't crash; record exists.
      reread = EntityData.get(ctx.record.uuid)
      assert reread != nil
    end
  end

  describe "reset event" do
    test "doesn't crash and re-renders the form", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_hook(view, "reset", %{})
      assert page_title(view) =~ "Edit DF Test"
    end
  end

  describe "allow_other custom option (Muu)" do
    setup ctx do
      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "df_other_test",
            display_name: "DF Other Test",
            display_name_plural: "DF Other Tests",
            fields_definition: [
              %{
                "type" => "select",
                "key" => "color",
                "label" => "Color",
                "options" => ["Red", "Blue"],
                "allow_other" => true
              }
            ],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, other_record} =
        EntityData.create(
          %{
            entity_uuid: other_entity.uuid,
            title: "Other Fixture",
            slug: "other-fixture",
            status: "published",
            data: %{"color" => "Red"},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, other_entity: other_entity, other_record: other_record}
    end

    # Fires "save" directly (rather than through the LiveViewTest form
    # helper) to exercise exactly what the browser sends: the sentinel
    # value from the "Other" radio/option plus its companion free-text
    # field — see do_save/2's merge_other_params call.
    test "sentinel + companion text is persisted as the free-text value",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.other_entity, ctx.other_record))

      render_hook(view, "save", %{
        "phoenix_kit_entity_data" => %{
          "data" => %{"color" => "__other__", "color__other" => "Crimson"}
        }
      })

      reread = EntityData.get(ctx.other_record.uuid)
      assert reread.data["color"] == "Crimson"
    end

    test "a known option round-trips unchanged", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.other_entity, ctx.other_record))

      render_hook(view, "save", %{
        "phoenix_kit_entity_data" => %{"data" => %{"color" => "Blue"}}
      })

      reread = EntityData.get(ctx.other_record.uuid)
      assert reread.data["color"] == "Blue"
    end
  end

  describe "generate_slug event" do
    test "doesn't crash and re-renders the form", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_hook(view, "generate_slug", %{})
      assert page_title(view) =~ "Edit DF Test"
    end
  end

  describe "managed blueprint value records" do
    setup ctx do
      {:ok, managed_entity} =
        Entities.create_entity(
          %{
            name: "catalogue_set_df_managed",
            display_name: "Catalogue Set DF Managed",
            display_name_plural: "Catalogue Sets",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid,
            settings: %{"managed_by" => "catalogue", "locked_keys" => []}
          },
          on_behalf_of: "catalogue"
        )

      {:ok, managed_record} =
        EntityData.create(
          %{
            entity_uuid: managed_entity.uuid,
            title: "Oak",
            slug: "oak",
            status: "published",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, managed_entity: managed_entity, managed_record: managed_record}
    end

    test "the slug field is disabled with a locked hint, and Generate is hidden",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, edit_url(ctx.managed_entity, ctx.managed_record))

      assert html =~ "Locked — the owning module keys on this slug"
      refute html =~ ~s(phx-click="generate_slug")

      slug_input =
        Regex.run(~r/<input[^>]*id="phoenix_kit_entity_data_slug"[^>]*>/, html) |> List.first()

      assert is_binary(slug_input)
      assert slug_input =~ "disabled"
    end

    test "a disabled field still submits its value via a hidden mirror",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, edit_url(ctx.managed_entity, ctx.managed_record))

      assert html =~
               ~r/<input\s+type="hidden"\s+name="phoenix_kit_entity_data\[slug\]"\s+value="oak"/
    end

    test "resubmitting the unchanged slug still saves other fields",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.managed_entity, ctx.managed_record))

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak (renamed title)", "slug" => "oak"}
      })

      after_save = EntityData.get(ctx.managed_record.uuid)
      assert after_save.title == "Oak (renamed title)"
      assert after_save.slug == "oak"
    end

    # A multilang row whose primary language carries no `_slug` of its own
    # (the shape `EntityData.create/2` stores when an owner creates a value
    # with only the `slug` column set). Mount seeds `data[primary]["_slug"]`
    # from the column, so every save posts it back — that is the column's
    # own value, not a rename, and must not lock the form.
    test "a multilang row without a stored primary _slug still saves",
         %{conn: conn} = ctx do
      {:ok, multilang_record} =
        EntityData.create(
          %{
            entity_uuid: ctx.managed_entity.uuid,
            title: "Birch",
            slug: "birch",
            status: "published",
            data: %{"_primary_language" => "en-US", "en-US" => %{"_title" => "Birch"}},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.managed_entity, multilang_record))

      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{"title" => "Birch (renamed title)"}
      })
      |> render_submit()

      refute render(view) =~ "locked by its owning module"

      after_save = EntityData.get(multilang_record.uuid)
      assert after_save.title == "Birch (renamed title)"
      assert after_save.slug == "birch"
    end

    test "a crafted slug change is refused at the write path, with a flash",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.managed_entity, ctx.managed_record))

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak", "slug" => "forged-slug"}
      })

      assert render(view) =~ "locked by its owning module"

      after_save = EntityData.get(ctx.managed_record.uuid)
      assert after_save.slug == "oak"
      assert after_save.title == "Oak"
    end

    # MINOR-2 (2026-09-11 review): the `:locked_key` branch used to leave
    # the rejected slug sitting in the changeset. The hidden mirror would
    # then resubmit "forged-slug" on every subsequent save — wedging the
    # form exactly like the `generate_slug` bug below (MINOR-1) — and the
    # flash's own advice ("revert that change to save") was unactionable
    # since the field is disabled. Before this fix, the second
    # `render_submit` below would still be refused with the same flash.
    test "after a refused slug change, the form recovers without a reload",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.managed_entity, ctx.managed_record))

      # A forged "validate" (phx-change) event dirties the changeset with
      # a slug the disabled field could never produce — `do_validate/2`
      # builds the changeset straight from `data_params` with no
      # `client_writable_params/2` filtering (that only runs on save), so
      # nothing stops this at the changeset-build step; the write-path
      # guard is what has to catch it, on the "save" that follows.
      render_change(view, "validate", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak", "slug" => "forged-slug"}
      })

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak", "slug" => "forged-slug"}
      })

      html = render(view)

      assert html =~
               ~r/<input\s+type="hidden"\s+name="phoenix_kit_entity_data\[slug\]"\s+value="oak"/

      refute html =~ "forged-slug"

      # `form/3` + `render_submit/1` (rather than `render_submit(view,
      # "save", params)`) walks the ACTUAL rendered markup: the disabled
      # slug input is excluded and the hidden mirror's CURRENT value is
      # what gets submitted, same as a real browser — not a slug typed by
      # hand in the test. That is the scenario this test guards: before
      # the fix, the mirror was still stuck on "forged-slug" here and
      # this save would fail with the very same flash.
      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak (retry)"}
      })
      |> render_submit()

      after_save = EntityData.get(ctx.managed_record.uuid)
      assert after_save.title == "Oak (retry)"
      assert after_save.slug == "oak"
    end

    # MINOR-1 (2026-09-11 review): the Generate button is hidden via `:if`
    # on a managed record, but `handle_event("generate_slug", ...)` was
    # unconditional — a LiveView event is not bound by the markup that
    # produced it. Before this fix, the `render_hook` below rewrote the
    # hidden slug mirror to "oak-wood" even though Generate is gone from
    # the page, and every ordinary save afterward was refused with
    # `:locked_key` (data safe, but the form was stuck — only a reload
    # cleared it).
    test "a forged generate_slug event cannot wedge a managed record's form",
         %{conn: conn} = ctx do
      {:ok, record} =
        EntityData.create(
          %{
            entity_uuid: ctx.managed_entity.uuid,
            title: "Oak Wood",
            slug: "oak",
            status: "published",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.managed_entity, record))

      render_hook(view, "generate_slug", %{})

      html = render(view)

      assert html =~
               ~r/<input\s+type="hidden"\s+name="phoenix_kit_entity_data\[slug\]"\s+value="oak"/

      refute html =~ "oak-wood"

      # `form/3` + `render_submit/1` submits the mirror's ACTUAL current
      # value rather than one typed by hand — see the comment on the
      # MINOR-2 test above.
      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{"title" => "Oak Wood (edited)"}
      })
      |> render_submit()

      after_save = EntityData.get(record.uuid)
      assert after_save.title == "Oak Wood (edited)"
      assert after_save.slug == "oak"
    end

    test "the owner can still change the slug via on_behalf_of", %{conn: _conn} = ctx do
      assert {:ok, updated} =
               EntityData.update(ctx.managed_record, %{"slug" => "renamed-by-owner"},
                 on_behalf_of: "catalogue"
               )

      assert updated.slug == "renamed-by-owner"
    end

    test "unmanaged records are unaffected — slug changes freely", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Hello", "slug" => "hello-renamed"}
      })

      after_save = EntityData.get(ctx.record.uuid)
      assert after_save.slug == "hello-renamed"
    end

    # CRITICAL (2026-09-11 review): `managed_blueprint?/1` used to lock the
    # slug field on `/data/new` too, disabling it and hiding Generate —
    # the same treatment as an EXISTING record. But on creation there is
    # no prior slug to protect, and the disabled field's hidden mirror
    # always posts `""` (nothing has been typed yet): the record was
    # created with `slug: nil`, permanently, since `changeset/2` never
    # derives a slug from the title. `managed_blueprint?/2` now also
    # checks `@data_record.uuid` — locking only an EXISTING record.
    test "the slug field and Generate are available when CREATING a managed value record",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, new_url(ctx.managed_entity))

      refute html =~ "Locked — the owning module keys on this slug"
      assert html =~ ~s(phx-click="generate_slug")

      slug_input =
        Regex.run(~r/<input[^>]*id="phoenix_kit_entity_data_slug"[^>]*>/, html) |> List.first()

      assert is_binary(slug_input)
      refute slug_input =~ "disabled"
    end

    test "creating a managed value record with a slug persists it (not nil)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, new_url(ctx.managed_entity))

      # `form/3` + `render_submit/1` (rather than `render_submit(view, "save",
      # params)`) actually walk the rendered markup: a `disabled` slug input is
      # excluded from what gets submitted, same as a real browser. That is the
      # scenario this test guards — `managed_blueprint?/2` wrongly locking the
      # slug field on CREATE — so it must go through the disabled check to be
      # able to fail when that regresses.
      view
      |> form("#entity-data-form", %{
        "phoenix_kit_entity_data" => %{"title" => "Maple", "slug" => "maple"}
      })
      |> render_submit()

      created = EntityData.get_by_slug(ctx.managed_entity.uuid, "maple")
      assert created
      assert created.title == "Maple"
    end

    # CRITICAL (2026-09-11 review): `renames_data_slug?/2` treated an
    # empty new slug as a rename whenever the record's slug wasn't
    # already `""` (it compared `is_binary("") and "" != nil`, which is
    # `true`) — so a record that legitimately has `slug: nil` (created
    # without one; possible even after the CREATE-path fix above, since
    # a blank slug has always been valid) could never be saved again:
    # the disabled field's hidden mirror resubmits `""`, and every save
    # — even a title-only edit — was refused as a locked-key rename.
    test "a managed value record created without a slug can still be saved again",
         %{conn: conn} = ctx do
      {:ok, no_slug_record} =
        EntityData.create(
          %{
            entity_uuid: ctx.managed_entity.uuid,
            title: "Birch",
            slug: nil,
            status: "published",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, edit_url(ctx.managed_entity, no_slug_record))

      # The hidden mirror posts back `""`, matching the DB's `nil` — not a
      # rename.
      assert html =~
               ~r/<input\s+type="hidden"\s+name="phoenix_kit_entity_data\[slug\]"\s+value=""/

      render_submit(view, "save", %{
        "phoenix_kit_entity_data" => %{"title" => "Birch (renamed)", "slug" => ""}
      })

      refute render(view) =~ "locked by its owning module"

      after_save = EntityData.get(no_slug_record.uuid)
      assert after_save.title == "Birch (renamed)"
      assert is_nil(after_save.slug)
    end
  end

  describe "live slug derivation (2026-08-28: no typing pause)" do
    test "the title field is wired for live derivation", %{conn: conn} = ctx do
      # Asserted unconditionally. This used to be wrapped in `if html =~
      # phx-debounce="0"`, on the reasoning that the attrs ride through
      # core's `translatable_field`, which only just gained a `:global`
      # passthrough — so under the released pin the whole block was skipped
      # and the else branch asserted the 300ms fallback instead. That hid
      # the actual gap: the SINGLE-LANGUAGE branch of this form (the
      # default) renders raw inputs and never carried the attrs at all, on
      # any core. Raw inputs need no passthrough, so these hold everywhere.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")

      # "0", not absent: phx-debounce CASCADES and this form carries 500, so
      # an omitted attribute inherits it — the opposite of live.
      assert has_element?(
               view,
               ~s|input[name="phoenix_kit_entity_data[title]"][phx-debounce="0"]|
             )

      # The browser fills the slug with no round trip; the hook needs all
      # three of these or it silently does nothing.
      assert html =~ ~s(phx-hook="SlugFromTitle")
      assert html =~ ~s(data-slug-target="#phoenix_kit_entity_data_slug")
      assert html =~ ~s(data-slug-auto="true")

      # And the server still derives the slug it will actually store.
      html =
        render_change(view, "validate", %{"phoenix_kit_entity_data" => %{"title" => "Walnut Oak"}})

      assert html =~ ~s(value="walnut-oak")
    end

    test "the mirror goes quiet once the user takes the slug over",
         %{conn: conn} = ctx do
      # Separated from the test above on purpose: taking ownership is a
      # one-way door for the rest of the session, so asserting it in the
      # same test as "the server derives the slug" makes the second
      # assertion depend on the first not having run.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")

      assert html =~ ~s(data-slug-auto="true")

      html =
        render_change(view, "validate", %{
          "_target" => ["phoenix_kit_entity_data", "slug"],
          "phoenix_kit_entity_data" => %{"title" => "Walnut", "slug" => "mine"}
        })

      assert html =~ ~s(data-slug-auto="false")

      # …and it stays quiet: a later title change must not overwrite the
      # slug the user chose.
      html =
        render_change(view, "validate", %{
          "phoenix_kit_entity_data" => %{"title" => "Something Else", "slug" => "mine"}
        })

      assert html =~ ~s(value="mine")
      refute html =~ ~s(value="something-else")
    end

    test "a STALE slug echo doesn't stop it (the bug live typing exposed)",
         %{conn: conn} = ctx do
      # With no debounce the client posts the slug it last rendered, which
      # lags the server by a keystroke or two. Deciding "is this still
      # auto-generated?" from that stale echo froze the slug after the
      # first character on a real (remote) connection, while every
      # tidy-params test passed.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")

      render_change(view, "validate", %{
        "phoenix_kit_entity_data" => %{"title" => "W", "slug" => ""}
      })

      # Every subsequent post carries a slug from BEFORE the server's last
      # derivation — "w" while the title has already reached "Walnut".
      html =
        render_change(view, "validate", %{
          "phoenix_kit_entity_data" => %{"title" => "Walnut", "slug" => "w"}
        })

      assert html =~ ~s(value="walnut")

      html =
        render_change(view, "validate", %{
          "phoenix_kit_entity_data" => %{"title" => "Walnut Oak", "slug" => "w"}
        })

      assert html =~ ~s(value="walnut-oak")
    end

    test "a hand-typed slug stops following the title", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")

      render_change(view, "validate", %{"phoenix_kit_entity_data" => %{"title" => "Walnut"}})

      # Typing IN the slug field is what hands ownership over.
      html =
        render_change(view, "validate", %{
          "_target" => ["phoenix_kit_entity_data", "slug"],
          "phoenix_kit_entity_data" => %{"title" => "Walnut", "slug" => "my-own-slug"}
        })

      assert html =~ ~s(value="my-own-slug")

      # …and keeps its own value while the title keeps changing.
      html =
        render_change(view, "validate", %{
          "phoenix_kit_entity_data" => %{"title" => "Walnut Door", "slug" => "my-own-slug"}
        })

      assert html =~ ~s(value="my-own-slug")
      refute html =~ ~s(value="walnut-door")
    end

    test "clearing the slug hands it back to the title", %{conn: conn} = ctx do
      # The field's own hint says "Leave empty to auto-generate from
      # title", so emptying it has to mean exactly that.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")

      render_change(view, "validate", %{
        "_target" => ["phoenix_kit_entity_data", "slug"],
        "phoenix_kit_entity_data" => %{"title" => "Walnut", "slug" => "mine"}
      })

      render_change(view, "validate", %{
        "_target" => ["phoenix_kit_entity_data", "slug"],
        "phoenix_kit_entity_data" => %{"title" => "Walnut", "slug" => ""}
      })

      html =
        render_change(view, "validate", %{
          "phoenix_kit_entity_data" => %{"title" => "Walnut Door", "slug" => ""}
        })

      assert html =~ ~s(value="walnut-door")
    end
  end

  describe "new form" do
    test "mounts the new path successfully", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/entities/#{ctx.entity.name}/data/new")
      assert html =~ "DF Test" or html =~ "data"
    end
  end

  describe "parent picker" do
    setup ctx do
      # Build a 3-deep chain in ctx.entity: A → B → C
      {:ok, a} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "A",
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, b} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "B",
            status: "published",
            parent_uuid: a.uuid,
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, c} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "C",
            status: "published",
            parent_uuid: b.uuid,
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "df_other",
            display_name: "Other",
            display_name_plural: "Others",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, other_record} =
        EntityData.create(
          %{
            entity_uuid: other_entity.uuid,
            title: "From other entity",
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, a: a, b: b, c: c, other_entity: other_entity, other_record: other_record}
    end

    test "happy path — saving with a valid same-entity parent persists parent_uuid",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      view
      |> form("form", phoenix_kit_entity_data: %{parent_uuid: ctx.a.uuid})
      |> render_submit()

      assert EntityData.get(ctx.record.uuid).parent_uuid == ctx.a.uuid
    end

    # For the three rejection tests below, `Phoenix.LiveViewTest.form/3`
    # validates submitted select values against the picker's rendered
    # options — which is exactly what the LV does for happy users.
    # These tests simulate a bypass attempt (custom client / crafted
    # payload) by firing the "save" event directly so the changeset
    # layer's validations are what's exercised, not the form helper.
    test "rejects self-parent — record cannot be its own parent",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_hook(view, "save", %{
        "phoenix_kit_entity_data" => %{"parent_uuid" => ctx.record.uuid}
      })

      assert is_nil(EntityData.get(ctx.record.uuid).parent_uuid)
    end

    test "rejects a parent from a different entity",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      render_hook(view, "save", %{
        "phoenix_kit_entity_data" => %{"parent_uuid" => ctx.other_record.uuid}
      })

      assert is_nil(EntityData.get(ctx.record.uuid).parent_uuid)
    end

    test "rejects a parent that is the record's descendant (cycle)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.a))

      # A → C would form A→C→B→A.
      render_hook(view, "save", %{
        "phoenix_kit_entity_data" => %{"parent_uuid" => ctx.c.uuid}
      })

      assert is_nil(EntityData.get(ctx.a.uuid).parent_uuid)
    end

    test "clearing parent_uuid (selecting None) persists nil",
         %{conn: conn} = ctx do
      {:ok, _} = EntityData.update(ctx.record, %{parent_uuid: ctx.a.uuid})
      assert EntityData.get(ctx.record.uuid).parent_uuid == ctx.a.uuid

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, edit_url(ctx.entity, ctx.record))

      view
      |> form("form", phoenix_kit_entity_data: %{parent_uuid: ""})
      |> render_submit()

      assert is_nil(EntityData.get(ctx.record.uuid).parent_uuid)
    end
  end

  # ── helpers ──────────────────────────────────────────────────

  defp edit_url(entity, record),
    do: "/en/admin/entities/#{entity.name}/data/#{record.uuid}/edit"

  defp new_url(entity), do: "/en/admin/entities/#{entity.name}/data/new"

  # The form's `data` JSONB as the LV currently holds it. Read off the
  # socket rather than the rendered HTML: without the Languages module
  # enabled the LV renders the single-language layout, so the secondary
  # translations never reach the markup even when they're all present.
  defp scope_folder_assign(view), do: :sys.get_state(view.pid).socket.assigns.scope_folder_uuid

  defp changeset_data(view),
    do: :sys.get_state(view.pid).socket.assigns.changeset |> Ecto.Changeset.get_field(:data)
end
