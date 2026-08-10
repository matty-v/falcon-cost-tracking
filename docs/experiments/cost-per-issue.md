# Experiment: cost per issue, and what moves it

The instrument came first: every worker self-reports its per-stage tokens by
model (`falcon:usage:v1` markers), Lando aggregates and prices them into
`cost-ledger.jsonl`, and every report is tagged with its charter variant and
carries the **actual model read from the session log**. With that in place,
cost questions become measurable instead of arguable. This doc registers the
baseline, the active experiment, and the designed follow-up, with predictions
written down BEFORE the test arms ran (an "arm" is one configuration under
test).

## Baseline: variant `full`, all `claude-opus-5` (2026-08-07 → 08, complete)

| issue | stages | holes | tokens | cost (floor) | cost (full) | kickbacks |
|---|---|---|---|---|---|---|
| snapdex#995 (night-theme contrast fix) | 8 | 0 | 37.1M | $28.19 | **$28.19** | 0 |
| snapdex#997 (grouped admin nav) | 10 | 1 | 72.6M | $49.26 | partial | 1 |
| snapdex#998 (entry-bundle perf) | 10 | 1 | 53.6M | $39.34 | partial | 0 |
| snapdex#999 (account-menu close fix) | 7 | 0 | 38.3M | $28.38 | **$28.38** | 0 |

**Median $33.86 / issue (floor basis), mean $36.29, range $28.19–49.26.
Median 46.0M tokens / issue, about 97–98% cache reads.** "Floor" means the
sum of the stages that could be priced; 2 of 35 stage-segments were honest
`unavailable` holes (a mid-stage session restart destroyed both copies of the
starting count) and are excluded.

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

Build and review dominate; the five pre-build "thinking" stages sum to about
14M tokens/issue. About 97% of the whole bill is cache reads, the cheapest
token type, which shapes which levers matter (see ranking below).

## ACTIVE experiment: model tier (arm 2, mixed fleet, quality gates keep Opus)

**Variable:** the model each agent runs, placed by role rather than
uniformly. Matt pushed back on the all-Sonnet design: a uniform downgrade
maximizes savings but not savings per unit of risk. This arm keeps
`claude-opus-5` at the two places where an error is most expensive to inherit
and runs `claude-sonnet-5` everywhere else. (Matt upgraded the economy tier
at setup time: sonnet-5 is both newer-generation than the sonnet-4-5 in the
first spec AND cheaper.)

| agent | role | arm-2 model | rationale |
|---|---|---|---|
| obi-wan | architecture | **opus-5** | cheap stage (3.8M) whose errors are expensive downstream; about \$1.20/issue premium is the cheapest insurance in the system |
| chewie | review + smoke | **opus-5** | the last gate before merge, protecting the cheaper builders; about \$3/issue premium |
| han / luke | builders | sonnet-5 | biggest stage (14.5M) → biggest savings; defects are what the Opus reviewer exists to catch |
| yoda | triage/challenge/verdict | sonnet-5 | rubric-driven classification; months of Sonnet history |
| ackbar | deploy | sonnet-5 | checklist and verification work; risky operations gated by Matt |
| boba-fett | QA (off-pipeline) | sonnet-5 | findings re-verified on pipeline entry |
| lando | orchestrator | sonnet-5 | contract-following; hard calls escalate to Matt; his always-on background cost isn't even in the per-issue ledger, so this is pure extra savings |

Rates: Opus 5 / 25 / 0.5 / 6.25 per million tokens vs sonnet-5
2 / 10 / 0.2 / 2.5, a uniform 60% reduction wherever sonnet-5 runs. Opus is
retained on about 41% of baseline issue-tokens (architecture plus
review/smoke); the expected cost multiplier is 0.41 + 0.59×0.40 ≈ 0.65.

**Registered predictions (written before arm 2 ran):**
1. **Cost/issue: median about $21–24 (about 35% below the $33.86 baseline).**
   This is the rate arithmetic over the mixed placement (updated when Matt
   put sonnet-5 in place, a 60% rate cut, instead of the sonnet-4-5 first
   spec at 40%); deliberately about \$2–4/issue above the all-sonnet-5 floor
   to keep Opus at both gates.
2. **Tokens/issue roughly unchanged (within 15%).** A Sonnet builder needing
   more turns would show up as stage-token growth, and that growth IS the
   measured gap between tiers, with a plausible surprise in our favor if
   newer-generation sonnet-5 needs FEWER turns than the 4-5 line would have.
3. **Guardrails flat (kickbacks, review rejections, gate failures).** The
   design bet is that they hold BECAUSE the gates kept Opus. If they hold,
   the follow-up arm drops Chewie to Sonnet to test whether the review gate
   actually needed the premium model.
4. Per-model attribution comes free (every report records the model read
   from the session log), so savings can be broken down by role regardless
   of outcome.

**Interpretation note, honest:** a mixed fleet measures "how much premium can
be shed safely" rather than a clean single-variable rate effect. That is
slightly muddier as science, but operationally the right question for the
bill-payer.

**Protocol:** set each agent's model as tabled → restart the fleet's
sessions → run about 3 comparable snapdex issues under normal gates →
compare via the ledger's per-model stage rows, floor basis, same
stage-profile analysis as baseline. No shared-repo updates mid-arm; no pod
restarts mid-issue.

### Arm-2 results (accumulating)

| issue | tokens | cost (floor) | kickbacks | notes |
|---|---|---|---|---|
| snapdex#1000 (view switcher) | about 60M | **$22.63** | 1 | yolo; first fast-path-priced row; 1 lower-bound stage (build session log rotated mid-stage) |
| snapdex#1001 (dex-card link) | 75.0M | $33.07 | 1 | yolo; 1 hole (obi-wan starting count lost) |
| snapdex#1008 (report-sheet styling fix) | 44.1M | **$20.06** (full) | 1 | non-yolo, ZERO holes, the best-matched datum; independent recomputation matched the official row to the cent |

The first two arm-2 issues (#1000, #1001) ran with the yolo label, the
team's fast-track mode that skips the human approval gates. That differs
from the gated baseline and is flagged as a confound (a difference between
the arms that could distort the comparison). The closer, #1008, ran under
normal gates. Model placement was verified from the session-log model on
every report: opus-5 only at architecture and review/smoke, sonnet-5
everywhere else.

**RESULT (arm complete, n=3):** three comparisons, one answer.

| comparison | result |
|---|---|
| medians (baseline $33.86 → arm-2 $22.63) | **−33%** |
| matched clean small-bugs (#995/#999 avg $28.29 → #1008 $20.06) | **−29%** |
| per-issue re-pricing (each arm-2 issue's actual tokens re-priced at all-Opus rates) | **−34%, −34%, −35%** |

The registered prediction was a $21–24 median (about 35%): the arm landed at
$22.63, inside the band, and the re-priced comparisons sit on the rate
arithmetic almost exactly, meaning the savings came from rates, not from
behavior change. Token volumes ran high on the two yolo issues (60–75M vs
the 46M baseline median) but the non-yolo closer (#1008, 44.1M) matched
baseline volume. That is consistent with prediction #2's "volumes unchanged"
at matched scope, and it attributes the inflation to issue scope and yolo
mode rather than to Sonnet needing more turns.
**Scrutinizing the negative effects (the conclusion's second half):**
kickbacks appeared in 3 of 3 arm-2 issues vs 1 of 4 in baseline (with a
second baseline issue showing re-runs). Quantified as REWORK, the cost of
duplicate-stage re-runs per issue:

| arm | rework incidence | rework share of issue cost | where the rework happened |
|---|---|---|---|
| baseline (opus) | 2/4 issues | mean 6.9% (about \$2.93/issue) | thinking stages only (architecture, challenge) |
| arm 2 (mixed) | 3/3 issues | mean **18.3%** (about \$5.06/issue) | **moved downstream**: implementation and review re-runs on 2 of 3 issues (#1001: 30% of its cost, including two review passes) |

The downstream shift is the interesting symptom: the Opus review gate
kicking back Sonnet-built work is the gate doing exactly its job, at a
price. In this sample the rate savings (about \$11/issue) paid the added
rework (about \$2.1/issue) roughly five times over, so the trade clearly
won. But three costs stay unmeasured at this sample size and time window:
defects that escape the gate entirely (post-ship bugs), the wall-clock time
and human-approval load from re-review loops, and whether rework compounds
on larger issues (#1001, the largest, had the worst share). The follow-up
arm's design should hold model placement and measure rework FIRST. Rework,
not the headline rate, is where cheaper models exact their tax.

**Bottom line for the bill-payer: role-aware model placement cut cost per
issue by roughly a third while keeping the premium model at both judgment
gates, and the ledger now prices that trade to the cent per role.**

## Designed follow-up: charter size (`full` vs `lite`), not yet run

The original variable, deferred in favor of the bigger lever. Design:
per-role extracts of the roughly 140KB of team documentation
(CHARTER+CONTRACTS+DECISIONS) every agent re-reads: keep the binding wire
contracts and each role's own sections; drop other roles' prose, the audit
ledger, and history (at least 60% smaller); tag reports `VARIANT=lite`; run
as a time-blocked arm. Registered hypothesis (from the baseline analysis):
**8–12% cost reduction** ($3–4 off the median), concentrated 15–25% in the
thinking stages, with the mechanism visible as reduced cache-write and
first-call input tokens. A null result is plausible if agents already read
the charter lazily. Guardrail: kickbacks must not rise, since one kickback
(about \$10, per #997) erases the savings.

## Lever ranking (from the baseline data)

| lever | est. impact | note |
|---|---|---|
| model tier per role | 25–45% | rates multiply the whole bill (ACTIVE) |
| API-call efficiency | 15–25% | cost = context × about 220 calls/issue |
| review depth policy | 10–15% | review (10.2M) rivals build (14.5M) |
| charter size | 8–12% | designed follow-up |
| pipeline shape | about 10% | 5 thinking stages ≈ 14M tokens/issue |
| kickback prevention | episodic | one kickback ≈ $10 of rework |

## Data provenance

Rows for #995/#997 are Lando's official `cost-ledger.jsonl`; #998/#999 were
aggregated from the same GitHub markers with the same script (`issue-cost.sh`)
run locally ahead of Lando's close-out job (method verified identical on
#995: $28.19 both ways). Arm 2: #1000/#1008 are official rows; #1001 was
aggregated locally the same way, which is why the mirrored ledger snapshot
has no #1001 row. #997's official row carries full token counts but honestly
declines a dollar total (`priced: false` because of its `unavailable` hole);
the $49.26 floor above is the local sum of its priceable stages via the same
script. Rates: LiteLLM@b45b4b7 via kyber's generated feed;
no hand-typed prices anywhere in the pipeline.
