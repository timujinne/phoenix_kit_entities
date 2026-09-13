defmodule PhoenixKitEntities.Components.LiveDataForm do
  @moduledoc """
  Embeddable `LiveComponent` for viewing/editing a single `EntityData`
  record's custom fields — without the admin `DataForm` LiveView's parent
  picker, status control, presence/locking, or multilang tabs.

  The host LiveView owns everything outside the fields themselves:

  - Loading `record` (an `%EntityData{}`) — **expected to arrive with its
    `:entity` association preloaded**. When it is, this component reuses
    it and never touches the database — `:readonly` render is always
    DB-free, and so is the initial `:edit` render as long as `lang` is
    `nil` (a non-nil `lang` makes `FormBuilder.build_fields/3` do one
    cacheable `Multilang`/settings read; see the `lang` attribute below).
    When `:entity` isn't preloaded, it's instead loaded via
    `PhoenixKitEntities.get_entity!/2` (one query per `update/2`, unless
    the entity was already resolved for the same `entity_uuid` on a
    previous update) — a correctness fallback, not the intended calling
    convention.
  - PubSub — this component neither subscribes nor publishes.
    `PhoenixKitEntities.EntityData.update/3` already broadcasts changes.
  - `record.status` — autosave never changes it; a draft record stays a
    draft, a published one stays published.
  - Guarding who can persist — `handle_event/3` only runs the
    autosave/submit path when `mode == :edit`; every other mode silently
    ignores both events. This isn't just UI polish: a `LiveComponent`'s
    `handle_event/3` is reachable for any event it defines via the
    component's `cid`, independent of what the rendered template actually
    wires up, so a non-`:edit` instance would otherwise still accept a
    crafted "autosave"/"submit" push and persist attacker-controlled data
    into a record the UI is displaying as read-only.
  - `render/1` mirrors the same fail-closed rule: only `mode == :edit`
    renders the live, autosaving form. Every other value — `:readonly`,
    anything else, or `mode` omitted entirely (a caller bug) — renders
    the static readonly view. The alternative (rendering the form
    whenever `mode` isn't literally `:readonly`) would let a forgotten
    `mode` produce a form that *looks* editable while `handle_event/3`'s
    own guard silently drops everything typed into it.
  - The `mode == :edit` guard above is a *process-level* check — it says
    nothing about whether the record ITSELF has moved on since this
    particular component instance last read it. Two browser tabs can
    both hold a live `:edit` instance of the same record; if one tab
    submits (moving the record to, say, `"published"`) and the other's
    still-pending autosave lands afterwards, `mode == :edit` is
    satisfied in both — the second tab genuinely IS in edit mode, it's
    just editing a record that has since moved on. Closing that
    *status-transition* race — NOT general concurrent-edit/optimistic
    locking, see the `persist_statuses` attribute's own doc for the
    distinction — is what `persist_statuses` (below) is for: it's
    optional (`nil` by default, matching every caller before it
    existed) precisely because it needs the host LiveView to state
    which statuses this instance is allowed to write into.
  - Required-field completeness — **incremental autosave is guaranteed
    only for entities without required fields; entities with required
    fields save all-or-nothing per attempt, by design**. Every save runs
    the merged data through
    `PhoenixKitEntities.FormBuilder.validate_data/2` on a best-effort
    basis (for type coercion — number strings, URL normalization — never
    as a hard gate: see `coerce_or_pass_through/3`). *However*,
    `EntityData.update/3` → `EntityData.changeset/2` runs its own,
    unconditional required-field check across the **entire** entity on
    every single save, independent of `FormBuilder` and deliberately left
    untouched here — relaxing it would also affect the admin `DataForm`
    and the public entity form, which both rely on it staying strict. In
    practice: for an entity with required fields, an autosave attempt
    while any required field is still empty logs an error and keeps the
    previous `record` unpersisted, exactly like any other save rejection;
    filling in the last required field then persists everything typed
    before it in one shot (thanks to merging over `record.data`). Entities
    with no required fields autosave incrementally with no such gap.
    Checking whether a record is "complete enough" to submit is the
    parent's responsibility either way.

  ## Usage

      <.live_component
        module={PhoenixKitEntities.Components.LiveDataForm}
        id={"survey-" <> record.uuid}
        record={record}
        mode={:edit}
        lang="et"
        actor={@current_user}
        submit_label={gettext("Kinnitan")}
      />

  ## Attributes

  - `record` (required) — the `%PhoenixKitEntities.EntityData{}` being
    displayed or edited. Preload its `:entity` association before passing
    it in — that's what keeps this component DB-free to render; see
    "The host LiveView owns" above.
  - `mode` (required) — `:edit` renders a live, autosaving form. Any
    other value renders static "label: value" output with no inputs;
    this includes `:readonly` (the intended non-editing value) but also
    a caller bug that omits `mode` altogether — the component fails
    closed to the safe, non-interactive view rather than rendering an
    editable-looking form that silently drops every edit.
  - `lang` (optional, defaults to `nil` — safe to omit entirely) — locale
    passed straight through to `PhoenixKitEntities.FormBuilder.build_fields/3`
    as `lang_code` (and to entity loading, when the entity isn't already
    preloaded). In `:edit` mode this drives `FormBuilder`'s own field-level
    "translations" resolution (labels + option text; see `FormBuilder`'s
    moduledoc for the display-only contract). The static `:readonly` view
    resolves the same `field["translations"]` map directly via
    `FormBuilder.translated_label/2` / `translated_option_label/3` — a
    stored value (e.g. `"Must"`) always renders its translation for
    `lang` (e.g. "Чёрный"), falling back to the original label/option text
    whenever `lang` is `nil` or no translation entry exists. Either way,
    the value actually persisted in `record.data` is never touched. This
    component is one of the surfaces that DOES resolve field-level
    `"translations"` — see `FormBuilder`'s moduledoc, "Which surfaces
    resolve this", for the full list of which callers do and don't.
  - `actor` (optional, defaults to `nil` — safe to omit entirely) — the
    acting user (a struct with a `:uuid` field) or `nil`. Threaded through
    to `EntityData.update/3` as `actor_uuid:` for activity logging.
  - `submit_label` (optional, defaults to `nil` — safe to omit entirely) —
    `nil` hides the submit button entirely; any other string renders it
    as the button's text.
  - `persist_statuses` (optional, defaults to `nil` — safe to omit
    entirely) — a list of status strings (e.g. `["draft"]`), threaded
    through to `EntityData.update/3` as `require_status:` on both the
    autosave and submit persist paths. **Recommended for any host
    LiveView that can have more than one live `:edit` instance of the
    same record open at once** (e.g. two browser tabs/sessions) — see
    the cross-session race note above. `nil` (the default) reproduces
    the exact pre-`persist_statuses` behavior: no status check, save
    proceeds regardless of the record's current status. When set, a
    save whose freshly-read record status has moved outside the list
    fails exactly like any other rejected save (see "Messages sent to
    the parent" below) — logged at `debug` (not `error`; the guard
    doing its job isn't a failure), previous `record` kept, no
    `:saved`/`:submitted` message sent. Be precise about what this
    guards: it's a **status-transition** check, not optimistic locking
    on `data`. Two sessions both legitimately editing the same record
    while its status stays within `persist_statuses` (e.g. both still
    "draft") are NOT protected from each other — whichever save lands
    last still wins, silently overwriting the other's edits. Closing
    *that* race (concurrent edits within the same allowed status) is
    out of scope here; this attribute only stops a save from landing
    once the record has moved to a status the caller didn't allow.

  ## Messages sent to the parent

  - `{:live_data_form, :saved, updated_record}` — after a successful
    autosave (fired on every change, debounced 500ms).
  - `{:live_data_form, :submitted, updated_record}` — after the submit
    button is pressed. Submit persists the params `phx-submit` just sent
    (the same merge-over-`record.data` path as autosave, so the last
    edit is never lost to the debounce window) and only sends this
    message once that save succeeds — `updated_record` reflects it. The
    component never changes `status` itself — the parent decides what
    "submitted" means for its workflow.

  On a failed save (autosave or submit) the component logs the error and
  keeps the previous `record` — it never crashes the LiveView, and on a
  failed submit specifically it does not send `:submitted` (the parent
  must not treat unpersisted data as agreed-upon).

  Ordering caveat: a debounced autosave that was already in flight when
  Submit was pressed can still land afterwards, so the parent may see
  `{:live_data_form, :saved, _}` arrive *after*
  `{:live_data_form, :submitted, _}` for the same record. Both messages
  carry the freshly-persisted record, so this is harmless as long as the
  parent treats each message as "here is the current server copy" rather
  than assuming `:submitted` is always the last word — read the record's
  own `status`/fields rather than inferring lifecycle order from message
  arrival, the way the host app (andi) does. This is a *single*
  component instance racing its own two persist paths — distinct from
  the *cross-session* race (a second tab's stale `:edit` instance of the
  same record) that `persist_statuses` guards against; the two are
  independent and both worth being aware of.
  """

  use PhoenixKitWeb, :live_component
  # Override the backend `use PhoenixKitWeb, :live_component` wires by
  # default (PhoenixKitWeb.Gettext, core's own — unreachable from this
  # package's `mix gettext.extract`). See lib/phoenix_kit_entities/gettext.ex.
  use Gettext, backend: PhoenixKitEntities.Gettext

  require Logger

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FormBuilder

  # Field types whose stored value must be a single JSON scalar (or
  # absent) — see `sanitize_values/2` below. `number` and `boolean` are
  # scalar too, but narrower (binary|number, and binary|boolean
  # respectively — see their own `sanitize_field_value/2` clauses), so
  # they're kept out of this group rather than widening it to "whatever
  # the loosest member tolerates".
  # image/video ride the scalar path: their value is a storage file
  # uuid string (EntityData.validate_media_field is the shape gate).
  @scalar_value_types ~w(text textarea email url rich_text date select radio image video)

  @impl true
  def update(assigns, socket) do
    entity = resolve_entity(assigns.record, assigns[:lang], socket)

    socket =
      socket
      |> assign(assigns)
      # `record` and `mode` are required — omitting them is a caller bug,
      # and should crash. `lang`/`actor`/`submit_label` are documented as
      # optional (safe to omit entirely, not just pass as explicit nil);
      # without these defaults, an omitted key stays absent from
      # `socket.assigns` (`assign/2` only sets keys actually present in
      # `assigns`) and `render/1`'s `@lang`/`@submit_label` raise `KeyError`.
      |> assign_new(:lang, fn -> nil end)
      |> assign_new(:actor, fn -> nil end)
      |> assign_new(:submit_label, fn -> nil end)
      |> assign_new(:persist_statuses, fn -> nil end)
      |> assign(:entity, entity)
      |> assign_form()

    {:ok, socket}
  end

  # Reuses the preloaded association when the caller already loaded it,
  # falls back to the cached assign from a previous `update/2` for the
  # same entity (autosave re-renders shouldn't re-query every keystroke),
  # and only hits the database as a last resort.
  defp resolve_entity(%EntityData{entity_uuid: entity_uuid} = record, lang, socket) do
    cond do
      Ecto.assoc_loaded?(record.entity) ->
        record.entity

      match?(%{entity: %{uuid: ^entity_uuid}}, socket.assigns) ->
        socket.assigns.entity

      true ->
        Entities.get_entity!(entity_uuid, lang: lang)
    end
  end

  # Deliberately NOT `EntityData.change/2` — that goes through the full
  # `changeset/2` (entity lookup, rich-text sanitization, cross-field
  # validation), all of which hit the database. This component only needs
  # a display/param-shape changeset, so a bare structural changeset is
  # enough and keeps rendering (and `:readonly` mode entirely) DB-free.
  defp assign_form(socket) do
    changeset = Ecto.Changeset.change(socket.assigns.record)
    assign(socket, :form, to_form(changeset, as: :phoenix_kit_entity_data))
  end

  # SECURITY: every clause below that actually persists (`do_autosave/2`,
  # `do_submit/2`) is guarded on `mode == :edit`. `handle_event/3` is
  # reachable for ANY event this module defines regardless of what the
  # rendered HTML wires up — LiveView dispatches a component event by
  # `cid` alone, so an authenticated client can push a crafted "autosave"
  # or "submit" payload straight at a `:readonly` instance's cid from the
  # browser console (devtools `pushEventTo`-style), even though the
  # `:readonly` template never renders a `<form>` with these bindings.
  # Without the guard that would silently persist attacker-controlled
  # data into a record the UI is showing as read-only — e.g. an already
  # "Kinnitatud" (submitted) survey whose status never changes, so the
  # tampering is invisible to whoever reviews it next. The fallback
  # clause at the bottom makes both events inert in any non-`:edit` mode.
  #
  # SECURITY (m2): the pattern `%{"phoenix_kit_entity_data" => data_params}`
  # only constrains the OUTER payload to be a map with that key — it says
  # nothing about the TYPE of `data_params` itself. A crafted push (e.g.
  # `%{"phoenix_kit_entity_data" => "not-a-map"}`) used to match this
  # clause and then crash inside `Map.get(data_params, "data", %{})`
  # (`Map.get/3` raises `BadMapError` for a non-map first argument) — an
  # unhandled exception in `handle_event/3` crashes the whole LiveView
  # process, not just this component, taking down every other component
  # on the same page for that user. The `when is_map(data_params)` guard
  # below makes a non-map `data_params` fall through to the dedicated
  # malformed-payload clause instead, which does not write. Malformed is
  # NOT folded into the absent-key path: absent means "every checkbox
  # unticked" and must flow as an empty payload, while an empty payload
  # built from garbage wipes checkbox data.
  @impl true
  def handle_event(
        "autosave",
        %{"phoenix_kit_entity_data" => data_params},
        %{assigns: %{mode: :edit}} = socket
      )
      when is_map(data_params) do
    case extract_data_params(data_params) do
      {:ok, data} ->
        {:noreply, do_autosave(socket, data)}

      :malformed ->
        Logger.warning("LiveDataForm ignored autosave: \"data\" is not a map")
        {:noreply, socket}
    end
  end

  # Key PRESENT but not a map: a crafted push, not a browser form — no real
  # form serializes its fields to a bare string. Distinct from the absent-key
  # clause below on purpose: absent means "every checkbox unticked" and MUST
  # flow as an empty payload, while malformed must not write at all —
  # degrading it to the same empty payload wiped every checkbox field, which
  # is exactly the data loss the integration tests forbid.
  def handle_event(
        "autosave",
        %{"phoenix_kit_entity_data" => _malformed},
        %{assigns: %{mode: :edit}} = socket
      ) do
    Logger.warning("LiveDataForm ignored autosave: payload is not a map")
    {:noreply, socket}
  end

  # Mirrors the "submit" fallback clause below rather than no-op'ing: a
  # `phx-change` from a form where every input is an unticked checkbox (or
  # a checkbox group plus only `heading` fields) submits no
  # `"phoenix_kit_entity_data"` key at all — there's nothing else in the
  # payload to carry it. Treating that as "nothing changed" would silently
  # ignore exactly the case `normalize_absent_checkboxes/2` exists to
  # handle (unticking the last box). An empty map still flows through the
  # same merge/coercion/persist path as any other autosave. Malformed
  # payloads do NOT land here — they have their own inert clause above.
  def handle_event("autosave", _params, %{assigns: %{mode: :edit}} = socket),
    do: {:noreply, do_autosave(socket, %{})}

  # Submit persists the params `phx-submit` just sent — the same
  # merge-over-`record.data` path as autosave — rather than trusting
  # whatever autosave last managed to save. `phx-submit` carries the
  # form's full, current values regardless of the 500ms debounce window,
  # so pressing Submit means "the client agreed to exactly this state";
  # relying solely on a possibly-still-pending autosave would risk
  # silently dropping the last edit. Only sends `:submitted` — and only
  # the freshly-updated record — on a successful save; a failed save
  # logs and does not notify the parent, since it must not treat
  # unpersisted data as agreed-upon.
  #
  # Same `when is_map(data_params)` guard and malformed-clause split as
  # "autosave" above, for the same reasons (m2).
  def handle_event(
        "submit",
        %{"phoenix_kit_entity_data" => data_params},
        %{assigns: %{mode: :edit}} = socket
      )
      when is_map(data_params) do
    case extract_data_params(data_params) do
      {:ok, data} ->
        {:noreply, do_submit(socket, data)}

      :malformed ->
        Logger.warning("LiveDataForm ignored submit: \"data\" is not a map")
        {:noreply, socket}
    end
  end

  # Same malformed-vs-absent split as autosave, same reason.
  def handle_event(
        "submit",
        %{"phoenix_kit_entity_data" => _malformed},
        %{assigns: %{mode: :edit}} = socket
      ) do
    Logger.warning("LiveDataForm ignored submit: payload is not a map")
    {:noreply, socket}
  end

  def handle_event("submit", _params, %{assigns: %{mode: :edit}} = socket),
    do: {:noreply, do_submit(socket, %{})}

  # Catch-all for both events in any mode other than `:edit` (`:readonly`
  # today, and any future mode). Deliberately silent/inert rather than
  # crashing or `Logger.warning` — a legitimate client can still have a
  # stray debounced autosave in flight around a mode transition, so this
  # isn't necessarily an attack every time it fires; `debug` is enough to
  # trace it when needed without adding log noise.
  def handle_event(event, _params, socket) when event in ["autosave", "submit"] do
    Logger.debug(
      "LiveDataForm ignored #{event}: mode is #{inspect(socket.assigns[:mode])}, not :edit"
    )

    {:noreply, socket}
  end

  # SECURITY (m2, continued): `data_params["data"]` being present but not
  # itself a map (e.g. `%{"phoenix_kit_entity_data" => %{"data" => ["a",
  # "b"]}}` — a list, not the expected key/value payload) used to reach
  # `normalize_absent_checkboxes/2` unchanged and crash there:
  # `Map.put_new(list, key, [])` raises `BadMapError` the same way
  # `Map.get/3` did for the outer payload above. `Map.get(data_params,
  # "data", %{})` alone doesn't catch this — the default only applies when
  # the *key* is missing, not when its value has the wrong shape. This
  # normalizes any non-map "data" value (a list, a string, a number, even
  # an explicit `null`/`nil`) down to `%{}`, the same empty-payload shape
  # every other malformed-input path in this module already degrades to.
  #
  # `def`, not `defp`, for the same testability reason as
  # `sanitize_values/2` above: reaching this through `handle_event/3`
  # needs `mode: :edit`, and that path unconditionally ends at
  # `EntityData.update/3` (a live database), so this is the only DB-free
  # way to test the "data" shape normalization directly. `@doc false`:
  # not part of this component's documented usage contract.
  @doc false
  def extract_data_params(data_params) do
    case Map.fetch(data_params, "data") do
      {:ok, %{} = data} -> {:ok, data}
      # Absent is legitimate (a payload carrying only non-data params);
      # present-but-wrong-shape (a list, a string, an explicit null) is a
      # crafted push and must not become a write.
      :error -> {:ok, %{}}
      {:ok, _malformed} -> :malformed
    end
  end

  # Merges the submitted field values over the record's existing (flat)
  # data map and persists them, preserving `status` untouched. Never
  # raises on failure — logs and keeps the previous `record` so the form
  # stays usable.
  defp do_autosave(socket, raw_data_params) do
    case persist_data(socket, raw_data_params, "autosave") do
      {:ok, updated_record} ->
        send(self(), {:live_data_form, :saved, updated_record})

        socket
        |> assign(:record, updated_record)
        |> assign_form()

      :error ->
        socket
    end
  end

  defp do_submit(socket, raw_data_params) do
    case persist_data(socket, raw_data_params, "submit") do
      {:ok, updated_record} ->
        send(self(), {:live_data_form, :submitted, updated_record})

        socket
        |> assign(:record, updated_record)
        |> assign_form()

      :error ->
        socket
    end
  end

  defp persist_data(socket, raw_data_params, log_context) do
    entity = socket.assigns.entity
    record = socket.assigns.record
    fields_definition = entity.fields_definition || []

    merged_data =
      fields_definition
      |> normalize_absent_checkboxes(raw_data_params)
      |> then(&FormBuilder.merge_other_params(fields_definition, &1))
      |> whitelist_known_fields(fields_definition)
      |> sanitize_values(fields_definition)
      |> then(&Map.merge(record.data || %{}, &1))

    data_to_persist = coerce_or_pass_through(entity, merged_data, log_context)

    update_opts =
      actor_opts(socket) ++ activity_log_opts(log_context) ++ require_status_opts(socket)

    case EntityData.update(record, %{"data" => data_to_persist}, update_opts) do
      {:ok, updated_record} ->
        {:ok, updated_record}

      {:error, :status_mismatch} ->
        # `persist_statuses` was set and the freshly-read row's status is
        # no longer in it — some other session moved this record on
        # (e.g. submitted/published it) since this instance last read
        # it. `debug`, not `error`: this is the guard doing exactly its
        # job, not a failure. No row/activity/PubSub touched by
        # `EntityData.update/3` itself; falling through to `:error` here
        # keeps the existing behavior of not sending :saved/:submitted
        # and leaving the previous `record` in place.
        Logger.debug(
          "LiveDataForm #{log_context} skipped: record #{inspect(record.uuid)} status no " <>
            "longer in persist_statuses (entity_uuid=#{inspect(entity.uuid)})"
        )

        :error

      # MINOR-5 (2026-09-11 review): a bare `{:error, changeset}` catch-all
      # here would also match `EntityData.update/3`'s `{:error, :locked_key}`
      # (`Managed.validate_data_mutation/4`) and raise `KeyError` calling
      # `.errors` on an atom instead of a changeset. Unreachable today —
      # this call only ever sends `%{"data" => ...}`, and the merge in
      # this function preserves the record's own multilang/slug data
      # untouched — but the split costs nothing and this is exactly the
      # assumption the guard's own comments warn will eventually break.
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error(
          "LiveDataForm #{log_context} failed: #{inspect(changeset.errors)} " <>
            "(entity_uuid=#{inspect(entity.uuid)} record_uuid=#{inspect(record.uuid)})"
        )

        :error

      {:error, other} ->
        Logger.error(
          "LiveDataForm #{log_context} failed: #{inspect(other)} " <>
            "(entity_uuid=#{inspect(entity.uuid)} record_uuid=#{inspect(record.uuid)})"
        )

        :error
    end
  end

  defp require_status_opts(socket) do
    case socket.assigns[:persist_statuses] do
      nil -> []
      statuses -> [require_status: statuses]
    end
  end

  # Drops any submitted key that isn't a real field on this entity —
  # companion `<key>__other` keys are already gone by this point
  # (`merge_other_params/2` drops them), so this only needs to guard
  # against keys that were never part of the form at all (a crafted
  # param, or a stale key from a since-changed entity definition).
  # Legacy keys already stored in `record.data` are unaffected — they
  # survive via the `Map.merge/2` in the caller regardless of whether
  # they're in `fields_definition` today; this only filters what's
  # newly incoming.
  defp whitelist_known_fields(params, fields_definition) do
    known_keys = MapSet.new(fields_definition, & &1["key"])
    Map.filter(params, fn {key, _value} -> MapSet.member?(known_keys, key) end)
  end

  # SECURITY: `whitelist_known_fields/2` above only filters by KEY — it
  # says nothing about the SHAPE of the value under a known key.
  # `FormBuilder.validate_type/2` has a catch-all clause
  # (`defp validate_type(_field, value), do: {:ok, value}`) that accepts
  # ANY term for the types it doesn't special-case, `text`/`textarea`
  # included, and `coerce_or_pass_through/3` only ever uses that result
  # for best-effort coercion, never as a gate. So nothing between a
  # crafted "autosave"/"submit" payload and `record.data` stops a map (or
  # a list of maps, or any other non-scalar term) from landing as a text
  # field's value.
  #
  # Once that happens, every surface that renders the value breaks: the
  # readonly view calls `to_string/1` on it (`readonly_value/1`,
  # `readonly_text/1` below — both raise `Protocol.UndefinedError`, a bare
  # map has no `String.Chars` implementation), and the edit form
  # interpolates it directly inside `<textarea>{@value}</textarea>`
  # (`FormBuilder.build_field/3`), which raises the same way via
  # `Phoenix.HTML.Safe`. Either crashes rendering for every subsequent
  # viewer of the record — a client-authored, un-fixable-without-a-DB-edit
  # stored DoS. This function is the value-SHAPE gate that closes that
  # hole at the point data enters this component, ahead of
  # `EntityData.changeset/2`'s own final-word validation (see
  # `PhoenixKitEntities.EntityData`'s `validate_field_type/3` — the
  # `text_like_shape?/1` guard inside it — for the changeset-layer half of
  # this fix; this component's sanitizer is defense-in-depth, not a
  # replacement for that final gate).
  #
  # Runs on the already key-whitelisted params (`whitelist_known_fields/2`
  # above), so every key here is guaranteed to have a matching field
  # definition — `sanitize_field_value/2` doesn't need a "no such field"
  # fallback. A value that doesn't fit its field's shape is DROPPED
  # (never coerced/truncated) — the previous, already-valid value in
  # `record.data` survives the `Map.merge/2` in the caller untouched,
  # same as any other key this function doesn't return.
  #
  # `def`, not `defp`: exposed specifically so it has direct, DB-free unit
  # test coverage (`live_data_form_test.exs`). Every other path through
  # `persist_data/3` needs a live database — `EntityData.changeset/2`
  # itself hits the DB for entity/parent lookups even before
  # `repo().update/1` runs — so this is the only way to test the
  # sanitizer's per-type rules without that dependency. `@doc false`: not
  # part of this component's documented usage contract (see the
  # moduledoc's "Usage" section); callers other than `persist_data/3` and
  # tests should not rely on it.
  @doc false
  def sanitize_values(params, fields_definition) do
    field_types = Map.new(fields_definition, fn field -> {field["key"], field["type"]} end)

    Enum.reduce(params, %{}, fn {key, value}, acc ->
      case sanitize_field_value(Map.get(field_types, key), value) do
        {:ok, sanitized} ->
          Map.put(acc, key, sanitized)

        :drop ->
          Logger.debug(
            "LiveDataForm dropped field #{inspect(key)}: value #{inspect(value)} has an " <>
              "invalid shape for field type #{inspect(Map.get(field_types, key))}"
          )

          acc
      end
    end)
  end

  # `heading` fields carry no data at all (see `FormBuilder.build_field/3`'s
  # heading clause — no input, not bound to the changeset) — any value
  # submitted under a heading's key is dropped unconditionally rather than
  # accumulating a meaningless entry in `record.data`.
  defp sanitize_field_value("heading", _value), do: :drop

  # `number`/`boolean` fields: real browser form submissions only ever
  # carry these as strings, but a crafted payload could carry the
  # already-coerced Elixir type directly (a real number, a real boolean)
  # — both are safe scalar shapes, so both are accepted. This function
  # only guards against shapes that would crash a render, never against
  # values that are merely the wrong scalar type or fail to parse —
  # `FormBuilder.validate_data/2` (best-effort) and
  # `EntityData.changeset/2` (final word) still separately enforce that
  # the *content* actually parses as a number / is a recognized boolean
  # token.
  defp sanitize_field_value("number", value) when is_binary(value) or is_number(value),
    do: {:ok, value}

  defp sanitize_field_value("number", _value), do: :drop

  defp sanitize_field_value("boolean", value) when is_binary(value) or is_boolean(value),
    do: {:ok, value}

  defp sanitize_field_value("boolean", _value), do: :drop

  defp sanitize_field_value(type, value)
       when type in @scalar_value_types and
              (is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)) do
    {:ok, value}
  end

  defp sanitize_field_value(type, _value) when type in @scalar_value_types, do: :drop

  # `checkbox` is the one legitimately list-shaped type reaching here — a
  # submitted value is either the real (possibly empty) list of ticked
  # option strings, or one with the `allow_other` sentinel already
  # resolved to free text by `FormBuilder.merge_other_params/2`; either
  # way every element must be a binary. A crafted list-of-maps collapses
  # to whatever binary entries (if any) survive, rather than reaching
  # storage; a non-list value is dropped outright — checkbox always
  # submits *some* list, even `[]`, once `normalize_absent_checkboxes/2`
  # has run.
  defp sanitize_field_value("checkbox", value) when is_list(value) do
    {:ok, Enum.filter(value, &is_binary/1)}
  end

  defp sanitize_field_value("checkbox", _value), do: :drop

  # `file`/`image`/`relation` render a placeholder here, never a real
  # submittable input (see `FormBuilder.build_field/3`'s clauses for them),
  # so a value arriving under one of their keys can only be crafted — there
  # is no legitimate submission to preserve. Dropping is also lossless for
  # a parent app that populates these out of band: a dropped key is simply
  # absent from the merge, so whatever `record.data` already holds survives
  # untouched.
  #
  # This closes the one registry type the rest of this function leaves to
  # the catch-all. `file` values ARE rendered — by the readonly catch-all
  # clause (`readonly_value/1`) and by `FormBuilder.build_field/3`'s `file`
  # clause, which indexes each list entry (`file["filename"]`) — so
  # "nothing stringifies them" was never true for `file`; see
  # `safe_string/1` below for the matching render-side guard that also
  # covers rows written before this clause existed.
  defp sanitize_field_value(type, _value) when type in ~w(file image relation), do: :drop

  # Every other/unrecognized field type passes through unchanged, same as
  # `FormBuilder.validate_type/2`'s own catch-all. A type outside
  # `FieldTypes.all/0` can only come from a hand-edited
  # `fields_definition`, and this component has no render clause that can
  # infer a safe shape for it; `safe_string/1` on the render side is what
  # keeps an unexpected value from crashing a page.
  defp sanitize_field_value(_type, value), do: {:ok, value}

  # Autosave fires on every change (debounced 500ms) — logging an
  # `entity_data.updated` activity row for each one would flood the
  # activity log for a user who's simply still typing. Submit is a
  # deliberate, one-time action and keeps the default (logged) behavior.
  defp activity_log_opts("autosave"), do: [activity_log: false]
  defp activity_log_opts(_log_context), do: []

  # `FormBuilder.validate_data/3` runs here WITHOUT `lang_code` — even
  # though `lang` is available on the socket — deliberately, not as an
  # oversight. Passing a non-nil `lang_code` that happens to differ from
  # `Multilang.primary_language/0` routes into `validate_data/3`'s
  # secondary-language branch, which treats the payload as translation
  # overrides and skips EVERY required-field check entirely. This
  # component's `record.data` is a flat, non-multilang map — there is no
  # "secondary language" for it — so always validating as the full/primary
  # path is the only correct choice; threading `lang` through here would
  # silently reopen exactly the required-field hole this call exists to
  # help close.
  #
  # Used for type coercion (e.g. number strings -> floats, URL
  # normalization) on a best-effort basis — never as a hard gate. Errors
  # (including a still-incomplete required field) are logged and merged
  # data is persisted as-is: `validate_data/3` validates the ENTIRE
  # entity on every call, so treating its errors as blocking would mean a
  # multi-field survey never saves ANY progress until every required
  # field is filled — defeating incremental autosave of a draft. The
  # final arbiter of what actually lands in the database is
  # `EntityData.changeset/2` inside `EntityData.update/3` above; a
  # rejection there still logs and keeps the previous `record`.
  defp coerce_or_pass_through(entity, merged_data, log_context) do
    case FormBuilder.validate_data(entity, merged_data) do
      {:ok, validated_data} ->
        # `validate_data/2` returns one entry per NON-heading field on the
        # entity, including fields never touched (as `nil`) — restricting
        # to keys already present in `merged_data` before merging avoids
        # writing brand-new explicit `null`s for fields nobody has filled
        # in yet, which would otherwise break a `Map.has_key?/2` "is this
        # field answered" check on the read side. Keys already present
        # (touched, even if previously "") still get their coerced value;
        # legacy keys outside the current `fields_definition` are
        # untouched either way since they never appear in `validated_data`.
        validated_data
        |> Map.take(Map.keys(merged_data))
        |> then(&Map.merge(merged_data, &1))

      {:error, errors} ->
        # `debug`, not `warning`: an incomplete required field mid-draft is
        # the expected, normal state of a form someone is still filling
        # out — autosave hits this on every debounced keystroke until the
        # last required field is filled, and a `warning` at that rate
        # floods the logs for something that isn't actually wrong.
        Logger.debug(
          "LiveDataForm #{log_context} data failed FormBuilder validation (persisting as-is): " <>
            "#{inspect(errors)} (entity_uuid=#{inspect(entity.uuid)})"
        )

        merged_data
    end
  end

  # A checkbox group with every box unticked submits no `[key][]` param at
  # all (browsers omit unchecked checkboxes; unlike `boolean`, `checkbox`
  # fields have no hidden fallback input) — without this, "uncheck
  # everything" would silently no-op against the shallow merge below
  # instead of clearing the field.
  defp normalize_absent_checkboxes(fields_definition, params) do
    Enum.reduce(fields_definition, params, fn
      %{"type" => "checkbox", "key" => key}, acc -> Map.put_new(acc, key, [])
      _field, acc -> acc
    end)
  end

  defp actor_opts(socket) do
    case socket.assigns[:actor] do
      %{uuid: uuid} when is_binary(uuid) -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # `id_prefix: @record.uuid || @id` — falls back to the component's own
  # `id` (always present, required by `live_component`) when `record.uuid`
  # is `nil` (a not-yet-persisted, in-memory `%EntityData{}` being built).
  # Without the fallback, every such instance would render field-wrapper
  # ids scoped to `nil`, so two of them on the same page would collide —
  # exactly the "Duplicate id found" failure `id_prefix` exists to avoid
  # (see `FormBuilder.build_fields/3`'s moduledoc).
  #
  # Matches ONLY `mode: :edit` explicitly — fail-closed. Every other
  # clause (below) renders the readonly view, including a caller bug that
  # omits `mode` entirely. The alternative (falling through to this
  # editable-looking form whenever `mode` isn't literally `:readonly`)
  # would pair badly with `handle_event/3`'s own `mode == :edit` guard:
  # a forgotten `mode` would render a form that LOOKS interactive but
  # silently drops every autosave/submit, which is worse than an
  # obviously-static readonly view.
  @impl true
  def render(%{mode: :edit} = assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-change="autosave"
        phx-submit="submit"
        phx-debounce="500"
        phx-target={@myself}
        class="space-y-6"
      >
        {FormBuilder.build_fields(@entity, @form,
          wrapper_class: "mb-4",
          lang_code: @lang,
          id_prefix: @record.uuid || @id
        )}

        <%= if @submit_label do %>
          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving…")}>
              {@submit_label}
            </button>
          </div>
        <% end %>
      </.form>
    </div>
    """
  end

  # Fail-closed default — `:readonly`, any other value, or `mode` missing
  # entirely all land here.
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for field <- @entity.fields_definition || [] do %>
        {readonly_field(field, @record.data || %{}, @lang)}
      <% end %>
    </div>
    """
  end

  # ── Readonly field rendering ─────────────────────────────────
  #
  # Every clause resolves its label through `FormBuilder.translated_label/2`
  # — same display-only "translations" contract as the editable form (see
  # `FormBuilder`'s moduledoc). `select`/`radio` additionally resolve their
  # STORED value through `FormBuilder.translated_option_label/3`: the value
  # itself (e.g. `"Must"`) stays canonical, only what's shown changes. A
  # value outside the field's `options` (an `allow_other` free-text answer)
  # has no translation entry to find, so `translated_option_label/3` falls
  # back to the raw value — exactly the desired "show as-is" behavior.

  defp readonly_field(%{"type" => "heading"} = field, _data, lang_code) do
    assigns = %{label: FormBuilder.translated_label(field, lang_code)}

    ~H"""
    <h3 class="text-base font-semibold border-b border-base-300 pb-1 mt-6 mb-2">
      {@label}
    </h3>
    """
  end

  defp readonly_field(%{"type" => "checkbox"} = field, data, lang_code) do
    display =
      data
      |> Map.get(field["key"])
      |> translate_option_values(field, lang_code)
      |> readonly_list()

    assigns = %{label: FormBuilder.translated_label(field, lang_code), display: display}

    ~H"""
    <div>
      <span class="font-semibold">{@label}:</span>
      <span>{@display}</span>
    </div>
    """
  end

  defp readonly_field(%{"type" => "textarea"} = field, data, lang_code) do
    assigns = %{
      label: FormBuilder.translated_label(field, lang_code),
      display: readonly_text(Map.get(data, field["key"]))
    }

    ~H"""
    <div>
      <div class="font-semibold">{@label}</div>
      <div class="whitespace-pre-wrap">{@display}</div>
    </div>
    """
  end

  defp readonly_field(%{"type" => "boolean"} = field, data, lang_code) do
    assigns = %{
      label: FormBuilder.translated_label(field, lang_code),
      display: readonly_boolean(Map.get(data, field["key"]))
    }

    ~H"""
    <div>
      <span class="font-semibold">{@label}:</span>
      <span>{@display}</span>
    </div>
    """
  end

  # `select`/`radio` are the other two option-bearing types (besides
  # `checkbox` above) — resolved via `translated_option_label/3` the same
  # way, just for a single stored value instead of a list. Must come
  # before the catch-all clause below, which has no option to translate.
  defp readonly_field(%{"type" => type} = field, data, lang_code)
       when type in ["select", "radio"] do
    raw_value = Map.get(data, field["key"])

    # `translated_option_label/3` falls back to the RAW stored value when it
    # finds no translation entry (the `allow_other` free-text case), so it
    # hands back whatever shape is in `data` — including a non-scalar term
    # from a row written before the write-side shape gates existed. Piping
    # it through `safe_string/1` keeps `{@display}` from raising the same
    # `Protocol.UndefinedError` the text clauses are already protected from.
    display =
      case raw_value do
        value when value in [nil, ""] -> dash()
        value -> safe_string(FormBuilder.translated_option_label(field, value, lang_code))
      end

    assigns = %{label: FormBuilder.translated_label(field, lang_code), display: display}

    ~H"""
    <div>
      <span class="font-semibold">{@label}:</span>
      <span>{@display}</span>
    </div>
    """
  end

  defp readonly_field(field, data, lang_code) do
    assigns = %{
      label: FormBuilder.translated_label(field, lang_code),
      display: readonly_value(Map.get(data, field["key"]))
    }

    ~H"""
    <div>
      <span class="font-semibold">{@label}:</span>
      <span>{@display}</span>
    </div>
    """
  end

  # Translates each value in an option list (`checkbox` field data) ahead
  # of `readonly_list/1` — a non-list value (`nil`, or any other stray
  # shape) passes through untouched so `readonly_list/1`'s own dash-vs-join
  # logic still applies unchanged.
  defp translate_option_values(values, field, lang_code) when is_list(values) do
    Enum.map(values, &FormBuilder.translated_option_label(field, &1, lang_code))
  end

  defp translate_option_values(other, _field, _lang_code), do: other

  defp readonly_list(nil), do: dash()
  defp readonly_list([]), do: dash()
  defp readonly_list(values) when is_list(values), do: Enum.map_join(values, ", ", &safe_string/1)
  defp readonly_list(_), do: dash()

  defp readonly_text(nil), do: dash()
  defp readonly_text(""), do: dash()
  defp readonly_text(value) when is_binary(value), do: value
  defp readonly_text(value), do: safe_string(value)

  defp readonly_boolean(nil), do: dash()
  defp readonly_boolean(value) when value in [true, "true", "1", 1], do: gettext("Yes")
  defp readonly_boolean(_value), do: gettext("No")

  defp readonly_value(nil), do: dash()
  defp readonly_value(""), do: dash()
  defp readonly_value(value) when is_list(value), do: readonly_list(value)
  defp readonly_value(value) when is_binary(value), do: value
  defp readonly_value(value), do: safe_string(value)

  # SECURITY: the last line of defence for the render side of the stored-DoS
  # this component's `sanitize_values/2` and `EntityData.changeset/2` guard
  # on the write side. Both of those only gate what lands in `data` FROM NOW
  # ON — a row poisoned before they existed, or written by a parent app
  # calling `EntityData` directly, still holds whatever term it holds, and
  # this readonly view is exactly where it gets rendered. `to_string/1` /
  # `Enum.join/2` raise `Protocol.UndefinedError` on a bare map (no
  # `String.Chars` implementation), which crashes rendering for every
  # subsequent viewer with no way out short of a manual DB edit. Nothing
  # displayed here is load-bearing enough to be worth a crash, so anything
  # without a `String.Chars` implementation degrades to `inspect/1` — the
  # same treatment `EntityData.stringify_invalid_option/1` and
  # `FormBuilder.stringify_invalid_option/1` already give their own
  # attacker-reachable interpolations.
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp safe_string(value), do: inspect(value)

  defp dash, do: gettext("—")
end
