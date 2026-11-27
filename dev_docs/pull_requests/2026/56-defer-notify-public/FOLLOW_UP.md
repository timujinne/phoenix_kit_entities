# PR #56 — follow-up

- Stale `ex_aws_ec2` lock from the `phoenix_kit` 3.0.0 → 3.7.0 upgrade
  unlocked (`mix deps.unlock ex_aws_ec2`); `mix deps.unlock --check-unused`
  was failing in `mix precommit` before this.
- `EntityData.notify_committed/2` now raises a descriptive `ArgumentError`
  for any event other than `:created`/`:updated` (test added).
- `EntityData.update_data/3`'s `@spec` widened to include
  `:status_mismatch` and `:locked_key`, matching the `update/3` it delegates
  to.
- None outstanding.
