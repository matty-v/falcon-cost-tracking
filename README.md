# Per-issue cost tracking for an AI dev team

*Origin take-home assessment — Matt Voget*

I run a fleet of eight AI coding agents (the "Falcon Dev Team") that work GitHub
issues end-to-end — triage, architecture, implementation, review, deploy — on a
self-hosted platform I built called [Kyber](docs/kyber-explainer.md). The team
ships real software, and it spends real money doing it, against a single shared
Anthropic account cap. Until this project, I could not answer the most basic
management question about it: **what does an issue cost?**

This project makes the team account for its own spend:

1. **Mini-charter** — when work kicks off on an issue, the orchestrator agent
   (Lando) posts a plan card to the issue's Discord thread: scope, which agents
   are involved in which roles, and which model each runs.
2. **Per-stage self-reporting** — every agent measures its own token usage
   (input / output / cache read / cache write, per model) for its stage of the
   work, by summing its own session transcript, and posts it: a human-readable
   bullet on Discord, a machine-readable marker on the GitHub issue.
3. **Final cost on close** — Lando aggregates the per-stage reports, prices them
   from a machine-generated rate table, cross-checks the platform's metrics API,
   posts a cost summary card to the Discord thread, and appends a row to a
   running **cost ledger** (`cost-ledger.jsonl`) so issues are comparable.
4. **A platform fix** — building this exposed that Kyber's metrics pipeline
   silently dropped output tokens and priced cache writes at $0. Fixed in a
   standalone PR (kyber#23, released as v1.0.1). Where it mattered here:
   the team's price table is a copy of Kyber's machine-generated rate feed,
   and cache-write rates — ~12% of every issue's bill — exist in that feed
   only because of this fix; it's also what makes the platform's metrics a
   meaningful independent cross-check against the agents' self-reports
   instead of a number known to be wrong. The ledger's token *counts* never
   depended on it (self-reports read transcripts directly).
5. **An experiment** — swap the underlying models by role and measure the
   effect on **both cost and quality**: premium model kept only at the
   architecture and review gates, a cheaper tier everywhere else, hypothesis
   registered before running, kickbacks scrutinized as hard as the savings.

## Where the changes live

| Piece | Repo | Link |
|---|---|---|
| Platform fix: output tokens + cache-write pricing | `matty-v/kyber` | [kyber#23](https://github.com/matty-v/kyber/pull/23) (merged) |
| `token-usage.sh`, charter/contract changes, roster, rates snapshot | `matty-v/falcon-dev-common` | merged as fdc#118 — private repo, mirrored in [`docs/mirror/`](docs/mirror/) |
| Lando: mini-charter, aggregation, ledger | `matty-v/lando-agent` | merged as lando-agent#105 — private repo, mirrored in [`docs/mirror/`](docs/mirror/) |
| Experiment protocol + results | this repo | [`docs/experiments/cost-per-issue.md`](docs/experiments/cost-per-issue.md) |
| Process log (prompts, pushback, AI mistakes) | this repo | [`PROCESS.md`](PROCESS.md) |

## Write-up

### The problem, and why I cared

I pay one Anthropic bill for eight AI agents that ship real software, and
until this project I couldn't answer "what did that issue cost?" — the
platform's metrics understated spend (output tokens were silently dropped),
and attribution stopped at (agent, model): concurrent work smeared together
in time-window queries. This wasn't a toy annoyance: the team shares one
account spend cap, and one heavy run can block everyone. So the tool is a
cost-accountability layer for an AI dev team: each agent measures its own
per-stage token spend from its own transcript, the orchestrator prices and
aggregates at issue close, a durable ledger makes issues comparable, and an
experiment framework turns "should we use cheaper models?" into a measured
answer instead of a vibe.

### How I used AI, and what worked

Claude Code ran the whole build: parallel research subagents mapped two
codebases before planning; design subagents produced file-level plans I
approved with modifications; an implementation subagent built the platform
fix while the main session built the team layer; three independent
adversarial reviewers tore into all of it before merge (22 verified
findings); and live monitors watched the fleet work real issues, surfacing
failures as they happened. What worked best was structural: AI proposing with
arithmetic, me redirecting with judgment (see PROCESS.md for every instance),
and — the single most repeated lesson — putting anything that must happen
reliably into a tested script rather than prose instructions. LLM agents
followed script invocations 8/8; they skipped prose procedures twice.

### Where the AI got things wrong

It's all in PROCESS.md's "Trial and error" section, but the highlights: the
AI's first output-token design was structurally lossy and had to be redesigned
after its own reviewers confirmed sampling gaps, TTL double-counts, and
tuple collisions; its cost scripts shipped with a stale rate table that would
have silently halved every cost figure; env-var payload passing died on a
kernel limit in production (diagnosed, remarkably, by one of the fleet's own
agents); its reconciler masked its own death with exit-0 + stderr warnings;
and it once declared Discord broken from an absent marker when the thread
existed all along. Every one of these was caught — by tests the AI wrote, by
reviewers the AI ran, by the fleet itself, or by me — and every failure
produced an honest "unavailable/partial/unpriced" artifact instead of a
plausible wrong number. That fail-loud discipline was the core design bet.

### What the experiment found

**The experiment: change the underlying models by role and measure both cost
and quality.** Baseline ran all eight agents on claude-opus-5 (n=4 live
issues); the test arm kept opus-5 only at the two judgment gates
(architecture, review) and ran claude-sonnet-5 everywhere else (n=3 live
issues). Hypotheses were registered in the repo before the arm ran.

| | Hypothesis (registered first) | Result |
|---|---|---|
| **Cost / issue** | median $21–24 (~35% below the $33.86 baseline) | **$22.63 (−33%)** — counterfactuals (same tokens at opus rates) −34/−34/−35% |
| **Token volume** | roughly unchanged (±15%) | matched at comparable scope (44M vs 46M median); elevated only on the two bigger yolo-labeled issues |
| **Quality (the scrutiny)** | kickbacks / rejections stay flat | **Not flat: rework rose 6.9% → 18.3% of issue cost**, hit 3/3 test issues, and moved downstream into build/review loops |
| **Net** | savings if guardrails hold | Savings (~$11/issue) paid the added rework (~$2.10/issue) ~5× over — *in this sample*; escaped defects and scaling unmeasured |

Behind the table: three lenses agree on the cost result — medians −33%,
matched clean-bug pairs −29%, per-issue counterfactuals on the registered
rate arithmetic — meaning the savings came from where the models were
placed, not from changed behavior.
The quality row is the finding I care most about. The rework didn't just
increase — it *moved*: baseline rework lived in cheap thinking stages, while
the test arm's rework was the retained opus reviewer kicking sonnet-built
work back through expensive build/review loops. The gate did its job, and
that's precisely the tax cheaper models pay. The honest claim is therefore
"a third cheaper, with a quantified and rising rework tax the next
experiment must watch first" — not "cheaper models are free." Escaped
defects (bugs the gate misses entirely), wall-clock from re-review loops,
and how rework scales with issue size remain unmeasured at n=3. Full
analysis with registered predictions:
[docs/experiments/cost-per-issue.md](docs/experiments/cost-per-issue.md).

### Known limitations and rough edges

- **Small n, honest framing**: 4 baseline + 3 arm-2 issues; medians and
  per-issue counterfactuals, not statistics. The arms also differ in gating
  (arm 2 ran partly yolo-labeled) — flagged inline.
- **Baseline durability**: mid-stage session recycles destroyed 4
  stage-baselines across the runs (the one-shot comment post is the weak
  link); those stages price as floors. The verify-and-retry fix is designed
  but held back by the mid-experiment vendor freeze.
- **Lando's own cost is invisible** to the per-issue ledger — the orchestrator
  never dispatches itself, so its always-on background spend isn't attributed.
- **The metrics cross-check is unfinished business**: kyber v1.0.1 fixed the
  platform's output-token gap, but the deployed cross-check rarely ran (the
  close-out fast path kept detouring; the cron backstop skips it by design).
- **Roster drift**: the planned-models file is stale (the fleet upgraded
  twice); every row honestly flags planned≠actual rather than hiding it.

### What I'd do with more time

Run the charter-size arm (designed, hypothesis registered); make partial rows
carry a first-class cost floor; fix baseline durability; per-stage context
curation (the lever ranking says call-count and review policy are the next
big dials); and teach Kyber itself per-issue attribution so the platform and
team layers converge on one number.
