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
error-amplification points and runs `claude-sonnet-5` everywhere else (Matt upgraded the economy tier at wiring time — sonnet-5 is both newer-generation than the sonnet-4-5 first spec AND cheaper):

| agent | role | arm-2 model | rationale |
|---|---|---|---|
| obi-wan | architecture | **opus-5** | cheap stage (3.8M), expensive errors — ~$1.20/issue premium is the cheapest insurance in the system |
| chewie | review + smoke | **opus-5** | the last gate before merge, protecting the cheaper builders; ~$3/issue premium |
| han / luke | builders | sonnet-5 | biggest stage (14.5M) → biggest savings; defects are what the opus reviewer exists to catch |
| yoda | triage/challenge/verdict | sonnet-5 | rubric-driven classification; months of sonnet history |
| ackbar | deploy | sonnet-5 | checklist + verification work; risky ops gated by Matt |
| boba-fett | QA (off-pipeline) | sonnet-5 | findings re-verified on pipeline entry |
| lando | orchestrator | sonnet-5 | contract-following; hard calls escalate to Matt; his always-on background cost isn't even in the per-issue ledger — pure extra savings |

Rates: opus 5 / 25 / 0.5 / 6.25 per MTok vs sonnet-5 2 / 10 / 0.2 / 2.5 — a
uniform 60% reduction wherever sonnet-5 runs. Opus is retained on ~41% of
baseline issue-tokens (architecture + review/smoke); cost multiplier ≈
0.41 + 0.59×0.40 ≈ 0.65.

**Registered predictions (written before arm 2 runs):**
1. **Cost/issue: median ≈ $21–24 (~35% below the $33.86 baseline)** — rate
   arithmetic over the mixed placement (updated when Matt wired sonnet-5, a
   60% rate cut, instead of the sonnet-4-5 first spec at 40%); deliberately
   ~$2–4/issue above the all-sonnet-5 floor to keep opus at both gates.
2. **Tokens/issue roughly unchanged (±15%)**; a sonnet-builder needing more
   turns shows up as stage-token growth and IS the measured tier gap — with a
   plausible surprise in our favor if newer-generation sonnet-5 needs FEWER
   turns than the 4-5 lineage would have.
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

### Arm-2 results (accumulating)

| issue | tokens | cost (floor) | kickbacks | notes |
|---|---|---|---|---|
| snapdex#1000 (view switcher) | ~60M | **$22.63** (full) | 1 | yolo; first fast-path-priced row |
| snapdex#1001 (dex-card link) | 75.0M | $33.07 | 1 | yolo; 1 hole (obi-wan baseline lost) |
| snapdex#1008 (report-sheet styling fix) | 44.1M | **$20.06** (full) | 1 | non-yolo, ZERO holes — best-matched datum; independent recomputation matched the official row to the cent |

Both arm-2 issues ran yolo-labeled (consistent within-arm; differs from the
gated baseline — flagged confound). Wiring verified from transcript models on
every report: opus-5 only at architecture + review/smoke, sonnet-5 everywhere
else.

**RESULT (arm complete, n=3):** three lenses, one answer —

| comparison | result |
|---|---|
| medians (baseline $33.86 → arm-2 $22.63) | **−33%** |
| matched clean small-bugs (#995/#999 avg $28.29 → #1008 $20.06) | **−29%** |
| per-issue counterfactual (actual tokens repriced at all-opus) | **−34%, −34%, −35%** |

The registered prediction was $21–24 median (~35%): the arm landed at $22.63
— inside the band — and the counterfactuals sit on the rate arithmetic almost
exactly, meaning the savings came from rates, not from behavior change. Token
volumes ran elevated on the two yolo issues (60–75M vs 46M baseline median)
but the non-yolo closer (#1008, 44.1M) matched baseline volume — consistent
with prediction #2's "volumes unchanged" at matched scope, and attributing
the inflation to issue scope/yolo rather than sonnet-tier turn inflation.
Guardrails: kickbacks appeared in 3/3 arm-2 issues vs 1/4 baseline — the one
result that stops short of a clean bill. At this n it is not separable from
yolo mode and issue mix, but it is exactly the signal the follow-up arm
(drop Chewie to sonnet-5? revert builders to opus?) should watch first, and
it is recorded as the experiment's open question rather than smoothed over.

**Bottom line for the bill-payer: role-aware model placement cut cost per
issue by roughly a third while keeping the premium model at both judgment
gates, and the ledger now prices that trade to the cent per role.**

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
