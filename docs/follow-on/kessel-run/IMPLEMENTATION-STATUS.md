# Kessel Run baseline hardening — implementation status

**Recorded:** 2026-08-18

**State:** merged and propagated; fleet restart and qualification run pending

The plan was implemented and merged as three reviewable changes:

- [falcon-dev-common #140](https://github.com/matty-v/falcon-dev-common/pull/140)
  adds immutable v2 ledger identity, fresh-workspace preparation and
  attestation, PR gating, worker sweep/audit tooling, profile contracts, and
  regression tests.
- [kessel-run-template #1](https://github.com/matty-v/kessel-run-template/pull/1)
  adds the fail-closed operator preflight and updates the experiment runbook.
- [chewie-agent #97](https://github.com/matty-v/chewie-agent/pull/97) makes
  missing or stale Builder workspace evidence a review hold for resettable
  benchmark profiles.

## Verification completed

- Shared targeted suites: 137 assertions passed across ledger generation and
  reconciliation, profile/dispatch contracts, PR gating, workspace preparation,
  sweep behavior, and reviewer evidence validation.
- Template preflight tests: clean readiness passes and dirty sweep evidence is
  refused.
- Shell syntax checks and `git diff --check` passed in both implementation
  repositories.
- The broader shared hook runner was exercised. Its failures were unrelated to
  these changes: the local environment lacks `pytest`, and two legacy
  `pre_commit_guard` expectations fail against current behavior.

The shared vendor propagation workflow completed successfully and merged the
bundle bump into all eight identity repositories.

## Remaining rollout gates

Baseline collection must not begin until the six participant pods are restarted
onto the new bundle. The first run after rollout is a qualification run, not
part of the ten-run sample, unless it satisfies every validity gate in the
implementation plan.
