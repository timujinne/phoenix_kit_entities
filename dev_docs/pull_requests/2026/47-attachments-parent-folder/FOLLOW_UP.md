# PR #47 — Follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Host hook ran from `handle_params` on every render (dead + connected, every blueprint, read-only viewers) and the andi hook find-or-creates `Entities/<name>` | BUG - MEDIUM | Fixed: resolved in `pick_media_field` after its legality/lock-owner guards; mount defaults `scope_folder_uuid: nil`. Tests *rendering the form never calls the hook* and *an illegal pick does not call the hook* fail against the merged `data_form.ex`. |
| `scope_folder/2` rescued but did not catch `:exit` | IMPROVEMENT - MEDIUM | Fixed: `catch :exit` → warning + `nil`. Test *returns nil when the hook exits*. |
| `data-scope-folder` DOM attribute existed only for the test | NITPICK | Fixed: removed; tests read the assign via `:sys.get_state`. |
| Test name implied clause-level fallback from `/3` to `/2` | NITPICK | Fixed: renamed to describe the arity check. |
| CHANGELOG said "file/image"; config undocumented outside the moduledoc; version bumped in the feature PR | NITPICK | Fixed: wording is `image`/`video`; README + AGENTS.md notes added; entry re-dated for the 0.4.14 release. |
| Hook not cached per LiveView | — | Not changed: once per click, host caches; a cache would need invalidation and can't tell `nil` from unresolved. |
