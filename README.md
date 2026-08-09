# Per-issue cost tracking for an AI dev team

*Origin take-home assessment, Matt Voget*

I run a team of eight AI coding agents (the "Falcon Dev Team") that works
GitHub issues end to end: triage, design, build, review, deploy. It runs on
[Kyber](docs/kyber-explainer.md), a platform I built for hosting long-running
AI agents. The team ships real software using shared credentials on a Claude Max
subscription. The question I wanted to answer: **how much would issues cost
using straight API rates?**

## How the team works an issue

Each box below shows a pod that runs on a k8s cluster. Each pod runs a
Claude Code session with different skills for performing the entire SDLC for
a project. Lando (the team lead) receives every GitHub event and routes each
handoff using webhooks to dispatch prompts to the other agents.

<img src="docs/assets/team-flow.svg" width="100%" alt="How the team works an issue: GitHub issue flows through triage, design, challenge, deploy check, human approval, build, review, deploy, smoke test, and close-out, snaking across three rows. Gold boxes run the premium model at the judgment gates; blue boxes run the cheaper model; dashed red arrows mark work sent back.">

Before this assignment, agents were performing their roles but never
tracking costs, i.e. tokens on a given model. After this assignment, they now
run [`token-usage.sh`](docs/mirror/token-usage.sh) twice per stage: once at
pickup (an odometer reading of its session) and once at completion (posting
what its stage used and on which model). At the end, Lando adds it all up
with [`issue-cost.sh`](docs/mirror/issue-cost.sh) to show me a final number.

## An Experiment in Model Cost versus Quality

Part of this assignment was to first add cost tracking. I had all the
agents in the dev team running Opus 5 models before, which was inefficient.
I hypothesized that I could get away with cheaper models on some agents with
the hope of keeping quality high. To orchestrate and execute this experiment
I ran another local Claude Code session on Fable 5. The job of this agent
was to help me set up the experiment, implement cost tracking across the AI
dev team, and measure and publish the results.

The test setup: keep Opus 5 only at the design stage and the code-review
gate, and run Sonnet 5 everywhere else. I compared 3 issues (on another
personal project, Snapdex, [snapdex.ai](https://snapdex.ai)) using the new
setup against the 4-issue baseline.

The result: costs came down by about a third.

As for quality, the team under the new model arrangement had more issues
getting kicked back at the design and code-review gates (Obi-wan and Chewie
running Opus 5), but that extra spend was offset by the savings from the
cheaper models doing the building. Full detail, including the predictions I
wrote down before running it:
[docs/experiments/cost-per-issue.md](docs/experiments/cost-per-issue.md).

| | Before (all premium model) | Prediction (written first) | Result |
|---|---|---|---|
| **Cost per issue** | $33.86 median | $21 to $24 | **$22.63, down 33%** |
| **Work volume** | 46M tokens median | unchanged, within 15% | 44M on comparable issues: unchanged |
| **Quality** | 6.9% of issue cost was redone work | stays flat | **18.3% redone, on all 3 test issues** |
| **Net** | | savings win if quality holds | Savings of about $11 per issue bought about $2.10 of added rework: 5 to 1 in favor, in this sample |

## How I used AI, and what worked

Claude Code ran the whole build:

- Research agents mapped two codebases in parallel before any plan was made.
- Design agents produced detailed plans, which I approved with changes.
- One agent built the platform fix while the main session built the team
  changes.
- Three independent AI reviewers attacked the work before merge and produced
  22 confirmed findings, including a redesign of code I had already approved.
- Live monitors watched the agent team work real issues and flagged failures
  as they happened.

The pattern that worked: the AI proposes with arithmetic, I redirect with
judgment. Every instance is in [PROCESS.md](PROCESS.md). The single most
repeated lesson: anything that must happen reliably belongs in a tested
script, not in written instructions (example: [`charter-ensure.sh`](docs/mirror/charter-ensure.sh),
which replaced instructions the agents skipped twice). The agents ran script commands 8 out of
8 times; they skipped written procedures twice.

## Where the AI got things wrong

The full list is in [PROCESS.md](PROCESS.md) ("Trial and error" section). Highlights:

- Its first design for counting output tokens could miss work, double-count
  after gaps, and mistake new work for old. Its own reviewers caught all
  three; it was redesigned.
- Its cost scripts shipped with an outdated price table (caught in review, [patch](docs/mirror/falcon-dev-common-review-fixes.patch)) that would have
  silently cut every cost figure roughly in half.
- It passed large data the wrong way and hit an operating-system limit in
  production ([fix](docs/mirror/fdc-123.patch)). One of my own agents diagnosed that bug from inside its pod.
- A cleanup job crashed silently for hours because its error messages went
  where nobody looked ([the job](docs/mirror/ledger-reconciler.sh) now reports where its caller reads).
- It once declared Discord broken based on a missing bookkeeping note, when
  the Discord thread existed all along. I corrected it by looking.

Every failure was caught: by tests the AI wrote, by reviewers the AI ran, by
the agent team itself, or by me. And by design, every failure showed up as an
honest "unavailable" or "partial" in the records, never as a made-up number.

## Known limitations and rough edges

- **Small sample.** 4 baseline issues, 3 test issues. Medians and
  per-issue comparisons, not statistics. Two test issues also ran in
  fast-track mode (skipping my approval gates); the cleanest test issue did
  not, and it matched the results.
- **Some readings have gaps.** Agents sometimes restart mid-task, and 4 of
  30 work segments lost their "starting odometer reading." Those issues
  report a known-minimum cost instead of a total. The fix is designed but was
  held back by the code freeze during the experiment.
- **Lando's own cost is not counted.** The team lead never assigns work to
  itself, so its always-on background spending never lands on any issue.
- **The platform second-opinion check rarely ran.** The fix made it
  possible, but the close-out step that runs it kept getting skipped, and the
  fallback that writes the ledger doesn't do the comparison.
- **The plan cards list outdated models.** The team's model roster file
  wasn't updated when I upgraded the fleet. Every report flags the difference
  between planned and actual instead of hiding it.

## What I'd do with more time

- Run the second designed experiment: shrink the 140KB of team documentation
  every agent re-reads, prediction already registered
  ([details](docs/experiments/cost-per-issue.md), 8–12% savings).
- Give partial rows a proper minimum-cost figure instead of a footnote.
- Fix the mid-task restart gap so readings stop getting lost.
- Chase the next two levers the data points at: the number of API calls per
  stage, and how deep code review needs to be.
- Teach Kyber itself to attribute cost per issue, so the platform and the
  team agree on one number.
