# Kyber and the Falcon Dev Team, from zero

*You've never heard of Kyber. This page is everything you need to follow the
rest of the submission.*

## Kyber in one paragraph

[Kyber](https://github.com/matty-v/kyber) (open source, Apache 2.0) is a
self-hosted platform for running **long-lived AI coding agents on
Kubernetes**. Each agent is declared in configuration, and Kyber turns that
declaration into a running pod: an agentic coding session (Claude Code or
Codex) with its own persistent files, durable identity, and model settings.
A central service provides a REST API and a web app for managing the fleet,
and small helper processes running beside each agent handle messaging
(Discord/Telegram), transcript retention, and usage telemetry. Think:
"what if each AI agent were a pet server with a personality, not a stateless
function call."

The pieces that matter for this project:

- **Identity repos.** Everything that makes an agent itself (its operating
  manual, role definition, memory, and skills) lives in a private GitHub
  repo that is cloned into the pod when it starts. Shared team conventions
  are copied into each identity repo from a common repo and pinned to an
  exact version, the way a software dependency would be.
- **Inbound webhooks.** Signed webhook events (for example, GitHub
  activity) are verified, deduplicated, filtered, rate-limited, and
  delivered into an agent's terminal session. This is how work reaches an
  agent.
- **Discord helper.** Agents post to Discord through a small companion
  process in each pod. It holds the Discord credentials (the agent never
  sees them) and gives the agent a simple local tool for posting.
- **Token telemetry.** A reporter inside each pod watches the agent's own
  session log and sends token usage up to the central service, which totals
  it per agent and model and prices it from a rate table generated from a
  public pricing feed (no hand-maintained prices anywhere).

## The Falcon Dev Team in one paragraph

The Falcon Dev Team is eight agents on a Kyber cluster that work GitHub issues
as a real dev team, governed by a shared charter repo (`falcon-dev-common`):
**Lando** (orchestrator: receives all GitHub webhooks, dispatches all work,
sole interface to the human), **Yoda** (product/triage), **Obi-wan**
(architecture), **Han** and **Luke** (builders), **Chewie** (review), **Ackbar**
(deploy/release), **Boba Fett** (QA). An issue moves through stages tracked by
GitHub labels (`needs-triage → needs-architecture → … → ready-for-implementation
→ merge-requested → needs-delivery`). At each stage Lando sends the right agent
a signed work order, and the worker replies with an acknowledgment. Every issue
gets one Discord forum thread where Lando posts a kickoff card, each agent posts
short intent and outcome updates for its stage, and Lando closes with a
completion summary. The human (me) approves work at defined gates.

## The problem this submission solves

Before this project, the team's relationship to money was:

- Only Lando ever looked at cost, by querying the platform's metrics API
  **for a time window**, so "what this issue cost" was really "everything
  those agents did during that window," indistinguishable from concurrent
  work.
- No worker ever reported its own usage or model. The worker replies, the
  GitHub comment trail, and the Discord thread carried zero token data.
- There was no ledger, so there was no way to compare cost across issues,
  which means no way to measure whether any change makes the team cheaper.
- And the platform numbers themselves were wrong: Kyber's metrics pipeline
  parsed **output tokens** from the transcript and then dropped them (never
  stored, never priced) while the UI rendered a permanently-zero Output
  column. Output is the most expensive token type (5× the input rate on
  current Anthropic models). Cache writes were counted but priced at $0.

So: the platform understated spend, and the team couldn't attribute what spend
it did see. This submission fixes both layers: accuracy in the platform,
attribution in the team.

## How the fix is layered

```
┌─ Team layer (falcon-dev-common + lando-agent) ─────────────────┐
│  plan card on kickoff → per-stage self-reports (session-log    │
│  deltas, embedded in existing GitHub comment markers) → Lando  │
│  aggregates, prices, cross-checks, posts summary, appends      │
│  cost-ledger.jsonl                                             │
└────────────────────────────────────────────────────────────────┘
┌─ Platform layer (kyber PR) ────────────────────────────────────┐
│  output tokens wired end-to-end (parser → accumulator → delta  │
│  → metrics API → UI) + cache-write pricing from the upstream   │
│  feed → the metrics API stops understating spend               │
└────────────────────────────────────────────────────────────────┘
```

The two layers meet in Lando's cross-check: at issue close, Lando compares the
workers' self-reports (computed from their own session logs) against the
platform's time-window metrics and labels any discrepancy instead of averaging
it away. Self-reports are the authoritative per-issue number (they attribute by
stage, and they always include output tokens); the metrics API is the
independent backstop.
