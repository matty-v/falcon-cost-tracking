# Kyber and the Falcon Dev Team, from zero

*You've never heard of Kyber. This page is everything you need to follow the
rest of the submission.*

## Kyber in one paragraph

[Kyber](https://github.com/matty-v/kyber) (open source, Apache 2.0) is a
self-hosted platform for running **long-lived AI coding agents as Kubernetes
pods**. Each agent is a custom resource (`Agent` CRD) that a controller reconciles
into a pod running an agentic coding session (Claude Code or Codex) with a
persistent filesystem, a durable identity, and its own model configuration. A
control plane exposes a REST API and a PWA for managing the fleet; sidecars
handle comms (Discord/Telegram), transcript retention, and telemetry. Think:
"what if each AI agent were a pet server with a personality, not a stateless
function call."

The pieces that matter for this project:

- **Identity repos.** Each agent's durable self — its operating manual, role
  definition, memory, skills — is a private GitHub repo cloned into the pod at
  boot. Shared team conventions are *vendored* into each identity repo from a
  common repo and SHA-pinned, like a dependency.
- **Inbound webhook rail.** Signed HMAC webhooks (e.g. GitHub events) are
  verified, deduplicated, filtered, rate-limited, and delivered into an agent's
  terminal session. This is how work reaches an agent.
- **Discord sidecar.** Agents post to Discord through a per-pod sidecar that owns
  the bot token (the agent never sees it) and exposes a local `reply` tool.
- **Token telemetry.** An in-pod reporter tails the agent's own session
  transcript and reports token usage up to the control plane, which accumulates
  it per (agent, model) and prices it from a machine-generated rate table
  (sourced from a public pricing feed — no hand-maintained prices anywhere).

## The Falcon Dev Team in one paragraph

The Falcon Dev Team is eight agents on a Kyber cluster that work GitHub issues
as a real dev team, governed by a shared charter repo (`falcon-dev-common`):
**Lando** (orchestrator — receives all GitHub webhooks, dispatches all work,
sole interface to the human), **Yoda** (product/triage), **Obi-wan**
(architecture), **Han** and **Luke** (builders), **Chewie** (review), **Ackbar**
(deploy/release), **Boba Fett** (QA). An issue moves through a GitHub-label
state machine (`needs-triage → needs-architecture → … → ready-for-implementation
→ merge-requested → needs-delivery`); Lando dispatches the right agent at each
stage via signed envelopes, and workers answer with acks. Every issue gets one
Discord forum thread where Lando posts a kickoff card, each agent posts terse
INTENT/OUTCOME updates for its stage, and Lando closes with a completion
summary. The human (me) approves work at defined gates.

## The problem this submission solves

Before this project, the team's relationship to money was:

- Only Lando ever looked at cost, by querying the platform's metrics API **for a
  time window** — so "what this issue cost" was really "everything those agents
  did during that window," indistinguishable from concurrent work.
- No worker ever reported its own usage or model. The ack contract, the GitHub
  comment trail, and the Discord thread carried zero token data.
- There was no ledger — no way to compare cost across issues, which means no way
  to measure whether any change makes the team cheaper.
- And the platform numbers themselves were wrong: Kyber's metrics pipeline
  parsed **output tokens** from the transcript and then dropped them — never
  stored, never priced — while the UI rendered a permanently-zero Output column.
  Output is the most expensive token type (5× the input rate on current Anthropic
  models). Cache writes were counted but priced at $0.

So: the platform understated spend, and the team couldn't attribute what spend
it did see. This submission fixes both layers — accuracy in the platform,
attribution in the team.

## How the fix is layered

```
┌─ Team layer (falcon-dev-common + lando-agent) ─────────────────┐
│  mini-charter on kickoff → per-stage self-reports (transcript  │
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
workers' transcript-based self-reports against the platform's windowed metrics
and labels any discrepancy instead of averaging it away. Self-reports are the
authoritative per-issue number (they attribute by stage, and they always include
output tokens); the metrics API is the independent backstop.

*(Diagram and deeper architecture detail to be refined in Phase 5.)*
