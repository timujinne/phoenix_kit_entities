defmodule PhoenixKitEntities.LiveDataFormTest do
  @moduledoc """
  `PhoenixKitEntities.Components.LiveDataForm` is a stateful `LiveComponent`,
  so exercising it needs `Phoenix.LiveViewTest.render_component/2` (which
  runs `update/2` + `render/1` through `Phoenix.LiveView.Diff`) rather than
  the plain-function-component pattern used by `FormBuilder.build_field/3`
  in the other `form_builder_*_test.exs` files.

  `render_component/2` only needs an `@endpoint` module attribute at
  compile time — it never dereferences the endpoint as a running process
  unless the component itself calls something endpoint-dependent (routing
  helpers, etc.), which this component doesn't. So these tests stay in the
  DB-free unit bucket as long as `record.entity` is preloaded (avoiding the
  `Entities.get_entity!/2` DB fallback in `resolve_entity/3`) — exactly the
  case a real caller hits when it preloads `:entity` before rendering.

  Autosave persistence, the `:submitted` message, and status-preservation
  are `:integration` tests in `live_data_form_integration_test.exs` (they
  need a live process + the database for `EntityData.update/3`).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEntities.Components.LiveDataForm
  alias PhoenixKitEntities.EntityData

  @endpoint PhoenixKitEntities.Test.Endpoint

  defp entity(fields) do
    %PhoenixKitEntities{uuid: Ecto.UUID.generate(), fields_definition: fields}
  end

  defp record(entity, data \\ %{}) do
    %EntityData{
      uuid: Ecto.UUID.generate(),
      entity_uuid: entity.uuid,
      entity: entity,
      title: "Survey",
      status: "published",
      data: data
    }
  end

  defp render_form(assigns) do
    render_component(
      LiveDataForm,
      Map.put(assigns, :id, "live-data-form-#{System.unique_integer([:positive])}")
    )
  end

  describe ":readonly mode" do
    test "renders a heading and no inputs" do
      fields = [%{"type" => "heading", "key" => "sec", "label" => "Section One"}]
      e = entity(fields)
      r = record(e)

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "<h3"
      assert html =~ "Section One"
      refute html =~ "<input"
      refute html =~ "<textarea"
      refute html =~ "<select"
    end

    test "shows a field's stored value as label: value" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Name"
      assert html =~ "Jaan"
      refute html =~ "<input"
    end

    test "an empty field renders the em dash placeholder" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "—"
    end

    test "a checkbox list is joined with commas" do
      fields = [
        %{
          "type" => "checkbox",
          "key" => "tools",
          "label" => "Tools",
          "options" => ["Hammer", "Drill", "Saw"]
        }
      ]

      e = entity(fields)
      r = record(e, %{"tools" => ["Hammer", "Saw"]})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Hammer, Saw"
      refute html =~ "<input"
    end

    test "a textarea value keeps its line breaks and is not comma-joined" do
      fields = [%{"type" => "textarea", "key" => "notes", "label" => "Notes"}]
      e = entity(fields)
      r = record(e, %{"notes" => "line one\nline two"})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "line one\nline two"
      refute html =~ "<textarea"
    end

    test "a value outside the fixed options (allow_other free text) is shown as-is" do
      fields = [
        %{
          "type" => "radio",
          "key" => "color",
          "label" => "Color",
          "options" => ["Red", "Blue"],
          "allow_other" => true
        }
      ]

      e = entity(fields)
      r = record(e, %{"color" => "Crimson"})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Crimson"
    end
  end

  describe ":edit mode" do
    # `lang: nil` throughout this block (rather than a real locale like
    # "et") is deliberate: `FormBuilder.build_fields/3` only touches
    # `Multilang`/the database when `lang_code` is non-nil (it short-circuits
    # on `nil` in both `maybe_add_primary_placeholders/4` and
    # `maybe_apply_language_view/3`). None of these assertions are about
    # language-specific behavior, so `nil` keeps them fast and DB-free. The
    # "lang pass-through" test below covers the non-nil path once.

    test "renders an autosaving, debounced form targeting the component" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e)

      html = render_form(%{record: r, mode: :edit, lang: nil, actor: nil, submit_label: nil})

      assert html =~ ~s(phx-change="autosave")
      assert html =~ ~s(phx-submit="submit")
      assert html =~ ~s(phx-debounce="500")
      assert html =~ ~s(name="phoenix_kit_entity_data[data][name]")
    end

    test "hides the submit button when submit_label is nil" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e)

      html = render_form(%{record: r, mode: :edit, lang: nil, actor: nil, submit_label: nil})

      refute html =~ ~s(type="submit")
    end

    test "shows the submit button with the given label when submit_label is set" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e)

      html =
        render_form(%{record: r, mode: :edit, lang: nil, actor: nil, submit_label: "Kinnitan"})

      assert html =~ ~s(type="submit")
      assert html =~ "Kinnitan"
    end

    test "renders a heading field with no input, same as readonly mode" do
      fields = [
        %{"type" => "heading", "key" => "sec", "label" => "Section One"},
        %{"type" => "text", "key" => "name", "label" => "Name"}
      ]

      e = entity(fields)
      r = record(e)

      html = render_form(%{record: r, mode: :edit, lang: nil, actor: nil, submit_label: nil})

      assert html =~ "<h3"
      assert html =~ "Section One"
    end
  end

  describe "lang pass-through" do
    # Exercises the one path where `lang` reaching `FormBuilder.build_fields/3`
    # as a real locale actually does something observable pre-render: it
    # probes `Multilang`/`Languages`, which — with no test DB in this
    # sandbox — blocks on a connection-pool queue timeout before falling
    # back safely. That's a pre-existing characteristic of
    # `FormBuilder.build_fields/3` (see `form_builder_multilang_test.exs`
    # for the DB-backed multilang suite), not something this component
    # introduces; kept to a single test so it doesn't slow down the rest
    # of this file.
    test "a non-nil lang still renders the form correctly" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html = render_form(%{record: r, mode: :edit, lang: "et", actor: nil, submit_label: nil})

      assert html =~ ~s(phx-change="autosave")
      assert html =~ "Jaan"
    end
  end

  describe "entity resolution" do
    test "reuses the preloaded :entity association without hitting the database" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      # entity_uuid points nowhere in the DB — if resolve_entity fell back
      # to a query, this would raise Ecto.NoResultsError (no DB is even
      # configured to connect to in this async unit test).
      r = record(e)

      html = render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Name"
    end
  end

  describe "id_prefix fallback for a not-yet-persisted record" do
    test "falls back to the component's own id when record.uuid is nil" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      # A record still being built (never saved) has no uuid yet.
      r = %EntityData{
        uuid: nil,
        entity_uuid: e.uuid,
        entity: e,
        title: "New",
        status: "draft",
        data: %{}
      }

      html =
        render_component(LiveDataForm, %{
          id: "ld-form-new",
          record: r,
          mode: :edit,
          lang: nil,
          actor: nil,
          submit_label: nil
        })

      # Without the `|| @id` fallback this would render
      # `id="entity-field-name-primary"` (no prefix at all) for every
      # not-yet-persisted instance, colliding across multiple such
      # instances on the same page.
      assert html =~ ~s(id="entity-field-ld-form-new-name-primary")
    end
  end

  describe "mode guard (security)" do
    # `handle_event/3` is reachable for any event this component defines
    # regardless of what the rendered template wires up — LiveView
    # dispatches a component event by `cid` alone. A `:readonly` instance
    # never renders a `<form phx-change="autosave" ...>`, but that alone
    # doesn't stop a crafted client-side push from reaching this
    # `handle_event/3` clause. These are handle_event/3 called directly
    # (no live process needed — mirrors the DB-backed tests in
    # `live_data_form_integration_test.exs`), and specifically DON'T need
    # the database: the mode guard must reject the event before
    # `persist_data/3` (and therefore `EntityData.update/3`) ever runs.
    defp readonly_socket(record, entity) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          record: record,
          entity: entity,
          mode: :readonly,
          lang: nil,
          actor: nil,
          submit_label: nil
        }
      }
    end

    test "autosave is a no-op in :readonly mode" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Old"})
      socket = readonly_socket(r, e)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "autosave",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Hacked"}}},
          socket
        )

      assert updated_socket.assigns.record.data == %{"name" => "Old"}
      refute_received {:live_data_form, :saved, _}
    end

    test "submit is a no-op in :readonly mode" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Old"})
      socket = readonly_socket(r, e)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event(
          "submit",
          %{"phoenix_kit_entity_data" => %{"data" => %{"name" => "Hacked"}}},
          socket
        )

      assert updated_socket.assigns.record.data == %{"name" => "Old"}
      refute_received {:live_data_form, :submitted, _}
    end

    test "the fallback autosave clause (no phoenix_kit_entity_data key) is also a no-op in :readonly mode" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      e = entity(fields)
      r = record(e, %{"tools" => ["Hammer"]})
      socket = readonly_socket(r, e)

      {:noreply, updated_socket} =
        LiveDataForm.handle_event("autosave", %{"_target" => ["nonexistent"]}, socket)

      assert updated_socket.assigns.record.data == %{"tools" => ["Hammer"]}
      refute_received {:live_data_form, :saved, _}
    end
  end

  describe "optional attrs (lang, actor, submit_label, persist_statuses) can be omitted entirely" do
    # `update/2` only sets a key on `socket.assigns` for what the caller
    # actually passes in — a caller that omits `:lang`/`:actor`/
    # `:submit_label` (not even `nil`) used to leave `render/1`'s
    # `@lang`/`@submit_label` raising `KeyError`, since these are
    # documented as optional. `assign_new/3` in `update/2` now backfills
    # `nil` for each. `record` stays genuinely required — no test for
    # omitting it; a caller bug there should crash. `mode`, however,
    # does NOT crash when omitted — `update/2` never required it to be
    # present, and `render/1` fails closed to the readonly view for any
    # `mode` other than an explicit `:edit` (see the "fail-closed render"
    # describe block below).
    test ":readonly renders fine with only record and mode given" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html =
        render_component(LiveDataForm, %{id: "live-data-form-omit-1", record: r, mode: :readonly})

      assert html =~ "Jaan"
    end

    test ":edit renders fine with only record and mode given — no submit button" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e)

      html =
        render_component(LiveDataForm, %{id: "live-data-form-omit-2", record: r, mode: :edit})

      assert html =~ ~s(phx-change="autosave")
      refute html =~ ~s(type="submit")
    end

    test "renders fine with persist_statuses omitted entirely (not just nil)" do
      # `persist_statuses` isn't read anywhere in `render/1`'s template
      # (only by `persist_data/3` at save time), so omitting it can't
      # raise a `KeyError` here the way omitting `lang`/`submit_label`
      # used to — this just documents/locks in that omitting it is a
      # fully supported, ordinary case, same as every other optional attr.
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html =
        render_component(LiveDataForm, %{id: "live-data-form-omit-3", record: r, mode: :edit})

      assert html =~ ~s(phx-change="autosave")
      assert html =~ "Jaan"
    end
  end

  describe "fail-closed render (missing/invalid mode)" do
    # `render/1` matches ONLY `mode: :edit` for the editable form; every
    # other clause — including a caller that forgets to pass `mode` at
    # all — renders the static readonly view. This matters together with
    # `handle_event/3`'s own `mode == :edit` guard: if a missing `mode`
    # rendered the form instead (e.g. by falling through a catch-all),
    # the result would be an editable-LOOKING form that silently drops
    # every autosave/submit, which is worse than an obviously-static
    # readonly view.
    test "omitting mode entirely renders the readonly view, not the form" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html = render_component(LiveDataForm, %{id: "live-data-form-no-mode", record: r})

      refute html =~ "<form"
      refute html =~ ~s(phx-change="autosave")
      assert html =~ "Jaan"
    end

    test "an unrecognized mode value also renders the readonly view" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => "Jaan"})

      html =
        render_component(LiveDataForm, %{
          id: "live-data-form-bad-mode",
          record: r,
          mode: :bogus
        })

      refute html =~ "<form"
      refute html =~ ~s(phx-change="autosave")
      assert html =~ "Jaan"
    end
  end

  describe ":readonly mode renders already-stored non-scalar values without crashing" do
    # `sanitize_values/2` and `EntityData.changeset/2`'s shape guards only
    # gate what lands in `data` from now on. A row poisoned before they
    # existed — or written by a parent app calling `EntityData` directly,
    # or under a `file` key, which neither layer had an opinion on — still
    # holds whatever term it holds, and THIS view is where it gets
    # rendered. `to_string/1` / `Enum.join/2` raise `Protocol.UndefinedError`
    # on a bare map, which crashed the page for every subsequent viewer
    # with no fix short of a manual DB edit. These lock in that the
    # readonly view degrades (inspect) instead.

    test "a map stored under a text field renders instead of raising" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]
      e = entity(fields)
      r = record(e, %{"name" => %{"evil" => "map"}})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Name"
      assert html =~ "evil"
    end

    test "a map stored under a textarea field renders instead of raising" do
      fields = [%{"type" => "textarea", "key" => "notes", "label" => "Notes"}]
      e = entity(fields)
      r = record(e, %{"notes" => %{"evil" => "map"}})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Notes"
      assert html =~ "evil"
    end

    test "a map stored under a select field renders instead of raising" do
      # `translated_option_label/3` falls back to the RAW stored value when
      # it has no translation entry, so the map reaches `{@display}`
      # directly on this clause.
      fields = [
        %{"type" => "select", "key" => "color", "label" => "Color", "options" => ["Red"]}
      ]

      e = entity(fields)
      r = record(e, %{"color" => %{"evil" => "map"}})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Color"
      assert html =~ "evil"
    end

    test "a list of maps stored under a checkbox field renders instead of raising" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      e = entity(fields)
      r = record(e, %{"tools" => ["Hammer", %{"evil" => "map"}]})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Hammer"
      assert html =~ "evil"
    end

    test "a list of maps stored under a file field renders instead of raising" do
      # `file` reaches the readonly catch-all clause (`readonly_value/1`),
      # and is the one registry type neither shape gate rejects.
      fields = [%{"type" => "file", "key" => "attachment", "label" => "Attachment"}]
      e = entity(fields)
      r = record(e, %{"attachment" => [%{"filename" => "a.pdf"}]})

      html =
        render_form(%{record: r, mode: :readonly, lang: "et", actor: nil, submit_label: nil})

      assert html =~ "Attachment"
      assert html =~ "a.pdf"
    end
  end

  describe "sanitize_values/2 (component-layer value-shape gate)" do
    # M2: `whitelist_known_fields/2` only filters submitted params by KEY —
    # it has no opinion on the SHAPE of the value under a known key, and
    # `FormBuilder.validate_type/2`'s catch-all accepts any term for types
    # it doesn't special-case. Without `sanitize_values/2`, a crafted
    # "autosave"/"submit" payload could carry a map (or any other
    # non-scalar term) as e.g. a `text` field's value straight into
    # `record.data`, where both render paths (`readonly_text/1`'s
    # `to_string/1`, the edit form's bare `{@value}` inside `<textarea>`)
    # raise `Protocol.UndefinedError` for every subsequent viewer — a
    # stored, client-authored DoS. `sanitize_values/2` is exposed as `def`
    # (not `defp`) specifically so this is testable without a database —
    # every path through `persist_data/3` needs one (`EntityData.changeset/2`
    # itself hits the DB for entity/parent lookups), so this is the only
    # DB-free way to exercise the sanitizer's per-type rules directly. See
    # `live_data_form_integration_test.exs` for the DB-backed end-to-end
    # version (crafted autosave -> nothing bad persisted, both renders
    # stay alive) and `entity_data_changeset_test.exs` for the
    # changeset-layer half of this fix.

    test "a map value for a text field is dropped" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]

      assert LiveDataForm.sanitize_values(%{"name" => %{"evil" => "map"}}, fields) == %{}
    end

    test "a map value for a textarea field is dropped" do
      fields = [%{"type" => "textarea", "key" => "notes", "label" => "Notes"}]

      assert LiveDataForm.sanitize_values(%{"notes" => %{"evil" => "map"}}, fields) == %{}
    end

    test "a list-of-maps value for a text field is dropped" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]

      assert LiveDataForm.sanitize_values(%{"name" => [%{"evil" => "map"}]}, fields) == %{}
    end

    test "a normal string value for a text field passes through" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]

      assert LiveDataForm.sanitize_values(%{"name" => "Jaan"}, fields) == %{"name" => "Jaan"}
    end

    test "a nil value for a text field passes through" do
      fields = [%{"type" => "text", "key" => "name", "label" => "Name"}]

      assert LiveDataForm.sanitize_values(%{"name" => nil}, fields) == %{"name" => nil}
    end

    test "a numeric string value for a number field passes through" do
      fields = [%{"type" => "number", "key" => "qty", "label" => "Quantity"}]

      assert LiveDataForm.sanitize_values(%{"qty" => "5"}, fields) == %{"qty" => "5"}
    end

    test "a real number value for a number field passes through" do
      fields = [%{"type" => "number", "key" => "qty", "label" => "Quantity"}]

      assert LiveDataForm.sanitize_values(%{"qty" => 5}, fields) == %{"qty" => 5}
    end

    test "a map value for a number field is dropped" do
      fields = [%{"type" => "number", "key" => "qty", "label" => "Quantity"}]

      assert LiveDataForm.sanitize_values(%{"qty" => %{"evil" => "map"}}, fields) == %{}
    end

    test "boolean-ish string and real boolean values for a boolean field pass through" do
      fields = [%{"type" => "boolean", "key" => "active", "label" => "Active"}]

      assert LiveDataForm.sanitize_values(%{"active" => "true"}, fields) == %{"active" => "true"}
      assert LiveDataForm.sanitize_values(%{"active" => false}, fields) == %{"active" => false}
    end

    test "a map value for a boolean field is dropped" do
      fields = [%{"type" => "boolean", "key" => "active", "label" => "Active"}]

      assert LiveDataForm.sanitize_values(%{"active" => %{"evil" => "map"}}, fields) == %{}
    end

    test "a list of strings for a checkbox field passes through unchanged" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      assert LiveDataForm.sanitize_values(%{"tools" => ["Hammer", "Drill"]}, fields) ==
               %{"tools" => ["Hammer", "Drill"]}
    end

    test "an empty list for a checkbox field passes through unchanged (clearing the field)" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      assert LiveDataForm.sanitize_values(%{"tools" => []}, fields) == %{"tools" => []}
    end

    test "a list-of-maps value for a checkbox field drops only the non-binary elements" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      result = LiveDataForm.sanitize_values(%{"tools" => [%{"evil" => "map"}, "Hammer"]}, fields)

      assert result == %{"tools" => ["Hammer"]}
    end

    test "a scalar (non-list) value for a checkbox field is dropped entirely" do
      fields = [
        %{"type" => "checkbox", "key" => "tools", "label" => "Tools", "options" => ["Hammer"]}
      ]

      assert LiveDataForm.sanitize_values(%{"tools" => "Hammer"}, fields) == %{}
    end

    test "any value submitted under a heading field's key is dropped" do
      fields = [%{"type" => "heading", "key" => "sec", "label" => "Section"}]

      assert LiveDataForm.sanitize_values(%{"sec" => "anything"}, fields) == %{}
      assert LiveDataForm.sanitize_values(%{"sec" => %{"evil" => "map"}}, fields) == %{}
    end

    test "select/radio accept a scalar value and drop a map value" do
      fields = [
        %{"type" => "radio", "key" => "color", "label" => "Color", "options" => ["Red", "Blue"]}
      ]

      assert LiveDataForm.sanitize_values(%{"color" => "Red"}, fields) == %{"color" => "Red"}
      assert LiveDataForm.sanitize_values(%{"color" => %{"evil" => "map"}}, fields) == %{}
    end

    test "any value submitted under a file field's key is dropped" do
      # `file` renders a placeholder, never a submittable input, so a
      # value arriving under its key can only be crafted. It used to fall
      # through the catch-all into `record.data`, where both render
      # surfaces index or stringify it — `FormBuilder.build_field/3`'s
      # `file["filename"]` and this module's `readonly_value/1` — which is
      # the same stored-DoS the scalar types above are protected from.
      fields = [%{"type" => "file", "key" => "attachment", "label" => "Attachment"}]

      assert LiveDataForm.sanitize_values(%{"attachment" => ["a.pdf"]}, fields) == %{}
      assert LiveDataForm.sanitize_values(%{"attachment" => %{"evil" => "map"}}, fields) == %{}
      assert LiveDataForm.sanitize_values(%{"attachment" => "a.pdf"}, fields) == %{}
    end

    test "relation values pass as a string or a list of strings; other shapes drop" do
      # What the picker's inputs submit. Whether the uuids are live records
      # of the target is EntityData.changeset/2's check, not this gate's.
      fields = [%{"type" => "relation", "key" => "grades", "label" => "Grades"}]
      uuid = Ecto.UUID.generate()

      assert LiveDataForm.sanitize_values(%{"grades" => uuid}, fields) == %{"grades" => uuid}

      assert LiveDataForm.sanitize_values(%{"grades" => ["", uuid]}, fields) ==
               %{"grades" => ["", uuid]}

      assert LiveDataForm.sanitize_values(%{"grades" => nil}, fields) == %{"grades" => nil}
      assert LiveDataForm.sanitize_values(%{"grades" => %{"evil" => "map"}}, fields) == %{}
      assert LiveDataForm.sanitize_values(%{"grades" => [%{"evil" => "map"}]}, fields) == %{}
      assert LiveDataForm.sanitize_values(%{"grades" => 42}, fields) == %{}
    end

    test "image/video values ride the scalar path: strings pass, shapes drop" do
      # Real field types since 2026-08-18 — the value is a storage file
      # uuid string; content validity is EntityData.validate_media_field's
      # job, this gate only rejects render-crashing shapes.
      for type <- ~w(image video) do
        fields = [%{"type" => type, "key" => "media", "label" => "Media"}]

        uuid = Ecto.UUID.generate()
        assert LiveDataForm.sanitize_values(%{"media" => uuid}, fields) == %{"media" => uuid}
        assert LiveDataForm.sanitize_values(%{"media" => %{"evil" => "map"}}, fields) == %{}
        assert LiveDataForm.sanitize_values(%{"media" => ["list"]}, fields) == %{}
      end
    end

    test "a mixed payload only drops the offending key, keeping the rest" do
      fields = [
        %{"type" => "text", "key" => "name", "label" => "Name"},
        %{"type" => "number", "key" => "qty", "label" => "Quantity"}
      ]

      result =
        LiveDataForm.sanitize_values(%{"name" => %{"evil" => "map"}, "qty" => "5"}, fields)

      assert result == %{"qty" => "5"}
    end
  end

  describe "extract_data_params/1 (m2 — non-map payload guard)" do
    # `handle_event/3`'s "autosave"/"submit" clauses match
    # `%{"phoenix_kit_entity_data" => data_params}` — that only constrains
    # the OUTER payload to be a map with that key, not the type of
    # `data_params` itself, nor of whatever's under its "data" key. Before
    # this fix, `Map.get(data_params, "data", %{})` raised `BadMapError`
    # for a non-map `data_params` (crashing the whole LiveView process,
    # not just this component), and even a well-formed `data_params` with
    # a non-map "data" value (e.g. a list) sailed through to
    # `normalize_absent_checkboxes/2`, which crashed the same way via
    # `Map.put_new/3`. `extract_data_params/1` is exposed as `def` (not
    # `defp`) for the same reason `sanitize_values/2` is — reaching it via
    # `handle_event/3` needs `mode: :edit`, which unconditionally ends at
    # `EntityData.update/3` (a live database), so this is the only DB-free
    # way to test the "data" shape normalization directly. See
    # `live_data_form_integration_test.exs` for the DB-backed end-to-end
    # version (both crafted payloads through `handle_event/3` itself —
    # no crash, no write).
    test "a normal map payload's data is returned unchanged" do
      assert LiveDataForm.extract_data_params(%{"data" => %{"name" => "Jaan"}}) ==
               {:ok, %{"name" => "Jaan"}}
    end

    test "a missing \"data\" key is a legitimate empty payload" do
      assert LiveDataForm.extract_data_params(%{}) == {:ok, %{}}
    end

    # Present-but-wrong-shape is :malformed, NOT an empty payload: an empty
    # payload means "every checkbox unticked" to normalize_absent_checkboxes/2,
    # so normalizing garbage down to %{} silently wiped stored checkbox values —
    # the exact data loss the integration tests forbid.
    test "a list \"data\" value is malformed, not an empty payload" do
      assert LiveDataForm.extract_data_params(%{"data" => ["a", "b"]}) == :malformed
    end

    test "a string \"data\" value is malformed, not an empty payload" do
      assert LiveDataForm.extract_data_params(%{"data" => "not-a-map"}) == :malformed
    end

    test "an explicit nil \"data\" value is malformed, not an empty payload" do
      assert LiveDataForm.extract_data_params(%{"data" => nil}) == :malformed
    end
  end
end
