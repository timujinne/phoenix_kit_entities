# PR #47 Review — Entity file fields upload into a host-configured folder

**Reviewer:** Claude
**Author:** Timujeen
**Merge:** `f90fb20` (branch `timujinne/feat/attachments-parent-folder`)
**Date:** 2026-09-15
**Verdict:** Approve with a fix. The hook contract and the core wiring are right,
but the hook ran on every form render. The real host hook creates folders, so
just viewing a data form wrote to storage.

---

## Summary

- New `PhoenixKitEntities.Attachments.scope_folder/2` reads
  `config :phoenix_kit_entities, :attachments_parent_folder, {mod, fun}`. It
  calls `fun(:entity_file, actor_uuid, %{entity_name: name})`, or `/2` when
  no 3-arity function is exported, and accepts only `{:ok, binary}`. It
  rescues and degrades to `nil`.
- `Web.DataForm` passes the result to core's `MediaSelectorModal` as
  `scope_folder_id`.
- Tests: unit tests for `scope_folder/2`, plus two LiveView tests that assert
  on a `data-scope-folder` attribute added to the page container.
- `mix.exs` bumped to 0.4.14, with a CHANGELOG entry.

### Verified

- **Core really does scope both paths.** In `MediaSelectorModal`,
  `load_files/2` pipes through `scope_files_by_folder/2`. That covers the
  folder's whole subtree plus `FolderLink`ed files. `process_upload/3` calls
  `maybe_set_folder/2` on new and duplicate uploads. The CHANGELOG's "both
  browsing and new uploads" is accurate.
- **The contract matches the host.** The andi host config sets
  `phoenix_kit_entities: attachments_parent_folder: {Andi.Media.Containers,
  :parent_for}`. `Containers.parent_for(:entity_file, actor, %{entity_name:
  name})` exists and reads `ctx[:entity_name]`. The kind atom and subject shape
  are the same as in the sibling modules (projects, staff, locations,
  manufacturing).
- **A bogus folder uuid can't crash the picker.** A non-existent uuid gives an
  empty subtree and an empty library. `maybe_set_folder/2` logs a warning if
  the FK insert fails. Neither raises.

---

## Findings

### BUG - MEDIUM — the host hook ran on every render and created folders

`Attachments.scope_folder/2` was called from `hydrate_data_form/5`, which runs
from `handle_params/3`. `handle_params/3` runs on the dead HTTP render **and**
again on the connected mount. The real host hook is not a lookup:
`Andi.Media.Containers.parent_for(:entity_file, …)` calls
`ensure_path(:entities, [name], actor)`, which find-or-creates
`Entities/<entity_name>` (and restores a trashed one). As merged, it did so:

- on every open of any data form, twice per page load;
- for **every** blueprint, including text-only ones with no `image`/`video`
  field that can never open the picker;
- for read-only viewers (`lock_owner?: false`), who cannot pick either.

So an `Entities/<name>` folder appeared for every blueprint anyone had
browsed. That means storage writes on a GET, plus two extra find-or-create
round-trips on each render. The sibling projects module hit the same problem
and split its contract into a read-only `%Project{}` subject for render and
`{:ensure, %Project{}}` for creation. This hook has only one shape, so the
caller has to pick the moment.

**Fixed:** the scope is now resolved in `handle_event("pick_media_field", …)`,
after the existing guards (a legal `image`/`video` field, and the lock owner).
That is the only path that renders the modal (`:if={@show_media_selector}`).
Mount defaults `scope_folder_uuid: nil`. The `Attachments` moduledoc and
AGENTS.md now say the hook must not be called from a render.

Tests: *rendering the form never calls the hook*, and *an illegal pick does not
call the hook*. The test hook `send`s every call to the test process, and the
dead render runs in that same process, so the render test covers both renders.
Both tests fail against the merged `data_form.ex`. *opening the picker scopes
it to the hook's folder for this entity and actor* pins the positive path: the
right actor and entity name, and the assign that reaches the modal.

### IMPROVEMENT - MEDIUM — a hook that exits crashed the form

`scope_folder/2` had only a `rescue`. Host hooks do DB work (`Storage` queries,
a folder cache), and a pool checkout timeout or a dead GenServer **exits**
rather than raising. AGENTS.md's convention for host- and DB-facing callbacks
is to rescue **and** catch `:exit`, as `enabled?/0`, `safe_count/1` and
`entities_children` do.

**Fixed:** added `catch :exit, reason ->` with a warning and `nil`.
Test: *returns nil when the hook exits*.

### NITPICK — `data-scope-folder` existed only for the test

The attribute put the folder uuid on the page container just so the LiveView
test could grep for it. Nothing on the client reads it. **Removed.** The tests
now read the assign through the file's existing `:sys.get_state` helper
pattern (`scope_folder_assign/1`, next to `changeset_data/1`).

### NITPICK — a test name described behaviour the code doesn't have

*falls back to a 2-arg hook when no 3-arg clause matches* suggests that a
3-arity hook whose clauses don't match falls back to `/2`. It doesn't:
`function_exported?/3` checks arity, not clauses. A non-matching 3-arity hook
raises `FunctionClauseError`, which is rescued to `nil`. **Renamed** to
*calls a 2-arg hook when the module exports no 3-arity function*.

### NITPICK — docs

- The CHANGELOG said "file/image fields". The picker, and so the scope, only
  applies to `image` and `video` fields. `file` is the upload type and doesn't
  go through `MediaSelectorModal`. **Fixed** the wording. The hook kind stays
  `:entity_file`, because the host contract already matches on it.
- The config key was documented only in the moduledoc. **Added** a README note
  under Field types and an AGENTS.md convention bullet.
- The PR bumped `@version` and dated its entry, but AGENTS.md says bumps land
  with the release commit. The entry has moved to the release version (below).

### Considered, not changed

- **The hook is called on every picker open, not cached per LiveView.** It
  runs once per user click, and the host caches folders itself. A per-LV
  cache would also need invalidation if a folder is trashed while the form is
  open, and `nil` ("no scope") can't be told apart from "not resolved yet".
  Not worth the state.
- **A misconfigured tuple shape** (e.g. a capture instead of `{mod, fun}`) is
  silently ignored, as in every sibling module. Kept consistent.

## Gate

- `mix format`: applied.
- `mix precommit` (`compile --warnings-as-errors`, `deps.unlock
  --check-unused`, `hex.audit`, format check, `credo --strict`, dialyzer,
  `test.js`): **passed**, exit 0. Credo: 1571 mods/funs, no issues. Dialyzer:
  3 errors, all covered by existing `.dialyzer_ignore.exs` skips, 0
  unnecessary skips. Hex audit: no retired packages.
- `mix test`: 1253 tests, 0 failures (10 excluded). PostgreSQL was available,
  so the integration tests ran.

## Release

Shipped as **0.4.14**, the version the PR had already bumped to, re-dated to
the release day. It includes the `lib upgrades` lock bump (`9782f7e`).
