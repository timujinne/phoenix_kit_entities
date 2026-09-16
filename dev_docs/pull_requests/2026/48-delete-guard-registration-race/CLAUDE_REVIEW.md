# PR #48 Review — Keep every owner's delete guard when owners register at the same time

**Reviewer:** Claude
**Author:** Dmitri Don
**Merge:** `43d5be4` (branch `mdon/main`, change in `bdcb389`)
**Date:** 2026-09-15
**Verdict:** Approve. The fix is correct and minimal. Two test-hygiene nitpicks
were fixed after the merge.

---

## Summary

- `Managed.register_delete_guard/2` no longer does a get-modify-put on one
  shared `{Managed, :delete_guards}` map. Each owner gets its own
  `{Managed, :delete_guard, owner}` key, so the lost update between two
  concurrent boot tasks cannot happen.
- `delete_guard/1` reads that owner's key, defaulting to `nil`, so a missing
  guard still fails closed with `{:error, :no_delete_guard}`.
- New test: forty tasks are held behind a barrier, released together, and then
  every owner's delete must be approved.

### Verified

- **The trigger is real.** `phoenix_kit_catalogue` registers two owners
  (`"catalogue"` in `attribute_sets.ex`, `"catalogue_supplier"` in
  `supplier_fields.ex`). The catalogue has since moved both into one boot task
  (`Catalogue.DeleteGuards`) as a workaround that works on every entities
  version. With this PR the workaround is redundant but harmless. Keep it until
  the catalogue's entities floor is at least 0.4.15.
- **Nobody reads the old key.** No `lib/` or `test/` code in this repo or in
  any sibling `phoenix_kit_*` checkout references `:delete_guards` or reads the
  term directly. Every consumer goes through `register_delete_guard/2`.
- **The return contract still holds.** `:persistent_term.put/2` returns `:ok`,
  which matches the `:: :ok` spec. Dialyzer would catch a change, and the test
  now asserts it (below).
- **Semantics are unchanged in a fresh VM.** Re-registering the same owner
  still replaces the guard (the last `put` wins, and the value is swapped as a
  whole). Unmanaged, generic, wrong-owner, missing-guard, raising, exiting and
  malformed-result paths all return what they did before.
- **Cost.** Putting a new key does not trigger the global literal-area GC that
  replacing an existing key does. The old code replaced the map on every
  registration, so boot is cheaper now. There is one key per owner. Owners are
  module keys, not user input, so the key count stays bounded.

---

## Findings

### NITPICK — the test did not pin the `:ok` return

`managed_test.exs`, concurrent registration test. The PR removed the explicit
`:ok` from `register_delete_guard/2`, so the function now returns whatever
`:persistent_term.put/2` returns. `Task.await_many/2`'s results were discarded,
so no test checked the documented return value.

**Fixed:** the test asserts every task returned `:ok`.

### NITPICK — `validate_delete/2` tests leaked their registrations

`managed_test.exs`, `describe "validate_delete/2"`. This predates the PR; the
PR's own test cleans up after itself. "owner deletes fail closed without a
registered guard" first asserts `{:error, :no_delete_guard}` for
`"managed_test_owner"`, then registers guards and never erases them. On a
second pass in the same VM (`mix test --repeat-until-failure N`) the guard is
still registered, and the first assertion gets `{:error, :set_in_use}`.
`"crashy_owner"` leaks the same way. Per-owner keys make cleanup a single
`:persistent_term.erase/1`.

**Fixed:** a `setup` `on_exit` in that describe block erases both owners' keys.

### Not changed — hot-upgrade gap (Codex 2)

A node hot-upgraded onto this code, without re-registering, would not see
guards stored under the old map key. I agree with the FOLLOW_UP rationale:
deploys restart, owners register at every boot, and a missing guard fails
closed rather than open. A fallback read of the legacy key would stay in the
code forever to cover a deploy style nobody uses.

---

## Verification

- `mix test test/phoenix_kit_entities/managed_test.exs --repeat-until-failure 5`
  passes.
- Full `mix test` and `mix precommit` are clean.
