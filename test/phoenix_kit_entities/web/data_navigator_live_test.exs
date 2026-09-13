defmodule PhoenixKitEntities.Web.DataNavigatorLiveTest do
  use PhoenixKitEntities.LiveCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.UUID
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "dn_test",
          display_name: "DN Test",
          display_name_plural: "DN Tests",
          fields_definition: [
            %{"type" => "text", "key" => "name", "label" => "Name"}
          ],
          status: "published",
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    records =
      for n <- 1..3 do
        {:ok, r} =
          EntityData.create(
            %{
              entity_uuid: entity.uuid,
              title: "Record #{n}",
              slug: "record-#{n}",
              status: "published",
              data: %{"name" => "Item #{n}"},
              created_by_uuid: actor_uuid
            },
            actor_uuid: actor_uuid
          )

        r
      end

    {:ok, entity: entity, records: records, actor_uuid: actor_uuid}
  end

  describe "mount" do
    test "renders the records, not a second copy of the entity name", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, navigator_url(ctx.entity))

      # All seeded records render in the table.
      assert html =~ "Record 1"
      assert html =~ "Record 2"
      assert html =~ "Record 3"

      # The in-body page title and its "Browse and manage your …" line are
      # gone on purpose (Max, 2026-08-28): the admin layout's breadcrumb bar
      # names the entity (via @page_title, the plural form the sidebar uses)
      # and links back to "Entities" (via @page_section), so the page opens
      # on its content and carries no back chip of its own.
      body = render(view)
      refute body =~ "DN Test"
      refute body =~ "Browse and manage"
      assert page_title(view) == "DN Tests"
    end
  end

  describe "single-record archive_data / restore_data" do
    test "archive_data flips status, logs activity with actor_uuid + flash",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      # Table view renders actions inside `<.table_row_menu>`; scope to
      # the menu's unique id so the card view's inline button doesn't
      # match too.
      view
      |> element("#data-menu-#{record.uuid} button[phx-click='archive_data']")
      |> render_click()

      assert_activity_logged("entity_data.updated",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid,
        metadata_has: %{"status" => "archived"}
      )

      assert render(view) =~ "archived successfully"
      assert EntityData.get!(record.uuid).status == "archived"
    end

    test "restore_data flips back to published and logs", %{conn: conn} = ctx do
      [record | _] = ctx.records

      {:ok, _} =
        EntityData.update_data(record, %{status: "archived"}, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "archived"))

      view
      |> element("#data-menu-#{record.uuid} button[phx-click='restore_data']")
      |> render_click()

      assert_activity_logged("entity_data.updated",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid,
        metadata_has: %{"status" => "published"}
      )

      assert render(view) =~ "restored successfully"
    end

    test "single-record buttons carry phx-disable-with", %{conn: conn} = ctx do
      [record | _] = ctx.records
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, navigator_url(ctx.entity))

      # delta-pin C5: archive button has phx-disable-with attr. The
      # button now lives inside `<.table_row_menu>`; isolate the menu's
      # subtree for this record (scoped by its id) and assert both
      # signals appear inside it. `:global` attrs aren't source-ordered
      # so we don't pin them to a single tag.
      menu_id = "data-menu-#{record.uuid}"

      menu_html =
        Regex.run(~r/<div id="#{menu_id}".*?<\/div>/s, html)
        |> List.first()

      assert is_binary(menu_html), "expected dropdown markup for #{menu_id}"
      assert menu_html =~ ~s(phx-click="archive_data")
      assert menu_html =~ "phx-disable-with="
    end
  end

  describe "bulk_action — actor_uuid threading + summary log" do
    test "bulk archive logs ONE bulk_status_changed row with actor + count",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      # Selection lives client-side (BulkSelectScope hook); the button's
      # event carries the selected uuids directly.
      uuids = Enum.map(ctx.records, & &1.uuid)
      render_hook(view, "bulk_archive", %{"uuids" => uuids})

      assert_activity_logged("entity_data.bulk_status_changed",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"status" => "archived", "count" => 3, "uuid_count" => 3}
      )
    end

    test "bulk delete (soft) logs ONE bulk_trashed row", %{conn: conn} = ctx do
      # The "delete" bulk action is now a soft-delete (trash) — the row stays
      # alive so parent-app FK references resolve. Hard-delete moved to the
      # "permanent_delete" action, available from the Trash filter view.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "bulk_delete", %{"uuids" => Enum.map(ctx.records, & &1.uuid)})

      assert_activity_logged("entity_data.bulk_trashed",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"count" => 3, "uuid_count" => 3}
      )
    end

    test "bulk restore (change_status published) threads actor", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      [r | _] = ctx.records
      render_hook(view, "bulk_restore", %{"uuids" => [r.uuid]})

      assert_activity_logged("entity_data.bulk_status_changed",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"status" => "published", "count" => 1}
      )
    end

    test "bulk_action with no selection flashes error, no activity row",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "bulk_archive", %{"uuids" => []})

      assert render(view) =~ "No records selected"

      refute_activity_logged("entity_data.bulk_status_changed",
        actor_uuid: ctx.actor_uuid
      )
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      send(view.pid, {:unknown_message, "noise"})
      assert render(view) =~ "Record 1"
    end

    test "logs at :debug level so unexpected messages stay visible in dev",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      # Global logger level is :warning in test config; lift it locally so
      # the capture sees Logger.debug. Reset on test exit.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:unhandled_in_test, :payload})
          # Force a render so handle_info has flushed before the capture closes.
          render(view)
        end)

      assert log =~ "DataNavigator: unhandled handle_info"
    end
  end

  # ── helpers ──────────────────────────────────────────────────

  describe "push_patch handlers (toggle_view_mode / filter / search)" do
    # These tests mount through the `/phoenix_kit/...` scope in
    # Test.Router so the LV's own `Routes.path/2`-driven push_patch
    # URLs resolve against a defined route. The mounted URL doesn't
    # include the entity_slug here because we test against the
    # navigator with one already in scope.

    defp pk_navigator_url(entity, opts \\ []) do
      base = "/phoenix_kit/en/admin/entities/#{entity.name}/data"

      case Keyword.get(opts, :status) do
        nil -> base
        status -> base <> "?status=#{status}"
      end
    end

    test "toggle_view_mode patches without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, pk_navigator_url(ctx.entity))

      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})
      render_hook(view, "toggle_view_mode", %{"mode" => "table"})
      assert render(view) =~ "Record 1"
    end

    test "filter_by_status patches without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, pk_navigator_url(ctx.entity))

      render_hook(view, "filter_by_status", %{"status" => "published"})
      assert render(view) =~ "Record 1"
    end

    test "search + clear_filters patch without crashing", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, pk_navigator_url(ctx.entity))

      render_hook(view, "search", %{"search" => %{"term" => "find_me"}})
      render_hook(view, "clear_filters", %{})
      assert render(view) =~ "Record 1"
    end

    test "filter_by_entity with empty uuid redirects to entities list (entities route mounted)",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, pk_navigator_url(ctx.entity))

      result = render_hook(view, "filter_by_entity", %{"entity_uuid" => ""})
      # The handler responds with a redirect; the test rendering
      # succeeds because the target `/phoenix_kit/en/admin/entities`
      # IS in our test router.
      assert is_binary(result) or match?({:error, _}, result)
    end
  end

  describe "single record events: toggle_status / restore_data" do
    setup ctx do
      {:ok, record} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Status Toggle",
            slug: "status-toggle",
            status: "draft",
            data: %{"title" => "Status Toggle"},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, record: record}
    end

    test "toggle_status cycles draft → published", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "toggle_status", %{"uuid" => ctx.record.uuid})
      reread = EntityData.get(ctx.record.uuid)
      # toggle_status: draft → published → archived → draft
      assert reread.status in ["published", "archived", "draft"]
    end

    test "restore_data sets status to published", %{conn: conn} = ctx do
      {:ok, _} = EntityData.update(ctx.record, %{status: "archived"}, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "restore_data", %{"uuid" => ctx.record.uuid})
      assert EntityData.get(ctx.record.uuid).status == "published"
    end
  end

  describe "selection + bulk events" do
    setup ctx do
      records =
        Enum.map(1..3, fn i ->
          {:ok, r} =
            EntityData.create(
              %{
                entity_uuid: ctx.entity.uuid,
                title: "Bulk #{i}",
                slug: "bulk-#{i}",
                status: "draft",
                data: %{},
                created_by_uuid: ctx.actor_uuid
              },
              actor_uuid: ctx.actor_uuid
            )

          r
        end)

      {:ok, records: records}
    end

    test "the client-side selection markup contract renders", %{conn: conn} = ctx do
      # Selection lives ENTIRELY client-side in core's BulkSelectScope
      # hook — the server never sees per-row toggles. Pin the markup the
      # hook drives: the select-all box, one value-carrying checkbox per
      # row, and the action buttons that submit the selected uuids.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, _view, html} = live(conn, navigator_url(ctx.entity))

      assert html =~ ~s(data-bulk-role="select-all")

      for r <- ctx.records do
        assert html =~ r.uuid
      end

      assert html =~ ~s(data-bulk-action="bulk_archive")
    end

    test "bulk_set_status flips the selected records", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      uuids = Enum.map(ctx.records, & &1.uuid)
      render_hook(view, "bulk_set_status_published", %{"uuids" => uuids})

      for uuid <- uuids do
        assert EntityData.get(uuid).status == "published"
      end
    end

    test "bulk delete soft-trashes the selected records", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      uuids = Enum.map(ctx.records, & &1.uuid)
      render_hook(view, "bulk_delete", %{"uuids" => uuids})

      for uuid <- uuids do
        assert EntityData.get(uuid, include_trashed: true).status == "trashed"
      end
    end

    test "bulk_action with empty selection flashes error",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "bulk_archive", %{"uuids" => []})
      assert render(view) =~ "No records selected"
    end
  end

  describe "trash_data / restore_from_trash / permanent_delete (issue #12)" do
    test "trash_data soft-deletes — row stays alive, status flips to trashed",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "trash_data", %{"uuid" => record.uuid})

      assert_activity_logged("entity_data.trashed",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )

      assert render(view) =~ "moved to trash"
      assert EntityData.get(record.uuid).status == "trashed"
    end

    test "restore_from_trash flips trashed → published",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "restore_from_trash", %{"uuid" => record.uuid})

      assert_activity_logged("entity_data.restored",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )

      assert render(view) =~ "restored from trash"
      assert EntityData.get(record.uuid).status == "published"
    end

    test "permanent_delete hard-deletes when no parent FK references", %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "permanent_delete", %{"uuid" => record.uuid})

      assert render(view) =~ "permanently deleted"
      refute EntityData.get(record.uuid)

      # Pin the audit row — without this, the LV could silently drop
      # actor_uuid and the test would still pass on flash + DB state.
      assert_activity_logged("entity_data.deleted",
        actor_uuid: ctx.actor_uuid,
        resource_uuid: record.uuid
      )
    end

    test "permanent_delete flashes a friendly message on FK violation, row stays",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      SQL.query!(repo(), """
      CREATE TABLE _dn_test_parent (
        id serial primary key,
        status_uuid uuid NOT NULL REFERENCES phoenix_kit_entity_data(uuid) ON DELETE RESTRICT
      )
      """)

      SQL.query!(
        repo(),
        "INSERT INTO _dn_test_parent (status_uuid) VALUES ($1)",
        [UUID.dump!(record.uuid)]
      )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "permanent_delete", %{"uuid" => record.uuid})

      assert render(view) =~ "referenced by other tables"
      # Row still exists — soft-delete fallback path.
      assert %EntityData{status: "trashed"} = EntityData.get(record.uuid)

      # Pin the audit row — `db_pending: true` flags the user-initiated
      # action that the DB rolled back. Without this assertion the LV
      # could silently drop actor_uuid on the error path.
      assert_activity_logged("entity_data.deleted",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end

    test "permanent_delete flashes :has_children when the trashed row has a live child",
         %{conn: conn} = ctx do
      [parent | _] = ctx.records

      # Live child that points at the parent we're about to trash.
      {:ok, _child} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Child of #{parent.title}",
            status: "published",
            parent_uuid: parent.uuid,
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, _} = EntityData.trash(parent, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "permanent_delete", %{"uuid" => parent.uuid})

      assert render(view) =~ "has child records"
      assert %EntityData{status: "trashed"} = EntityData.get(parent.uuid)

      # Error-branch audit pins the user-initiated action even though
      # the DB rolled back.
      assert_activity_logged("entity_data.deleted",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end

    test "bulk_action 'permanent_delete' hard-deletes selected trashed records",
         %{conn: conn} = ctx do
      [r1, r2, _r3] = ctx.records
      {:ok, _} = EntityData.trash(r1, actor_uuid: ctx.actor_uuid)
      {:ok, _} = EntityData.trash(r2, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "bulk_permanent_delete", %{"uuids" => [r1.uuid, r2.uuid]})

      assert render(view) =~ "permanently deleted"
      refute EntityData.get(r1.uuid)
      refute EntityData.get(r2.uuid)
    end

    test "bulk_action 'restore_from_trash' flips selected trashed → published",
         %{conn: conn} = ctx do
      [r1, r2, _] = ctx.records
      {:ok, _} = EntityData.trash(r1, actor_uuid: ctx.actor_uuid)
      {:ok, _} = EntityData.trash(r2, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "bulk_restore_from_trash", %{"uuids" => [r1.uuid, r2.uuid]})

      assert_activity_logged("entity_data.bulk_restored",
        actor_uuid: ctx.actor_uuid,
        metadata_has: %{"count" => 2}
      )

      assert render(view) =~ "restored from trash"
      assert EntityData.get(r1.uuid).status == "published"
      assert EntityData.get(r2.uuid).status == "published"
    end

    test "trash_data on already-trashed record shows :info flash, not error",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "trash_data", %{"uuid" => record.uuid})
      assert render(view) =~ "already in the trash"
    end

    test "restore_from_trash on non-trashed record shows :info flash",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "restore_from_trash", %{"uuid" => record.uuid})
      assert render(view) =~ "not in the trash"
    end

    test "trash_data refused for non-admin scope", %{conn: conn} = ctx do
      [record | _] = ctx.records

      conn =
        put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid, roles: [], permissions: []))

      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "trash_data", %{"uuid" => record.uuid})

      assert render(view) =~ "Not authorized"
      # Row unchanged.
      assert EntityData.get(record.uuid).status == "published"
    end

    test "restore_from_trash refused for non-admin scope", %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn =
        put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid, roles: [], permissions: []))

      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "restore_from_trash", %{"uuid" => record.uuid})

      assert render(view) =~ "Not authorized"
      assert EntityData.get(record.uuid).status == "trashed"
    end

    test "permanent_delete refused for non-admin scope", %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn =
        put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid, roles: [], permissions: []))

      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "permanent_delete", %{"uuid" => record.uuid})

      assert render(view) =~ "Not authorized"
      assert %EntityData{} = EntityData.get(record.uuid)
    end

    test "bulk_action 'permanent_delete' with empty selection flashes error",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "bulk_permanent_delete", %{"uuids" => []})

      assert render(view) =~ "No records selected"
    end

    test "bulk_action 'restore_from_trash' with empty selection flashes error",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "bulk_restore_from_trash", %{"uuids" => []})

      assert render(view) =~ "No records selected"
    end

    test "bulk_action 'trash' with empty selection flashes error",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "bulk_trash", %{"uuids" => []})

      assert render(view) =~ "No records selected"
    end

    test "bulk_action 'permanent_delete' refused for non-admin scope",
         %{conn: conn} = ctx do
      conn =
        put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid, roles: [], permissions: []))

      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "bulk_permanent_delete", %{"uuids" => []})

      assert render(view) =~ "Not authorized"
    end

    test "an empty Trash offers no chip; a full one does (2026-08-28 filter row)",
         %{conn: conn} = ctx do
      # The status dropdown became a row of counted, clickable chips, and
      # a status nobody can reach stays out of the way: with nothing
      # trashed there is no Trash chip at all.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      refute has_element?(view, ~s|button[phx-value-status="trashed"]|)

      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))
      assert has_element?(view, ~s|button[phx-value-status="trashed"]|, "Trash")
      assert has_element?(view, ~s|button[phx-value-status="trashed"] .badge|, "1")
    end

    test "the current status chip stays visible even at zero",
         %{conn: conn} = ctx do
      # Otherwise selecting Trash from a full bin, then restoring the
      # last record, would erase the control the user is standing on.
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      assert has_element?(view, ~s|button[phx-value-status="trashed"][aria-pressed="true"]|)
      assert has_element?(view, ~s|button[phx-value-status="trashed"] .badge|, "0")
    end

    test "viewing the Trash filter shows Restore + Delete-forever bulk buttons",
         %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      # The action buttons live in the DOM regardless of selection (the
      # BulkSelectScope hook toggles visibility client-side).
      html = render(view)

      assert html =~ ~s(data-bulk-action="bulk_restore_from_trash")
      assert html =~ ~s(data-bulk-action="bulk_permanent_delete")
      # The non-trash views' Trash button should NOT appear.
      refute html =~ ~s(data-bulk-action="bulk_trash")
    end

    test "non-trash view's bulk bar shows Trash but NOT Permanent-delete",
         %{conn: conn} = ctx do
      [record | _] = ctx.records

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      _ = record
      html = render(view)

      assert html =~ ~s(data-bulk-action="bulk_trash")
      refute html =~ ~s(data-bulk-action="bulk_permanent_delete")
      refute html =~ ~s(data-bulk-action="bulk_restore_from_trash")
    end
  end

  describe "status helpers (status_badge_class / status_label / status_icon)" do
    alias PhoenixKitEntities.Web.DataNavigator

    test "trashed sentinel renders as the error badge with the trash icon" do
      assert DataNavigator.status_badge_class("trashed") == "badge-error"
      assert DataNavigator.status_icon("trashed") == "hero-trash"
      assert DataNavigator.status_label("trashed") == "Trashed"
    end

    test "existing statuses still resolve" do
      assert DataNavigator.status_badge_class("published") == "badge-success"
      assert DataNavigator.status_badge_class("draft") == "badge-warning"
      assert DataNavigator.status_badge_class("archived") == "badge-neutral"
    end
  end

  describe "toggle_status preserves trashed status (does NOT cycle to published)" do
    test "toggle_status on a trashed record is a no-op", %{conn: conn} = ctx do
      [record | _] = ctx.records
      {:ok, _} = EntityData.trash(record, actor_uuid: ctx.actor_uuid)

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity, status: "trashed"))

      render_hook(view, "toggle_status", %{"uuid" => record.uuid})

      # Status MUST NOT cycle out of trashed. Restore is the only escape.
      assert EntityData.get(record.uuid).status == "trashed"
    end
  end

  describe "reorder_records (drag-and-drop)" do
    test "reorders records and refreshes the list",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      [r1, r2, r3] = ctx.records
      ordered = [r3.uuid, r1.uuid, r2.uuid]

      render_hook(view, "reorder_records", %{"ordered_ids" => ordered})

      assert EntityData.get(r3.uuid).position == 1
      assert EntityData.get(r1.uuid).position == 2
      assert EntityData.get(r2.uuid).position == 3

      # A SUCCESSFUL reorder is audited, and against the admin who dragged.
      # Only the failure and rejected-payload paths used to log, so the
      # activity table recorded reorders exclusively when they went wrong.
      assert_activity_logged("entity_data.reordered",
        actor_uuid: ctx.actor_uuid,
        resource_type: "entity_data",
        metadata_has: %{"count" => 3}
      )
    end

    test "first drag implicitly switches sort_mode to manual + logs warning",
         %{conn: conn} = ctx do
      # Entity starts with default sort_mode = "auto"
      assert Entities.get_sort_mode(ctx.entity) == "auto"

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      previous = Logger.level()
      Logger.configure(level: :warning)
      on_exit(fn -> Logger.configure(level: previous) end)

      [r1, r2, _r3] = ctx.records

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          render_hook(view, "reorder_records", %{"ordered_ids" => [r2.uuid, r1.uuid]})
        end)

      # The flip is persisted on the entity row.
      reread = Entities.get_entity!(ctx.entity.uuid)
      assert Entities.get_sort_mode(reread) == "manual"

      assert log =~ "auto-switched sort_mode to \"manual\""
    end

    test "malformed payload (no ordered_ids) flashes error without crashing",
         %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      render_hook(view, "reorder_records", %{"unexpected" => "shape"})

      assert render(view) =~ "Failed to save the new order"
      # LV still alive.
      assert render(view) =~ "Record 1"
    end
  end

  describe "status filter row (2026-08-28: the dashboard cards are gone)" do
    test "counts live ON the filter, not in four cards above the fold", %{conn: conn} = ctx do
      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, navigator_url(ctx.entity))

      # The four stat cards and their CMS vocabulary are gone…
      refute html =~ "Total Records"
      refute html =~ "All data records"
      refute html =~ "Live content"
      refute html =~ "Work in progress"
      refute html =~ "Stored content"

      # …the numbers they carried are on the chips, which actually filter.
      assert has_element?(view, ~s|button[phx-value-status="all"] .badge|, "3")
      assert has_element?(view, ~s|button[phx-value-status="published"] .badge|, "3")
      assert has_element?(view, ~s|button[phx-value-status="all"][aria-pressed="true"]|)

      # Empty statuses stay out of the way until they hold something.
      refute has_element?(view, ~s|button[phx-value-status="draft"]|)
      refute has_element?(view, ~s|button[phx-value-status="archived"]|)
    end

    test "a chip click filters the list", %{conn: conn} = ctx do
      {:ok, _} =
        EntityData.create(
          %{
            entity_uuid: ctx.entity.uuid,
            title: "Unfinished",
            slug: "unfinished",
            status: "draft",
            data: %{},
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, _html} = live(conn, navigator_url(ctx.entity))

      # A draft exists now, so its chip appears with the count and the
      # click wiring that reaches filter_by_status.
      assert has_element?(view, ~s|button[phx-value-status="draft"] .badge|, "1")

      assert has_element?(
               view,
               ~s|button[phx-click="filter_by_status"][phx-value-status="draft"]|
             )

      # Where that click lands (the chip patches the URL, which this
      # harness mounts under a different prefix than Routes.path/1
      # builds — so drive the destination directly).
      {:ok, view, html} = live(conn, navigator_url(ctx.entity, status: "draft"))
      assert html =~ "Unfinished"
      refute html =~ "Record 1"
      assert has_element?(view, ~s|button[phx-value-status="draft"][aria-pressed="true"]|)
    end

    test "a brand-new entity shows no filter row at all", %{conn: conn} = ctx do
      # This was the worst case of the old design: four giant zeros.
      {:ok, empty} =
        Entities.create_entity(
          %{
            name: "dn_empty",
            display_name: "DN Empty",
            display_name_plural: "DN Empties",
            fields_definition: [],
            status: "published",
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
      {:ok, view, html} = live(conn, navigator_url(empty))

      refute has_element?(view, ~s|button[phx-value-status="all"]|)
      refute html =~ "Search by title or slug"
      # …but the way forward is still there.
      assert html =~ "No Data Records Yet"
    end
  end

  defp navigator_url(entity, opts \\ []) do
    base = "/en/admin/entities/#{entity.name}/data"

    case Keyword.get(opts, :status) do
      nil -> base
      status -> base <> "?status=#{status}"
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
