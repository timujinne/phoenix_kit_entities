# PR #40 Review — Quality sweep: wrong assign key on the public form, credentials in Presence metas, mass assignment on save

**Reviewer:** Claude
**Date:** 2026-08-29
**Verdict:** Approve with one HIGH finding fixed (the sweep's own biggest fix
left an assumption unchecked), plus three doc/comment corrections.

---

## Summary

A wide, mostly-independent quality sweep. Eight changes:

1. **`entity_form_controller.ex`** — public submissions read
   `conn.assigns[:phoenix_kit_current_user]` instead of `:current_user`.
   Verified against the dep: core's `fetch_phoenix_kit_current_user` plug
   (`deps/phoenix_kit/.../users/auth.ex:425`) is the only thing that assigns
   a user on the conn, and it uses the prefixed key. Nothing in core or this
   repo ever assigned bare `:current_user` on a conn, so the old read was
   unconditionally `nil` and every signed-in submission was stored as
   anonymous. Correct fix.
2. **`presence_helpers.ex`** — Presence metas shrink from
   `%{user_uuid, user_email, user: %User{}, joined_at, phx_ref, pid,
   transport_pid}` to `%{user_uuid, joined_at, pid}`. The `%User{}` was
   broadcast in a `presence_diff` to every other collaborator's LiveView,
   `hashed_password` included (`redact: true` only suppresses `Inspect`, not
   term serialization). Verified no remaining reader of `:user`,
   `:user_email`, `:phx_ref` or `:transport_pid` anywhere in `lib/` or
   `test/`; the three assigns the dropped `populate_presence_info/3` fed
   (`:lock_owner_user`, `:lock_info`, `:spectators`) have no reader either,
   in code or in any `.heex`. Clean removal.
3. **`web/data_form.ex`** — `client_writable_params/2` allowlists the save
   payload down to what the form renders. See the finding below.
4. **`web/data_form.ex`** — the save-path error changeset gets
   `action: :validate` so `<.input>` will actually render the per-field
   errors `add_form_errors/2` attaches. Matches what the `validate` handler
   already did.
5. **`web/data_form.ex`** — the slug hook attrs (`phx-debounce="0"`,
   `slug_mirror_attrs/0`, `slug_auto_attrs/1`) were only on the multilang
   branch; added to the single-language branch, which is the default.
6. **`web/data_navigator.ex`** — drops a duplicate
   `Events.subscribe_to_entities()`. Confirmed: `PhoenixKitEntities.Web.Hooks`
   `on_mount` subscribes unconditionally on `connected?`, and `Phoenix.PubSub`
   uses a `keys: :duplicate` registry, so the LV was getting every entity
   event twice and running `refresh_entities_and_data/1` twice. Checked the
   other four LiveViews for the same double-subscribe — none of them
   re-subscribes to the entities topic.
7. **`entity_data.ex`** — the reorder success path now audit-logs (only the
   failure and rejected paths did, so the activity table recorded reorders
   exclusively when they went wrong), `escape_like/1` is applied to
   `search_by_title/3` (it was already applied in
   `entity_uuids_matching_title/3` — the two had drifted), and the
   transaction counts rows written rather than pairs submitted.
8. **`catch :exit`** added alongside every existing DB-availability `rescue`
   in `phoenix_kit_entities.ex`, `sitemap_source.ex` and `url_resolver.ex`.
   A dead pool exits rather than raises, so each of those guards stopped one
   step short of the case it was written for. Consistent with the two places
   that already had the `catch`.
9. **`list_entities_with_mirror_status/0`** — 1 grouped count + 1 `File.ls`
   in place of N counts + N `File.exists?`. Verified the substitutions are
   equivalent: `counts_by_entities/2` and `count_by_entity/2` both run
   `exclude_trashed/2` with the same defaults, and `Storage.list_entities/0`
   strips `.json` off the same `root_path()` that `entity_exists?/1`'s
   `entity_path/1` joins a name into, so the `MapSet` membership test and
   the old `File.exists?` agree name-for-name.

---

## Issues Found

### BUG - HIGH — the save path now trusts the URL's blueprint, and nothing
### checks the URL's blueprint is the record's (fixed)

`client_writable_params/2` removes `entity_uuid` from what the client can
write and has the server set it instead:

```elixir
|> Map.put("entity_uuid", entity_uuid)   # entity_uuid = socket.assigns.entity.uuid
```

The in-line rationale is right about the threat — `changeset/2` casts
`:entity_uuid` and `validate_entity_reference/1` only checks that the target
*exists*, so a crafted `save` naming another blueprint's uuid re-parented the
row — and right that "a LiveView event is not bound by the markup that
produced it". But it closes that hole by asserting *"the server knows which
entity this form is for"*, and the server does not check that it does.

In edit mode the two `handle_params/3` clauses load the two halves
independently and never compare them:

```elixir
entity      = Entities.get_entity_by_name(entity_slug, lang: locale)  # from the URL
data_record = EntityData.get!(uuid)                                   # from the uuid
```

So `/admin/entities/<any-other-entity>/data/<uuid>/edit` loads the record
against a blueprint it does not belong to. Before this PR that was wrong on
screen but inert on save — the record kept its own `entity_uuid`. After it,
the server writes the URL's entity, so a plain **Save from a mismatched URL
moves the record to whatever blueprint the URL named** — the exact outcome
the change was written to prevent, reached through the address bar instead of
a crafted payload. The record leaves one navigator, appears in another, and
its public URL and sitemap entry change with it.

The PR's own test for this (`"entity_uuid cannot move the record to another
blueprint"`) navigates to `edit_url(ctx.entity, ctx.record)` — the *matching*
URL — so it cannot see this.

**Fixed** in `web/data_form.ex`: both edit clauses now gate on
`owns_record?/2`, and a mismatch `push_navigate`s to the same record under the
blueprint it actually belongs to (a 404 was the alternative, but the uuid
plainly exists and the canonical URL is one lookup away). Regression test
added: `"editing a record under another entity's URL redirects to its own"`.

### NITPICK — the reorder-failure comment ended up on the success logger (fixed)

The new `log_data_reorder/4` was inserted between the
`# Audit-log a reorder failure ... db_pending: true ...` comment and the
`log_data_reorder_error/4` it describes, so the comment now documents the
success path and claims a `db_pending` key that function does not set. Gave
each function its own comment.

### NITPICK — two docs still describe the old Presence meta shape (fixed)

- `presence_helpers.ex`'s `get_lock_owner/2` doc still says `meta.user`.
- `DEEP_DIVE.md`'s "Presence Tracking" section documents the return of
  `get_sorted_presences/2` as `%{user: %User{}, joined_at: timestamp}`.

Both name the field this PR deliberately removed, on a function the same PR
kept *because it is public API core's docs point at*. Updated both to the
real shape, with a note on why the struct is gone.

### NITPICK — `AGENTS.md`'s reorder audit table drifted (fixed)

The table says `metadata.count` is `n` on all three paths and the bullet
above says both functions log on `:ok`. The success row is now gated on
`written > 0` and carries rows *written*, while the error/rejected rows still
carry pairs *submitted*. Updated the table and the bullet.

---

## Things checked that turned out fine

Recorded so a future reviewer doesn't re-walk them:

- **`@preserve_fields` vs `client_writable_params/2`'s `Map.take`** — the
  classic two-lists-must-stay-in-sync shape. They currently agree exactly
  (`title`, `slug`, `status`, `parent_uuid`), and `preserve_primary_fields/4`
  runs *before* the allowlist, so a drift would silently drop a preserved
  secondary-language field rather than fail loudly. Left as two lists: they
  answer different questions ("which DB columns keep their primary-language
  value on a secondary tab" vs "which DB columns may the client write"), and
  collapsing them would couple multilang behaviour to the security boundary.
  Noted here instead.
- **`@client_settable_statuses` vs the rendered `<select>`** — both branches
  of the template offer exactly `draft` / `published` / `archived`, and
  `@valid_statuses` additionally holds `trashed`, which is what the filter is
  for. In sync.
- **`escape_like/1`** — escapes `\`, `%`, `_` with a backslash, which is
  Postgres' default `LIKE` escape character; the term arrives as a bound
  parameter, so the backslashes are data. Matches the existing usage in
  `entity_uuids_matching_title/3`. No double-escaping: `search_by_title/3`'s
  callers pass raw user input.
- **`counts_by_entities/2` arity** — has a `\\ []` default and an `[]` clause,
  so the single-argument call in `list_entities_with_mirror_status/0` is fine
  and an empty entity list short-circuits.
- **`alive_presence?/1` and `Process.alive?/1` across nodes** — the PR
  deliberately left this and documented it in-line and in
  `dev_docs/2026-08-28-quality-sweep.md`. Agreed it is out of scope for a
  sweep: changing it changes lock-ownership semantics.
- **`catch :exit` placement** — every added clause returns the same value as
  the `rescue` beside it (`[]`, `nil`, `true`, `default`), including the
  nested `try` in `url_resolver.ex`.
