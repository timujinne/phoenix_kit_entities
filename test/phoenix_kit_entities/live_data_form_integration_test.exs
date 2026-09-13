defmodule PhoenixKitEntities.LiveDataFormIntegrationTest do
  @moduledoc """
  DB-backed behavior of `PhoenixKitEntities.Components.LiveDataForm`:
  autosave persistence, the `:submitted` message, and status preservation.

  `handle_event/3` is invoked directly against a hand-built
  `%Phoenix.LiveView.Socket{}` rather than through a mounted LiveView —
  `Phoenix.Component.assign/3` works on any `%Socket{}` regardless of
  whether it's attached to a live process, and the component neither
  subscribes to PubSub nor uses `@myself`/routing in a way that requires
  one. This mirrors calling a plain function with a hand-built first
  argument; it does not exercise the client-side `phx-change`/`phx-submit`
  wiring itself (covered structurally by the unit tests in
  `live_data_form_test.exs`), only the server-side effects once those
  events land.
  """
  use PhoenixKitEntities.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.LiveDataForm
  alias PhoenixKitEntities.EntityData

  @endpoint PhoenixKitEntities.Test.Endpoint

  @fields [
    %{"type" => "text", "key" => "name", "label" => "Name"},
    %{
      "type" => "checkbox",
      "key" => "tools",
      "label" => "Tools",
      "options" => ["Hammer", "Drill"]
    }
  ]

  defp create_entity!(fields \\ @fields) do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "live_data_form_test_#{System.unique_integer([:positive])}",
          display_name: "LiveDataForm Test",
          display_name_plural: "LiveDataForm Tests",
          fields_definition: fields,
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    entity
  end

  defp create_record!(entity, data, status \\ "published") do
    actor_uuid = Ecto.UUID.generate()

    {:ok, record} =
      EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: "Survey response",
          status: status,
          data: data,
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    record
  end

  defp socket(record, entity, opts \\ []) do
    assigns =
      %{
        __changed__: %{},
        record: record,
        entity: entity,
        mode: :edit,
        lang: "et",
        actor: nil,
        submit_label: nil
      }
      |> Map.merge(Map.new(opts))

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  describe "autosave" do
    test "persists the merged data and preserves status" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old", "tools" => ["Hammer"]}, "published")
      socket = socket(record, entity)

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New", "tools" => ["Drill"]}}},
          socket
        )

      assert socket.assigns.record.data["name"] == "New"
      assert socket.assigns.record.data["tools"] == ["Drill"]
      assert socket.assigns.record.status == "published"
      assert_received {:live_data_form, :saved, updated_record}
      assert updated_record.uuid == record.uuid

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "New"
      assert reloaded.status == "published"
    end

    test "does not reset status on a draft record" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "draft")
      socket = socket(record, entity)

      {:noreply, _socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
          socket
        )

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "New"
      assert reloaded.status == "draft"
    end

    test "unchecking every checkbox clears the stored list instead of leaving it untouched" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old", "tools" => ["Hammer", "Drill"]})
      socket = socket(record, entity)

      # Browsers omit the `tools` param entirely when every checkbox in the
      # group is unticked — no `data[tools][]` key at all.
      {:noreply, socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Old"}}},
          socket
        )

      assert socket.assigns.record.data["tools"] == []
    end

    test "unchecking the only field on the form (checkbox-only entity) still clears it" do
      # When EVERY input on the form is a checkbox group (no text/other
      # field to anchor a "phoenix_kit_entity_data" key), unticking the
      # last box makes phx-change submit params with no
      # "phoenix_kit_entity_data" key at all — just LiveView's internal
      # "_target". The fallback `handle_event("autosave", _params, socket)`
      # clause must still run the merge/persist path (with an empty map)
      # rather than no-op'ing, or this case would silently never clear.
      fields = [
        %{
          "type" => "checkbox",
          "key" => "tools",
          "label" => "Tools",
          "options" => ["Hammer", "Drill"]
        }
      ]

      entity = create_entity!(fields)
      record = create_record!(entity, %{"tools" => ["Hammer"]})
      socket = socket(record, entity)

      {:noreply, socket} =
        LiveDataForm.handle_event("autosave", %{"_target" => ["nonexistent"]}, socket)

      assert socket.assigns.record.data["tools"] == []
      assert_received {:live_data_form, :saved, updated_record}
      assert updated_record.data["tools"] == []

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["tools"] == []
    end

    test "a key with no matching field definition is dropped before persisting" do
      # A crafted/legacy param riding along with a legitimate autosave
      # payload — `whitelist_known_fields/2` (live_data_form.ex) filters
      # it out after `merge_other_params/2`, so it never lands in
      # `record.data` even though the changeset itself has no opinion on
      # unknown keys (JSONB `data` accepts anything).
      entity = create_entity!()
      record = create_record!(entity, %{})
      socket = socket(record, entity)

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{
            "phoenix_kit_entity_data" => %{
              "data" => %{"name" => "Jaan", "role" => "admin"}
            }
          },
          socket
        )

      assert socket.assigns.record.data["name"] == "Jaan"
      refute Map.has_key?(socket.assigns.record.data, "role")

      reloaded = EntityData.get!(record.uuid)
      refute Map.has_key?(reloaded.data, "role")
    end

    test "resolves an allow_other sentinel before persisting" do
      fields = [
        %{
          "type" => "radio",
          "key" => "color",
          "label" => "Color",
          "options" => ["Red", "Blue"],
          "allow_other" => true
        }
      ]

      entity = create_entity!(fields)
      record = create_record!(entity, %{})
      socket = socket(record, entity)

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{
            "phoenix_kit_entity_data" => %{
              "data" => %{"color" => "__other__", "color__other" => "Crimson"}
            }
          },
          socket
        )

      assert socket.assigns.record.data["color"] == "Crimson"
    end

    test "an EntityData.changeset failure logs and keeps the previous record" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      # entity_uuid pointing at a deleted/unknown entity trips
      # `validate_entity_reference`/`validate_data_against_entity` inside
      # `EntityData.changeset/2`, forcing the `{:error, changeset}` branch —
      # this is the FINAL, hard-blocking validator (unlike
      # `FormBuilder.validate_data/2` below, which never blocks a save).
      broken_record = %{record | entity_uuid: Ecto.UUID.generate()}
      socket = socket(broken_record, entity)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:noreply, updated_socket} =
            LiveDataForm.handle_event(
              "autosave",
              %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
              socket
            )

          send(self(), {:updated_socket, updated_socket})
        end)

      assert log =~ "LiveDataForm autosave failed"
      assert_received {:updated_socket, socket}
      assert socket.assigns.record == broken_record
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end

    test "a number field's string value is coerced to a float on persist" do
      fields = [%{"type" => "number", "key" => "qty", "label" => "Quantity"}]
      entity = create_entity!(fields)
      record = create_record!(entity, %{})
      socket = socket(record, entity)

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"qty" => "5"}}},
          socket
        )

      assert socket.assigns.record.data["qty"] == 5.0

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["qty"] == 5.0
    end

    test "an out-of-options radio value fails EntityData's changeset too, so the save is rejected" do
      # Historically `radio` fields were validated strictly by
      # `FormBuilder.validate_type/2` (value must be one of `options`,
      # absent `allow_other`) but had NO type-specific branch in
      # `EntityData.changeset/2`'s own `validate_field_type/2` — so an
      # out-of-options value failed the FormBuilder pass while still
      # sailing through `EntityData.update/3` and getting persisted
      # as-is. `EntityData.changeset/2` now validates radio the same way
      # `select` always has, closing that gap: this now hits the
      # hard-blocking changeset-failure path instead (like the
      # `broken_record` test above), and the previous record is kept.
      fields = [
        %{
          "type" => "radio",
          "key" => "priority",
          "label" => "Priority",
          "options" => ["Low", "High"]
        }
      ]

      entity = create_entity!(fields)
      record = create_record!(entity, %{})
      socket = socket(record, entity)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:noreply, updated_socket} =
            LiveDataForm.handle_event(
              "autosave",
              %{"phoenix_kit_entity_data" => %{"data" => %{"priority" => "Medium"}}},
              socket
            )

          send(self(), {:updated_socket, updated_socket})
        end)

      assert log =~ "LiveDataForm autosave failed"
      assert_received {:updated_socket, updated_socket}
      assert updated_socket.assigns.record.data == %{}
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data == %{}
    end
  end

  describe "value-shape sanitization (crafted map payload, M2)" do
    # End-to-end version of the `sanitize_values/2` unit tests in
    # `live_data_form_test.exs`: a crafted "autosave" can name any real
    # field key (`whitelist_known_fields/2` only filters by key) — before
    # this fix, a map value for a `text` field would sail into
    # `record.data` and crash rendering (`Protocol.UndefinedError`) for
    # every subsequent viewer, in BOTH `:edit` (`<textarea>{@value}</textarea>`)
    # and `:readonly` (`to_string/1`). Confirms the map never reaches the
    # row and that both render modes stay alive afterward — the record's
    # last-known-good value is preserved instead.
    test "a crafted map value for a text field is dropped, not persisted, and both render modes stay alive" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      entity = create_entity!(fields)
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => %{"evil" => "map"}}}},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "Old"
      assert_received {:live_data_form, :saved, updated_record}
      refute is_map(updated_record.data["name"])

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"

      edit_html =
        render_component(LiveDataForm, %{
          id: "shape-guard-edit",
          record: reloaded,
          mode: :edit,
          lang: nil,
          actor: nil,
          submit_label: nil
        })

      readonly_html =
        render_component(LiveDataForm, %{
          id: "shape-guard-readonly",
          record: reloaded,
          mode: :readonly,
          lang: nil,
          actor: nil,
          submit_label: nil
        })

      assert edit_html =~ "Old"
      assert readonly_html =~ "Old"
    end

    test "a crafted list-of-maps value for a checkbox field drops the non-binary entries instead of failing the whole save" do
      fields = [
        %{
          "type" => "checkbox",
          "key" => "tools",
          "label" => "Tools",
          "options" => ["Hammer", "Drill"]
        }
      ]

      entity = create_entity!(fields)
      record = create_record!(entity, %{"tools" => []})
      socket = socket(record, entity)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{
            "phoenix_kit_entity_data" => %{
              "data" => %{"tools" => [%{"evil" => "map"}, "Hammer"]}
            }
          },
          socket
        )

      assert updated_socket.assigns.record.data["tools"] == ["Hammer"]

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["tools"] == ["Hammer"]
    end
  end

  describe "malformed payload guard (m2)" do
    # DB-backed end-to-end version of the `extract_data_params/1` unit
    # tests in `live_data_form_test.exs`: reaching `handle_event/3`'s
    # guarded clauses at all needs `mode: :edit`, which unconditionally
    # ends at `EntityData.update/3` (a live database), so proving the full
    # "crafted payload -> no crash, no write" chain needs this DB-backed
    # test rather than a pure unit test. Before this fix, both payloads
    # below raised `BadMapError` synchronously inside `handle_event/3` —
    # crashing the whole LiveView process (every component on the page for
    # that user), not just this one.
    test "a non-map phoenix_kit_entity_data payload does not crash and does not write" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => "not-a-map"},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "Old"

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end

    test "a non-map \"data\" value does not crash normalize_absent_checkboxes and does not write" do
      fields = [
        %{
          "type" => "checkbox",
          "key" => "tools",
          "label" => "Tools",
          "options" => ["Hammer", "Drill"]
        }
      ]

      entity = create_entity!(fields)
      record = create_record!(entity, %{"tools" => ["Hammer"]})
      socket = socket(record, entity)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => ["a", "b"]}},
          socket
        )

      assert updated_socket.assigns.record.data["tools"] == ["Hammer"]

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["tools"] == ["Hammer"]
    end

    test "the same guards protect the submit event" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity, submit_label: "Kinnitan")

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => "not-a-map"},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "Old"
      refute_received {:live_data_form, :submitted, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end
  end

  describe "mode guard (security)" do
    # Same guard as the unit tests in `live_data_form_test.exs`, but here
    # with a real, DB-persisted record — confirms the guard rejects the
    # event before `EntityData.update/3` ever runs, not merely that the
    # in-memory socket assign looks untouched.
    test "autosave against a :readonly socket does not persist and sends no :saved" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old", "tools" => ["Hammer"]}, "published")
      socket = socket(record, entity, mode: :readonly)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Hacked"}}},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "Old"
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end

    test "submit against a :readonly socket does not persist and sends no :submitted" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "published")
      socket = socket(record, entity, mode: :readonly, submit_label: "Kinnitan")

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Hacked"}}},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "Old"
      refute_received {:live_data_form, :submitted, _}
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end
  end

  describe "activity logging" do
    test "autosave does not log an entity_data.updated activity row" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity)

      {:noreply, _socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
          socket
        )

      refute_activity_logged("entity_data.updated", resource_uuid: record.uuid)
    end

    test "submit still logs an entity_data.updated activity row" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity, submit_label: "Kinnitan")

      {:noreply, _socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Final"}}},
          socket
        )

      assert_activity_logged("entity_data.updated", resource_uuid: record.uuid)
    end
  end

  describe "cross-session status guard (persist_statuses)" do
    # Simulates two browser tabs holding the same record: this test's
    # `socket` plays the SECOND tab, still holding an :edit view built
    # from `record` (status "draft") after a FIRST tab has since
    # submitted/published the same row directly in the DB. Without
    # `persist_statuses`, `mode == :edit` alone doesn't catch this —
    # this socket genuinely IS in edit mode, it's just editing a record
    # that has moved on underneath it.
    test "autosave refuses once the DB record has moved outside persist_statuses" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "draft")
      socket = socket(record, entity, persist_statuses: ["draft"])

      {:ok, _published} =
        EntityData.update(record, %{status: "published"}, actor_uuid: Ecto.UUID.generate())

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
          socket
        )

      assert updated_socket.assigns.record == record
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
      assert reloaded.status == "published"
    end

    test "submit refuses once the DB record has moved outside persist_statuses" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "draft")
      socket = socket(record, entity, persist_statuses: ["draft"], submit_label: "Kinnitan")

      {:ok, _published} =
        EntityData.update(record, %{status: "published"}, actor_uuid: Ecto.UUID.generate())

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
          socket
        )

      assert updated_socket.assigns.record == record
      refute_received {:live_data_form, :submitted, _}
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
      assert reloaded.status == "published"
    end

    test "autosave still succeeds when the record's status is in persist_statuses" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "draft")
      socket = socket(record, entity, persist_statuses: ["draft"])

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "New"}}},
          socket
        )

      assert updated_socket.assigns.record.data["name"] == "New"
      assert_received {:live_data_form, :saved, updated_record}
      assert updated_record.data["name"] == "New"

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "New"
    end
  end

  describe "submit" do
    # Contract (revised): submit persists the params `phx-submit` just
    # sent — same merge-over-`record.data` path as autosave — so the
    # last edit is never lost to the 500ms debounce window, then sends
    # `:submitted` with the freshly-updated record. It never touches
    # `status`.
    test "persists the submitted params and sends :submitted with the updated record" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      socket = socket(record, entity, submit_label: "Kinnitan")

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Final"}}},
          socket
        )

      assert_received {:live_data_form, :submitted, submitted_record}
      assert submitted_record.uuid == record.uuid
      assert submitted_record.data["name"] == "Final"
      refute_received {:live_data_form, :saved, _}

      assert socket.assigns.record.data["name"] == "Final"

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Final"
    end

    test "submitting a published record persists data without changing its status" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"}, "published")
      socket = socket(record, entity, submit_label: "Kinnitan")

      {:noreply, _socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Final"}}},
          socket
        )

      assert_received {:live_data_form, :submitted, submitted_record}
      assert submitted_record.status == "published"
      assert submitted_record.data["name"] == "Final"

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.status == "published"
      assert reloaded.data["name"] == "Final"
    end

    test "a failed save logs, keeps the previous record, and never sends :submitted" do
      entity = create_entity!()
      record = create_record!(entity, %{"name" => "Old"})
      # Same broken-reference trick as the autosave failure test — trips
      # `EntityData.changeset/2`'s entity validation so `update/3` returns
      # `{:error, changeset}`.
      broken_record = %{record | entity_uuid: Ecto.UUID.generate()}
      socket = socket(broken_record, entity, submit_label: "Kinnitan")

      {:noreply, socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Final"}}},
          socket
        )

      refute_received {:live_data_form, :submitted, _}
      refute_received {:live_data_form, :saved, _}
      assert socket.assigns.record == broken_record

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["name"] == "Old"
    end
  end

  describe "managed blueprint write-guard error (MINOR-5)" do
    # MINOR-5 (2026-09-11 review): `persist_data/3`'s catch-all used to
    # be `{:error, changeset} -> Logger.error("... #{inspect(changeset.errors)} ...")`,
    # which would also match `EntityData.update/3`'s `{:error, :locked_key}`
    # and then raise `KeyError` calling `.errors` on an atom. Unreachable
    # through this component's ORDINARY payload shape (`%{"data" => ...}`
    # only, no `slug`/`entity_uuid` key), but reachable through a
    # legitimately-registered field type `sanitize_values/2` doesn't
    # special-case (`"decimal"` isn't in `@scalar_value_types` and has no
    # clause of its own, so it falls to the catch-all that passes the
    # value through unchanged — see the comment above that clause), so a
    # field keyed on a real language code can carry a map deep enough to
    # reach `data[lang]["_slug"]` — the guard `renames_translated_slug?/2`
    # (see the parent PR's MINOR-6 fix) protects on a managed blueprint.
    test "a locked_key refusal is logged, not raised, and the record is left untouched" do
      actor_uuid = Ecto.UUID.generate()

      {:ok, managed_entity} =
        Entities.create_entity(
          %{
            name: "live_data_form_managed_#{System.unique_integer([:positive])}",
            display_name: "Managed",
            display_name_plural: "Managed",
            fields_definition: [
              %{"type" => "decimal", "key" => "et", "label" => "Estonian overrides"}
            ],
            created_by_uuid: actor_uuid,
            settings: %{"managed_by" => "catalogue", "locked_keys" => []}
          },
          on_behalf_of: "catalogue"
        )

      record =
        create_record!(managed_entity, %{
          "_primary_language" => "en",
          "en" => %{"_title" => "Oak", "_slug" => "oak"},
          "et" => %{"_title" => "Tamm", "_slug" => "tamm"}
        })

      socket = socket(record, managed_entity)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{
            "phoenix_kit_entity_data" => %{
              "data" => %{"et" => %{"_slug" => "forged-tamm"}}
            }
          },
          socket
        )

      # Did not raise KeyError, refused the write, and left the record
      # (and socket) exactly as they were.
      assert updated_socket.assigns.record == record
      refute_received {:live_data_form, :saved, _}

      reloaded = EntityData.get!(record.uuid)
      assert reloaded.data["et"]["_slug"] == "tamm"
    end
  end
end
