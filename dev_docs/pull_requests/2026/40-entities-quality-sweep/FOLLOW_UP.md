# Follow-up Items for PR #40

Reviewed against `main` on 2026-08-29. CLAUDE_REVIEW raised 4 findings
(1 HIGH, 3 NITPICK). All fixed in this batch.

## Fixed (Batch 1 — 2026-08-29)

- **BUG - HIGH** `web/data_form.ex` — the PR moved `entity_uuid` out of the
  client-writable params and had the server set it from
  `socket.assigns.entity.uuid`, on the reasoning that "the server knows which
  entity this form is for". Nothing checked that it does: both edit
  `handle_params/3` clauses load the entity from the URL and the record from
  its uuid, independently. So `/admin/entities/<other>/data/<uuid>/edit`
  rendered the record against the wrong blueprint — inert before the PR,
  since the form posted the record's own `entity_uuid` back, but afterwards a
  plain Save **moves the record to whatever blueprint the URL named**: the
  exact outcome the change was written to prevent, reached through the
  address bar instead of a crafted payload. Added `owns_record?/2` and
  `redirect_to_owning_entity/2` — a mismatch now `push_navigate`s to the same
  record under the blueprint it really belongs to, with a flash. Covered by
  `"editing a record under another entity's URL redirects to its own"` in
  `data_form_live_test.exs`, which also asserts the record did not move on
  the way. (The PR's own `entity_uuid` test navigates to the *matching* URL,
  so it could not see this.)
- **NITPICK** `entity_data.ex` — the new `log_data_reorder/4` was inserted
  between the `# Audit-log a reorder failure … db_pending: true …` comment
  and the `log_data_reorder_error/4` it describes, so the comment documented
  the success path and named a key that path does not set. Each function has
  its own comment now.
- **NITPICK** `presence_helpers.ex` + `DEEP_DIVE.md` — both still documented
  the Presence meta as carrying `:user` (`get_lock_owner/2`'s doc says
  `meta.user`; DEEP_DIVE shows `%{user: %User{}, joined_at: timestamp}`),
  which is the field this PR removed, on a function it deliberately kept
  because core's docs point at it. Updated both to the real
  `user_uuid` / `joined_at` / `pid` shape, with the reason the struct is gone.
- **NITPICK** `AGENTS.md` — the reorder audit-row table said `metadata.count`
  is `n` on all three paths and the bullet above said both functions log on
  `:ok`. The success row is now gated on `written > 0` and carries rows
  *written*; the error/rejected rows still carry pairs *submitted*. Table and
  bullet updated.

## Deliberately not changed

- **`@preserve_fields` vs `client_writable_params/2`'s `Map.take` list** —
  two lists that must stay in sync (they agree today: `title`, `slug`,
  `status`, `parent_uuid`) and a drift would fail silently, since
  `preserve_primary_fields/4` runs before the allowlist. Left as two lists:
  they answer different questions, and deriving one from the other would
  couple multilang behaviour to a security boundary. Recorded in
  CLAUDE_REVIEW instead.
- **`alive_presence?/1`'s `Process.alive?/1` across nodes** — the PR
  documented this in-line and in `dev_docs/2026-08-28-quality-sweep.md`.
  Agreed it is out of scope for a sweep; changing it changes lock-ownership
  semantics.

## Gate

`mix precommit` (compile --force --warnings-as-errors, deps.unlock
--check-unused, hex.audit, format --check-formatted, credo --strict,
dialyzer, test.js) passes clean.

`mix test`: 1158 tests, 8 failures. The 8 are exactly
`SchemaOwnerGuardTest` (6) and `SchemaOwnerGuardWiringTest` (2) — the
sandbox Postgres role can't `CREATE DATABASE`, the same pre-existing
environment failure recorded in `../38-i067-schema-owner-guard/FOLLOW_UP.md`
and `../39-entities-data-page-and-live-slug/FOLLOW_UP.md`. Every other test
passes, including all 39 in `data_form_live_test.exs`.

## Open

None.
