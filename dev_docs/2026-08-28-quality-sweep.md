# Quality sweep — phoenix_kit_entities (2026-08-28)

Playbook: `~/Desktop/Elixir/dev_docs/quality_sweep.md`. Phase 1 is complete —
both untriaged PR folders (#30, #33) now carry a `FOLLOW_UP.md`. This file
records Phase 2.

Four triage agents ran over `lib/` + `test/` (security/error-handling,
translations/activity/tests, PubSub/cleanliness/API, host-integration
boundaries) plus the hand checks. **Every finding was verified against the
code before being acted on**; the ones that did not survive are listed under
"Rejected".

## Fixed

### Security and correctness

- **The public form read the wrong assign key.**
  `conn.assigns[:current_user]` — nothing sets that. Core's
  `:phoenix_kit_auto_setup` pipeline assigns `:phoenix_kit_current_user`. So
  a *signed-in* submitter was stored as anonymous, and the careful
  explicit-nil reasoning in the comment above it never got to matter. Worse
  on a pre-V169 core, where `created_by_uuid` is NOT NULL: the explicit nil
  made every public submission a validation failure.
- **Presence broadcast the whole `%User{}` — `hashed_password` included.**
  `redact: true` only suppresses `Inspect`, not term serialization, and
  Phoenix.Presence ships metas to every subscriber of the editing topic on
  each join and leave. The only reader of `meta.user` was
  `populate_presence_info/3`, whose three assigns (`:lock_owner_user`,
  `:lock_info`, `:spectators`) appear in no template and no function body:
  **the credentials crossed the cluster to feed dead code**, recomputed on
  every `presence_diff`. The meta is now `user_uuid` / `joined_at` / `pid` —
  what ownership, ordering and dead-session detection actually read — and the
  dead function, the dead assigns, and two uncalled helpers
  (`get_spectators/2`, `count_editors/2`, whose docs described a meta shape
  that no longer exists) are gone from both LiveViews.
- **Mass assignment on save.** The handler passed raw client `data_params` to
  `EntityData.update/3`, which casts `created_by_uuid`, `date_created`,
  `metadata` and `position` — none of which the form renders. A crafted
  `save` could forge authorship, back-date the audit timestamp, rewrite the
  `ip_address`/`user_agent`/`security_warnings` a flagged public submission
  was stored with, or move a record to another blueprint. Now allowlisted to
  the fields the form has, pinned by a test that fails without it.
- **`search_by_title/3` ignored `escape_like/1`** — a helper in the same
  module, used by its sibling. Searching `50%` matched every record; `a_b`
  matched `axb`. Not injection (Ecto parameterises) but a wrong answer and an
  unbounded scan.

### The live slug never worked on a single-language install

The hook attrs were only on the multilang branch. The `else` branch — which
is what a **single-language install, the default, always renders** — emitted
raw inputs with no `phx-hook`, no `data-slug-auto`, and `phx-debounce="300"`.
Being raw inputs they need no `:global` passthrough from core, so this works
against the released pin too.

The test that should have caught it was wrapped in `if html =~
phx-debounce="0"`, whose else branch asserted the 300ms fallback and passed.
Splitting that conditional also exposed a second flaw: the `if` branch handed
slug ownership to the user and the shared tail then asserted the server still
derives — an assertion that only held because the branch never ran. Now two
tests, both unconditional.

### Audit trail

- **A successful reorder logged nothing**, while its failure and
  rejected-payload paths both did — so the activity table contained reorders
  only when they went wrong, and the actor was being computed and discarded.
  Pinned by a test that fails without it.
- **The activity assertion helper silently ignored `resource_type:`** and any
  other unrecognised key: `match_opt/3` answers `true` for anything it is not
  asked about. Two call sites passed `resource_type:` and got nothing. It now
  raises on unknown keys — which immediately caught a test passing
  `metadata:` where `metadata_has:` was meant, i.e. asserting nothing at all.

### Robustness and performance

- **`rescue` without `catch :exit`** in `entities_children/1,2` (core's
  `dynamic_children` callback, so the exit took out every admin page render),
  five guards in `sitemap_source.ex`, and five in `url_resolver.ex`. Each
  exists for "the database may be unreachable" — and an unowned checkout
  raises while a **dead pool exits**, so none held in the case it was written
  for. `enabled?/0` in two of those very files already had the `catch`.
  (An automated pass over these got two fallbacks wrong — `default` became
  `nil` — and was reverted in favour of editing each by hand.)
- **`data_navigator` subscribed to entity events twice**: once via
  `on_mount(Hooks)` and again in `mount/3`. Phoenix.PubSub uses a duplicate
  registry, so every entity event ran the ~4-query refresh twice.
- **`list_entities_with_mirror_status/0` was an N+1** — one count query and
  one `File.exists?` per entity — while `EntityData.counts_by_entities/2`
  existed unused a few modules away. The settings LiveView re-runs it on
  every entity *and* data broadcast, and autosave emits `:data_updated` per
  debounced keystroke, so one user typing drove `1 + 2N` queries plus `N`
  filesystem stats on every open settings page.
- **Validation errors never rendered inline.** The save path's error
  changeset came from `EntityData.change/2`, which never touches
  `repo.insert/update`, so `action` stayed `nil` and `<.input>` gates error
  display on `action != nil`. Every per-field error was invisible, leaving
  only a concatenated flash. The `validate` handler in the same file already
  set it.

## Rejected after verification

- **"`:depth` is castable, so nesting limits can be defeated."** It is always
  recomputed from the parent before insert.
- **"`SlugFromTitle` collides with another module's hook."** Checked core's
  bundle and all sibling bundles: no collision today. It is the only
  un-namespaced external hook name, so the risk is real but latent — see
  Open.
- Several "missing gettext" and "commented-out code" flags: prose comments and
  data-driven field labels, correctly not translated.

## What an external panel found in the fixes

Four models reviewed the PR after the fixes were in; three independently
found the same hole in the mass-assignment fix. Verified before acting:

- **`entity_uuid` was in the allowlist** — the field with the widest blast
  radius, and the one the function's own comment named. The blueprint decides
  a record's URL, its sitemap entry and which navigator it appears in;
  `changeset/2` casts it and `validate_entity_reference/1` checks only that
  the target exists. The hidden input binds the browser, not the socket. The
  server knows which entity the form is for, so the server sets it.
- **`status` accepted `"trashed"`**, a valid status the select never offers.
  Writing it directly skips `trash/2`, where `metadata["trashed_from_status"]`
  is stashed: the row soft-deleted without recording what it had been, logged
  `entity_data.updated`, and would restore to "draft" whatever its real
  status was. The reverse — writing "published" onto a trashed row — skips
  `restore_from_trash/2` the same way.
- **The deleted presence helpers were public API.** `get_spectators/2` and
  `count_editors/2` had no callers in this repo, but core's
  `making-pages-live.md` lists `get_spectators/2` among this module's
  functions, so a host following that guide would have taken an
  UndefinedFunctionError from a patch release. Both restored on the trimmed
  meta; the security fix is untouched.
- **The reorder audit row counted the wrong thing** — the raw pair list while
  the transaction wrote from the deduped one, and `update_all` results were
  discarded, so a pair naming a row in another entity counted despite
  updating nothing. Now the rows actually written, and an empty payload
  writes no row at all.
- **Recorded, not fixed:** `alive_presence?/1` filters on `Process.alive?/1`,
  which is false for a live process on another node — so on a multi-node
  deployment each node discards the other's presences and two people can both
  be told they hold the lock. It predates this branch; a note now sits beside
  it saying why it is there.

## Open — needs a decision

1. **Public submissions are hardcoded `status: "published"`.**
   `entities_default_status` (default `"draft"`) and
   `entities_require_approval` are written by the settings UI, validated on
   save, and **read nowhere in `lib/`**. The module's own `OVERVIEW.md` calls
   them "🚧 Not yet enforced", so this is a known gap rather than a
   regression — but the settings screen presents working controls that do
   nothing, and unauthenticated submissions land live and sitemap-eligible.
   Not changed here: flipping the default would change behaviour on every
   live install, which is your call.
2. **All public-form anti-abuse is opt-in** — honeypot, timing check and rate
   limit each default to `false`, so enabling a public form gets an endpoint
   with none of them. There is also no server-side cap on submitted field
   values (`max_length` is emitted as an HTML attribute only), so one request
   can write a multi-megabyte JSONB row.
3. **`SlugFromTitle` should be namespaced** (`PhoenixKitEntitiesSlugFromTitle`)
   — the fold into `window.PhoenixKitHooks` is last-write-wins across every
   module and core, and this is the sole generic name among external bundles.
   Renaming touches the bundle, `js_sources/0` and the `phx-hook=` sites.

## Open — known gaps, not yet done

- **17 `handle_info/2` clauses across four LiveViews have no test.** These are
  runtime-only paths: they dot-access socket assigns and call bang-functions,
  so a renamed assign or a changed event tuple compiles clean, passes
  dialyzer, passes the suite — and kills the socket the first time a
  collaborator saves in another tab. Includes both `presence_diff` handlers
  and the entire media-picker completion path.
- **Two tests with no assertions at all** (`context_extras_test.exs:233,240`),
  and six tautological ones whose titles claim more than they check
  (`assert match?({:ok,_}, r) or match?({:error,_}, r)` over a function whose
  return type is exactly that union).
- **507 of 508 msgids have no runtime proof they resolve** — every
  translation assertion outside one file pins the English msgid, which
  `gettext/1` returns when the string is absent, so those tests would pass
  with `priv/gettext/` deleted.
- **No code→`.pot` gate exists**: the catalogue tests compare `.po` files to
  each other, which by construction cannot see a string that reached no
  catalogue. `mix gettext.extract --check-up-to-date` belongs in `precommit`.
- **`@field_types` keeps raw English `label:`/`description:` values** behind a
  fall-through, so deleting a `label_for/1` gettext clause is invisible under
  `en` while `ru`/`et` silently regress.
- **Six settings mutations attribute the change to the entity's creator**
  rather than the admin who made it, because they call the 2-arity
  `update_entity/2` and the actor falls back to `entity.created_by_uuid`.
- **`bulk_update_status/3` and `bulk_delete/2` never broadcast**, while their
  `bulk_trash`/`bulk_restore` siblings do — so other open sessions show stale
  rows after those two actions only.
- **Duplication:** the admin-authorization wrapper is copy-pasted 16 times
  (sixteen chances to omit it on a new handler); the bulk-action body 5
  times; the mirror-toggle body 4 times.
- **Naming:** `EntityData` ships two complete parallel schemes
  (`list_all_data/1` ↔ `list_all/1` …) and the LiveViews use both in the same
  file; `search_data`, `delete_data`, `list_definitions` and
  `definition_exists?` have no callers in `lib/`.
- **`@spec` is absent across the whole PubSub/Presence public surface**
  (`events.ex`, `presence_helpers.ex`).
- **`js_sources/0` has no test** — nothing asserts the file exists at the
  declared priv path, that `:global` matches the bundle, or that every
  `phx-hook=` name resolves.
- **Docs drift:** README shows a `.phk` publishing snippet as the HEEx embed
  syntax; the callback table omits `js_sources/0` and `sitemap_sources/0`; the
  file layout lists a `migrations/v1.ex` that does not exist and omits
  `priv/static/`.
