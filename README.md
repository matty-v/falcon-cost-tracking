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
4. **A platform fix** — building this exposed that Kyber's metrics pipeline was
   silently dropping output tokens (the dominant cost term) and not pricing
   cache writes. Fixed in a standalone PR so the platform numbers stop lying.
5. **An experiment** — with the ledger in place: does shrinking the ~140KB team
   charter each agent loads reduce cost per issue? (Variable: context size.)

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

With the instrument in place, we ran two arms on live issues. Baseline (n=4,
all claude-opus-5): median **$33.86/issue**, 46M tokens, ~97% cache reads.
Arm 2 (n=3, role-aware mix — opus kept only at the architecture and review
gates, sonnet-5 everywhere else): median **$22.63/issue**. Three lenses agree:
medians −33%, matched clean-bug pairs −29%, and per-issue counterfactuals
(actual tokens repriced at all-opus) −34/−34/−35% — squarely on the registered
prediction of ~35%, meaning the savings came from rates, not behavior change.
The conclusion is deliberately two-sided. Costs fell — but the cheaper
models exacted a measurable tax: rework (duplicate-stage re-runs) rose from
6.9% of issue cost in baseline to 18.3% in the mixed arm, hit all three
arm-2 issues, and — the telling part — moved downstream from cheap thinking
stages to expensive implementation/review loops: the retained opus review
gate kicking back sonnet-built work. In this sample the rate savings paid
for the added rework about five times over, so the trade won. But escaped
defects, wall-clock from re-review loops, and how rework scales with issue
size are all unmeasured at n=3 — so the honest claim is "a third cheaper,
with a quantified and rising rework tax that the next experiment must watch
first," not "cheaper models are free." Full analysis with registered
predictions: [docs/experiments/cost-per-issue.md](docs/experiments/cost-per-issue.md).

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
