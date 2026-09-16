# PR #48: Keep every owner's delete guard when owners register at the same time — Grok review

**URL**: https://github.com/BeamLabEU/phoenix_kit_entities/pull/48
**Reviewer**: Grok, no tools (answered from a written description of the old and new `register_delete_guard/2`)
**Date**: 2026-09-15

**Q1. Yes for the bug you saw. Remaining interleavings are benign. `put` still returns `:ok`.**

OLD is a lost-update on one shared map: two `get`s, two `put`s, last map wins, the other owner vanishes. NEW gives each owner its own key. Distinct-owner puts cannot clobber each other. `persistent_term.put/2` is atomic and isolated per key.

Same owner, two concurrent registers: last `put` wins, whole fun replaced, never mixed. That matches the stated replace contract. persistent_term has no CAS, so you cannot make “first register wins” without a different store.

Lookup during register: `get` sees either the previous fun or the new one, never a torn value. A delete that races a *first* register can still fail-closed (`nil`) — same contract as a node that has not finished boot.

Code reload: keys survive; `&Mod.fun/1` stays valid (MFA lookup). A *local* capture is stale in both OLD and NEW.

Node restart: table is empty until boot Tasks re-put. Fail-closed until then. Not distributed; each node registers for itself.

`:persistent_term.put/2` returns `ok`, so `register_delete_guard/2` still returns `:ok` without an extra `:ok`.

**Q2. NEW is cheaper at boot. The `:global.trans` timeout is expected-ish, and `:global` was the wrong lock.**

`put`/`erase` of an *existing* key forces a global GC so old terms can be copied onto any heap that still holds them. **Insert of a new key does not.** OLD replaced the whole map on every register → a global GC per owner at boot, including the two concurrent ones. NEW inserts one small key per owner; GC only on re-register of the same owner. Typical boot is inserts, so NEW is strictly better.

Key growth: one tuple `{Module, :delete_guard, owner}` per owner, forever on that node. Fine for a handful of module names. If `owner` were unbounded user input you’d leak keys until restart (no `erase`); it isn’t.

`:global.trans({…}, fun, [node()])` serializes a *node-local* write through the distributed lock server, default retries `infinity`. Fun is cheap, but each OLD `put` is a global GC, so 40 serialized replace-GCs on a busy test VM can blow 10s. Also a poor fit: `:nonode@nohost`, `global_name_server` contention, and a test timeout killing the lock holder all produce hangs/`aborted`. Drop it; per-key `put` is the actual fix.
