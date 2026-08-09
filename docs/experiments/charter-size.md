# Experiment: does shrinking the team charter reduce cost per issue?

**Variable:** the size of the shared context every agent vendors and re-reads —
`falcon-dev-common`'s CHARTER.md + CONTRACTS.md + DECISIONS.md, ~140KB that
lands in each agent's context (as cache writes, then repeated cache reads) on
every dispatch.

**Arms:** `full` (the complete charter, tagged `full@<sha>` in every usage
report) vs `lite` (per-role extracts keeping normative contracts — comment/ack
/label shapes, the agent's own role sections, Format Standard — dropping other
roles' prose, the audit ledger, and history; target ≥60% byte reduction;
tagged `lite@<sha>`). The tag rides automatically in every `falcon:usage:v1`
report via the vendored VARIANT file, so arm membership needs no bookkeeping.

**Design + caveats, stated up front:** time-blocked arms (vendor pins are
per-repo), n≈4 issues per arm on one repo (snapdex), comparable PWA bug/perf
work, frozen models (all `claude-opus-5`), Matt's normal approval gates. This
is a DIRECTIONAL read, not statistics — issue-size variance dominates at this
n, so we compare medians and per-stage profiles rather than means, and report
partial rows (mid-stage baseline losses) as floors, excluded stages named.

## Baseline arm — variant `full` (2026-08-07 → 08, complete)

| issue | stages | holes | tokens | cost (floor) | cost (full) | kickbacks |
|---|---|---|---|---|---|---|
| snapdex#995 (night-theme contrast fix) | 8 | 0 | 37.1M | $28.19 | **$28.19** | 0 |
| snapdex#997 (grouped admin nav) | 10 | 1 | 72.6M | $49.26 | partial | 1 |
| snapdex#998 (entry-bundle perf) | 10 | 1 | 53.6M | $39.34 | partial | 0 |
| snapdex#999 (account-menu close fix) | 7 | 0 | 38.3M | $28.38 | **$28.38** | 0 |

**Baseline: median $33.86 / issue (floor basis), mean $36.29, range
$28.19–49.26. Median 46.0M tokens / issue, ~97–98% cache reads.** The two
hole-free issues priced within $0.19 of each other. "Floor" = sum of priceable
stages; 2 of 30 stage-segments across the arm were honest `unavailable` holes
(mid-stage session recycles destroyed both baseline copies) and are excluded,
so true costs for #997/#998 are slightly above their floors.

### Per-stage medians (the profile the lite arm must move)

| stage | median tokens | n |
|---|---|---|
| ready-for-implementation (build) | 14.52M | 4 |
| merge-requested (review) | 10.17M | 5 |
| smoke-test | 4.96M | 4 |
| needs-architecture | 3.77M | 5 |
| needs-triage | 3.19M | 4 |
| needs-deploy-review | 2.92M | 4 |
| needs-challenge | 2.73M | 6 |
| approval-verdict | 1.41M | 1 |

The five pre-build "thinking" stages sum to ~14M tokens/issue — a full
build-stage-equivalent of overhead, and the segment where the vendored charter
is proportionally the largest share of context. Review (a full re-verification
by charter policy) rivals the build itself.

**Predictions to test in the lite arm:** (1) `cache_creation` and first-call
input drop first — the charter lands as cache writes at session start; (2) the
thinking stages shrink proportionally more than build/review, whose tokens are
dominated by code context; (3) guardrail — kickback count and `merge: no`
rates must not rise; a cheaper charter that degrades quality is a net loss.

## Lite arm — variant `lite` (pending)

Protocol: build `charter-lite` branch in falcon-dev-common → set `VARIANT=lite`
→ re-pin the fleet + session restarts → run ~4 comparable snapdex issues → the
comparison is `jq`/python over `cost-ledger.jsonl` grouped by the variant-name
prefix of `charter_variant`, on the same floor basis and stage profile as
above.

## Data provenance

Rows for #995/#997 are Lando's official `cost-ledger.jsonl` entries; #998/#999
were aggregated from the same GitHub markers with the same script
(`issue-cost.sh`) run locally, ahead of Lando's close-out cron, and verified
identical in method to the official #995 row ($28.19 both ways). Rates:
LiteLLM@b45b4b7 via kyber's generated feed (no hand-typed prices anywhere).
