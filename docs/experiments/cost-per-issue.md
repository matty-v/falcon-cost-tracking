# Experiment: cost per issue — what moves it?

The instrument came first: every worker self-reports per-stage tokens by model
(`falcon:usage:v1` markers), Lando aggregates and prices them into
`cost-ledger.jsonl`, and every report is tagged with its charter variant and
carries the **actual model read from the transcript**. With that in place,
cost questions become measurable instead of arguable. This doc registers the
baseline, the active experiment, and the designed follow-up — predictions
written down BEFORE the arms run.

## Baseline — variant `full`, all `claude-opus-5` (2026-08-07 → 08, complete)

| issue | stages | holes | tokens | cost (floor) | cost (full) | kickbacks |
|---|---|---|---|---|---|---|
| snapdex#995 (night-theme contrast fix) | 8 | 0 | 37.1M | $28.19 | **$28.19** | 0 |
| snapdex#997 (grouped admin nav) | 10 | 1 | 72.6M | $49.26 | partial | 1 |
| snapdex#998 (entry-bundle perf) | 10 | 1 | 53.6M | $39.34 | partial | 0 |
| snapdex#999 (account-menu close fix) | 7 | 0 | 38.3M | $28.38 | **$28.38** | 0 |

**Median $33.86 / issue (floor basis), mean $36.29, range $28.19–49.26.
Median 46.0M tokens / issue, ~97–98% cache reads.** "Floor" = sum of
priceable stages; 2 of 30 stage-segments were honest `unavailable` holes
(mid-stage session recycles destroyed both baseline copies) and are excluded.

### Per-stage medians

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

Build + review dominate; the five pre-build "thinking" stages sum to ~14M
tokens/issue. The whole bill is ~97% cache reads — the cheap token type —
which shapes which levers matter (see ranking below).

## ACTIVE experiment — model tier (arm 2: fleet on `claude-sonnet-4-5`)

**Variable:** the model each agent runs. Baseline arm ran all `claude-opus-5`
(rates 5 / 25 / 0.5 / 6.25 per MTok in/out/cache-read/cache-write); arm 2
flips the fleet to `claude-sonnet-4-5` (3 / 15 / 0.3 / 3.75) — a uniform 40%
rate reduction on every token type. Everything else holds: same repo, same
issue class, same pipeline, same gates, same charter (`full` variant).

**Why this variable first:** effect size vs. noise. The baseline's issue-size
variance is large ($28–49 at n=4); a ~10% context-trim effect can drown in
it, but a 40% rate shift cannot. It is also the cheapest arm to run — arm
membership needs NO vendor changes: every usage report already records the
actual transcript model, so the ledger sorts itself. And the fleet ran
sonnet-4-5 for months before the opus upgrade, so the quality prior is real;
this arm quantifies what the upgrade actually costs per issue.

**Registered predictions (written before arm 2 runs):**
1. **Cost/issue: median drops ~40% to $19–23** (pure rate arithmetic on
   unchanged token volumes, with slack for behavioral drift).
2. **Tokens/issue: roughly unchanged (±15%)** — if sonnet needs materially
   more calls/turns to do the same work, the token count rises and eats into
   the rate savings; that delta IS the efficiency gap between the tiers.
3. **Guardrails must hold: kickbacks, `merge: no` rates, and gate failures
   flat vs. baseline.** If quality degrades, the honest conclusion is "opus
   earns its premium," priced precisely — equally valuable.

**Protocol:** flip agent specs (roster/agent-spec model fields) →
session-restart the fleet → run ~3 comparable snapdex issues under normal
gates → compare via the ledger grouped by the per-model rows, floor basis,
same stage-profile analysis as baseline. No mid-arm vendor merges; no
mid-issue pod recycles (the baseline-hole lesson).

## Designed follow-up — charter size (`full` vs `lite`), not yet run

The original variable, deferred in favor of the bigger lever. Design: per-role
extracts of the ~140KB CHARTER+CONTRACTS+DECISIONS payload (keep normative
wire contracts + own-role sections; drop other roles' prose, audit ledger,
history; ≥60% smaller), `VARIANT=lite` tag, time-blocked arm. Registered
hypothesis (from the baseline analysis): **8–12% cost reduction** ($3–4 off
the median), concentrated 15–25% in the thinking stages, mechanism visible as
reduced `cache_creation` + first-call input; null result plausible if agents
already read the charter lazily; guardrail — kickbacks must not rise, since
one kickback (~$10, per #997) erases the savings.

## Lever ranking (from the baseline data)

| lever | est. impact | note |
|---|---|---|
| model tier per role | 25–45% | rates multiply the whole bill — ACTIVE |
| API-call efficiency | 15–25% | cost = context × ~220 calls/issue |
| review depth policy | 10–15% | review (10.2M) rivals build (14.5M) |
| charter size | 8–12% | designed follow-up |
| pipeline shape | ~10% | 5 thinking stages ≈ 14M tokens/issue |
| kickback prevention | episodic | one kickback ≈ $10 of rework |

## Data provenance

Rows for #995/#997 are Lando's official `cost-ledger.jsonl`; #998/#999 were
aggregated from the same GitHub markers with the same script (`issue-cost.sh`)
run locally ahead of Lando's close-out cron (method verified identical on
#995: $28.19 both ways). Rates: LiteLLM@b45b4b7 via kyber's generated feed —
no hand-typed prices anywhere in the pipeline.
