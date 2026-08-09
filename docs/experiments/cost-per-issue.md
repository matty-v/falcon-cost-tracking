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

## ACTIVE experiment — model tier (arm 2: MIXED fleet, quality-gates-keep-opus)

**Variable:** the model each agent runs — placed by role, not uniformly.
Matt pushed back on the all-sonnet design: uniform downgrade maximizes savings
but not savings-per-unit-of-risk. The arm keeps `claude-opus-5` at the two
error-amplification points and runs `claude-sonnet-4-5` everywhere else:

| agent | role | arm-2 model | rationale |
|---|---|---|---|
| obi-wan | architecture | **opus-5** | cheap stage (3.8M), expensive errors — ~$1.20/issue premium is the cheapest insurance in the system |
| chewie | review + smoke | **opus-5** | the last gate before merge, protecting the cheaper builders; ~$3/issue premium |
| han / luke | builders | sonnet-4-5 | biggest stage (14.5M) → biggest savings; defects are what the opus reviewer exists to catch |
| yoda | triage/challenge/verdict | sonnet-4-5 | rubric-driven classification; months of sonnet history |
| ackbar | deploy | sonnet-4-5 | checklist + verification work; risky ops gated by Matt |
| boba-fett | QA (off-pipeline) | sonnet-4-5 | findings re-verified on pipeline entry |
| lando | orchestrator | sonnet-4-5 | contract-following; hard calls escalate to Matt; his always-on background cost isn't even in the per-issue ledger — pure extra savings |

Rates: opus 5 / 25 / 0.5 / 6.25 per MTok vs sonnet 3 / 15 / 0.3 / 3.75 — a
uniform 40% reduction wherever sonnet runs. Opus is retained on ~41% of
baseline issue-tokens (architecture + review/smoke).

**Registered predictions (written before arm 2 runs):**
1. **Cost/issue: median ≈ $25–27 (~24% below the $33.86 baseline)** — rate
   arithmetic over the mixed placement; deliberately ~$6/issue above the
   all-sonnet floor to keep opus at both judgment gates.
2. **Tokens/issue roughly unchanged (±15%)**; a sonnet-builder needing more
   turns shows up as stage-token growth and IS the measured tier gap.
3. **Guardrails flat (kickbacks, `merge: no`, gate failures)** — the design
   bet is that they hold BECAUSE the gates kept opus. If they hold, the
   follow-up arm drops Chewie to sonnet to test whether the review gate
   actually needed the premium.
4. Per-model attribution comes free (every report records the transcript
   model), so savings decompose by role regardless of outcome.

**Interpretation note, honest:** a mixed fleet measures "how much premium can
be shed safely" rather than a clean single-variable rate effect — slightly
muddier as science, operationally the right question for the bill-payer.

**Protocol:** flip the model per agent spec as tabled → session-restart the
fleet → run ~3 comparable snapdex issues under normal gates → compare via the
ledger's per-model stage rows, floor basis, same stage-profile analysis as
baseline. No mid-arm vendor merges; no mid-issue pod recycles.

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
