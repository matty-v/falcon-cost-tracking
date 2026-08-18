# Kessel Run baseline hardening — implementation plan

**Status:** merged and propagated; fleet restart pending

**Recorded:** 2026-08-18

**Follow-on to:** [Per-issue cost tracking](../../../README.md)

Implementation and verification status is recorded in
[IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md).

## Objective

Turn repeated implementations of the frozen Kessel Run task into a trustworthy
cost baseline for the Falcon Dev Team. A qualifying run must begin from the same
repository and task state, use fresh agent sessions and workspaces, preserve
complete stage-level token evidence, finish through merge and deployment, and
produce a distinct priced ledger row.

The target baseline is at least ten clean runs. Invalid runs remain recorded but
are excluded from baseline statistics.

## Incidents driving this work

The first observed follow-on run exposed two independent correctness failures:

1. A builder reused a persistent local clone and read a leftover implementation
   diff. Recycling an agent session does not clear its whole-disk workspace, and
   prose telling the agent to re-clone was not an enforceable boundary.
2. Every recreated repository starts again at `matty-v/kessel-run#1`. The cost
   ledger uses that display reference as its idempotency key, so a priced row
   from an earlier repository incarnation can suppress the new run's row.

The backstop also previously carried a hard-coded repository list. That defect
was fixed independently in falcon-dev-common #139; this plan retains the
single-source-of-truth scope rule and adds regression coverage around it.

## Workstream A — immutable cost-ledger identity

Owner: `matty-v/falcon-dev-common`

1. Extend `scripts/issue-cost.sh` to fetch GitHub's immutable repository ID and
   issue node ID and emit a version-2 ledger row containing:

   ```json
   {
     "v": 2,
     "ledger_key": "github:<repository-id>:<issue-node-id>",
     "repository_id": 123456789,
     "issue_node_id": "I_kwDOExample",
     "issue": "matty-v/kessel-run#1"
   }
   ```

2. Add optional `--run-id R-YYYYMMDD-x`. The benchmark operator supplies this
   human-facing ID; ordinary product issues may omit it. Frozen issue titles,
   bodies, and labels remain unchanged.
3. Replace the reconciler's textual `grep` idempotency with structural JSONL
   lookup by `ledger_key`. Only an unpriced row with the same immutable key may
   be superseded.
4. Preserve version-1 rows unchanged. Introduce an explicit v2 rollout cutoff
   for the backstop so historical recent issues are not duplicated during the
   transition.
5. Add tests for repeated `owner/repo#number` values, exact reprocessing,
   unpriced healing, malformed JSONL, and scope discovery.

## Workstream B — mechanically fresh workspaces

Owner: `matty-v/falcon-dev-common`

1. Add `scripts/prepare-workspace.sh`. For repositories whose deploy profile
   declares `workspace.policy: fresh-clone-per-dispatch`, it must:

   - accept an explicit `owner/repo` and dispatch envelope;
   - resolve only `$HOME/dev/<repo>` and refuse symlinks, unexpected parents,
     globs, empty paths, or broad deletion targets;
   - delete the exact stale clone and its local worktrees;
   - clone the current repository without inspecting the old tree;
   - record repository ID, initial commit, preparation time, prior-path state,
     agent, and envelope in a machine-readable attestation.

2. Add the workspace policy to `profiles/kessel-run.yaml` and its profile
   schema documentation.
3. Invoke preparation from `handle-inbound` before a role-specific skill may
   inspect the target repository.
4. Post a separate, implementation-free `falcon:workspace:v1` marker to the
   issue. Keep the load-bearing pickup and usage markers unchanged.
5. Extend `pr-create.sh` to fail closed for a fresh-clone-policy repository when
   the active envelope lacks a matching repository-ID/initial-SHA attestation.
6. Make review treat a missing or mismatched attestation as `merge: hold`, not a
   non-blocking observation.

## Workstream C — deterministic sweep and preflight

Owners: `matty-v/falcon-dev-common`, `matty-v/kessel-run-template`

1. Add `scripts/benchmark-sweep.sh` with `audit` and `clean` modes. It may touch
   only explicitly validated Kessel Run workspaces, runtime files, and tagged
   benchmark memory blocks. It must preserve Lando's cost ledger, ship reports,
   event logs, dispatch accounting, and freeze/carve-out records.
2. Emit structured sweep evidence so the operator can prove all participants
   were clean before session recycling.
3. Add `scripts/preflight-run.sh` to the template. It fails unless:

   - the previous run has terminal cost evidence;
   - participant sweeps are clean;
   - the recreated repo has one commit, no prior issues or PRs, and a new
     repository ID;
   - the baseline deployment is live;
   - all participants are Running on replacement pod IPs;
   - the parked issue has exactly the expected labels; and
   - the frozen task matches the private task bank byte-for-byte.

4. Print one JSON readiness record for the operator to retain.

The between-run order becomes:

```text
cost record terminal
→ sweep and verify participants
→ recreate repository
→ recycle sessions and verify pod IPs
→ file parked task
→ preflight
→ release task
```

## Workstream D — follow-on experiment record

Owner: `matty-v/falcon-cost-tracking`

This public repository will contain sanitized metrics only. It must not contain
task-bank material, implementation diffs, solution descriptions, or anything
that gives future agents a shortcut.

```text
docs/follow-on/kessel-run/
├── README.md
├── IMPLEMENTATION-PLAN.md
├── baseline.jsonl
└── runs/
    └── R-YYYYMMDD-x.md
```

Each run record includes immutable ledger identity, run ID, validity and reason
codes, stage tokens and cost, wall-clock time, review rounds, interventions,
CI/deploy outcome, workspace attestation, model/charter configuration, and
pricing provenance. Invalid runs use `valid:false` and remain visible.

## Verification and rollout

1. Run every falcon-dev-common script test plus the contract drift guards.
2. Run the template reset/preflight tests with stubbed GitHub and Kyber APIs.
3. Merge and propagate the shared vendor bundle to all agent identity repos.
4. Restart the participating fleet.
5. Run one qualification iteration and require:

   - fresh-workspace markers before implementation;
   - complete stage usage markers;
   - a unique, priced v2 ledger row;
   - successful merge and deployment; and
   - a clean post-run sweep.

6. Only then begin collecting the ten-run baseline.

## Non-goals

- Changing the frozen benchmark task.
- Adding benchmark metadata to its issue title, body, or label set.
- Clearing agent disks or unrelated repositories.
- Rewriting historical version-1 ledger rows.
- Publishing implementation knowledge where future benchmark agents can read it.
