# PR #48: Keep every owner's delete guard when owners register at the same time — Codex review

**URL**: https://github.com/BeamLabEU/phoenix_kit_entities/pull/48
**Reviewer**: Codex (gpt-5.6), read-only repo access, no test runs
**Date**: 2026-09-15
**Scope**: commit `5cc7f7e` (the first version of this change), four numbered questions

1. **Checked, sound** — no code or documentation in `lib/` or `test/` references `{PhoenixKitEntities.Managed, :delete_guards}` or assumes a shared map. The public examples only use `register_delete_guard/2`.

2. **Behavioral difference during hot upgrade** — `lib/phoenix_kit_entities/managed.ex:250,287`.
   Sequence: old code registers `"catalogue"` → guard is stored under the shared-map key → load `5cc7f7e` without restarting/re-registering → call `validate_delete(entity, on_behalf_of: "catalogue")`.
   Expected before: guard result, e.g. `:ok`. Actual after reload: `{:error, :no_delete_guard}`.
   In a fresh VM, all outcomes are unchanged: unmanaged `:ok`; managed generic/wrong-owner `:managed_blueprint`; owner without guard `:no_delete_guard`; registered guard approval/refusal/raise/exit behave as before.

3. **Checked, sound** — `:persistent_term.put/2` returns `:ok`, so `managed.ex:283-285` satisfies the spec. Different owners cannot overwrite each other. Concurrent same-owner registrations retain replacement semantics—the last serialized put wins. A concurrent delete atomically sees the old/nil or new guard; after registration returns, it sees the new guard. No stale read remains apart from the upgrade migration gap in #2.

4. **Test is nondeterministic against the old code** — `test/phoenix_kit_entities/managed_test.exs:56-60` has no start/read barrier. A valid schedule runs each spawned task through shared-map get/put before the next task runs; all forty entries survive and the old implementation passes. Under overlapping execution it will usually expose the race, but is not guaranteed to fail.
   It also leaves forty persistent-term entries. Current tests use no matching owner names, so they are unaffected; a later test expecting no guard for `"concurrent-owner-1"` would expect `{:error, :no_delete_guard}` but receive `:ok`.
