# Mirror: changes made in private repos

The team's shared repo (`falcon-dev-common`) and the agents' identity repos
are private. Everything this project changed in them is mirrored here so
reviewers can read it.

## Scripts (the working code)

| File | What it does |
|---|---|
| [`token-usage.sh`](token-usage.sh) | Run by every agent at task pickup and completion. Reads the agent's own session logs and computes what that stage used, per model. Fails loud, never guesses. |
| [`issue-cost.sh`](issue-cost.sh) | Run by the team lead at issue close. Collects every stage report from the issue and its PRs, converts tokens to dollars from the price table, and emits one ledger row. |
| [`ledger-reconciler.sh`](ledger-reconciler.sh) | Safety net on a 15-minute timer: writes any ledger row the close-out missed, retries rows that couldn't be priced. |
| [`charter-ensure.sh`](charter-ensure.sh) | Creates the per-issue plan card. Replaced written instructions the agents kept skipping; as a script it ran 4 for 4. |

## Tests

[`test_token_usage.sh`](test_token_usage.sh) ·
[`test_issue_cost.sh`](test_issue_cost.sh) ·
[`test_ledger_reconciler.sh`](test_ledger_reconciler.sh)
(59 checks total; several reproduce real production failures.)

These files are verbatim copies from the private repos, so the suites look
for the scripts under `<repo root>/scripts/`. To run them from the root of
this repo:

```sh
mkdir -p scripts && cp docs/mirror/token-usage.sh docs/mirror/issue-cost.sh docs/mirror/ledger-reconciler.sh scripts/
bash docs/mirror/test_token_usage.sh
bash docs/mirror/test_issue_cost.sh
bash docs/mirror/test_ledger_reconciler.sh
```

(`scripts/` is git-ignored; it exists only to satisfy the suites' layout.)

## Full patches (everything else: team charter, contracts, skills)

| Patch | Contents |
|---|---|
| [`falcon-dev-common.patch`](falcon-dev-common.patch) | The core cost-tracking change to the shared team repo |
| [`falcon-dev-common-review-fixes.patch`](falcon-dev-common-review-fixes.patch) | Fixes from the adversarial review round |
| [`fdc-119.patch`](fdc-119.patch) | Fix to the workflow that copies shared files to every agent repo: the version pin now moves with the code, and more file types trigger the copy |
| [`fdc-120.patch`](fdc-120.patch) | Price table refresh (new models priced) |
| [`fdc-121.patch`](fdc-121.patch) | Discord cost bullet gains the cache-read share |
| [`fdc-122.patch`](fdc-122.patch) | Ledger safety net on the 15-minute timer |
| [`fdc-123.patch`](fdc-123.patch) | Operating-system-limit fix: large data passed via files, not environment variables |
| [`fdc-124.patch`](fdc-124.patch) | Unpriced ledger rows retry and heal |
| [`lando-agent.patch`](lando-agent.patch) | Team lead: plan card + cost roll-up + ledger |
| [`lando-agent-review-fixes.patch`](lando-agent-review-fixes.patch) | Team lead review fixes |
| [`lando-agent-charter-backstop.patch`](lando-agent-charter-backstop.patch) | Plan card created at dispatch time, not just at kickoff |
| [`lando-agent-charter-script.patch`](lando-agent-charter-script.patch) | Plan card creation moved from prose to script |

## Evidence

[`cost-ledger-snapshot.jsonl`](cost-ledger-snapshot.jsonl): the team lead's
actual ledger as of submission (one JSON row per issue, written by the agents
themselves during the live runs). It holds the four official rows (#995,
#997, #1000, #1008); #998, #999, and #1001 were aggregated locally from the
same markers. Provenance is detailed in
[the experiment doc](../experiments/cost-per-issue.md#data-provenance).
