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
| Experiment protocol + results | this repo | [`docs/experiments/charter-size.md`](docs/experiments/charter-size.md) *(pending)* |
| Process log (prompts, pushback, AI mistakes) | this repo | [`PROCESS.md`](PROCESS.md) |

## Write-up

*(Completed in Phase 5 — sections per the assignment: problem & why; how AI was
used and what worked; where the AI got things wrong; what I'd improve; known
limitations.)*
