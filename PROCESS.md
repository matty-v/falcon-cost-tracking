# Process log — rolling record of the AI-assisted workflow

This is the rolling document the assignment asks for: every prompt, the AI's
process, where I pushed back, and what changed as a result. Entries are appended
as the work happens — nothing here is reconstructed after the fact.

Tooling: Claude Code (CLI) running Claude Fable 5, with background research and
design subagents. The working session runs inside my `kyber` repo checkout.

---

## Session 1 — 2026-08-07

### Turn 1 — kickoff (my prompt)

I pasted the full Origin assignment (reproduced in Appendix A below) and framed
the problem I wanted to solve:

> I need your help to plan and implement the assignment as well as document the
> process along the way. I want the crux of the assignment to focus on solving a
> problem: can we build in cost tracking to the Falcon Dev Team when they work on
> Github issues.
>
> The falcon dev team is a fleet of agents running on a kyber cluster. They are
> defined by their individual agent identity repos but also follow a team charter
> here: https://github.com/matty-v/falcon-dev-common
>
> Assume that the company interviewing me has never heard of kyber, so explaining
> it is part of the submission. The solution to my cost problem may include Kyber
> changes, but also may just be adjusting the skills on the agents in the Falcon
> Dev Team or perhaps tweaking the common files in falcon-dev-common. My general
> guidance is to make the dev team better use Discord to track their work on
> issues. I think that each issue needs a mini-charter posted on discord that
> details the issue or issues being work and specifies which agents are involved.
> Lando helps orchestrate the agent execution. Each agent should post the tokens
> they spent on their part and the LLM used. Finally when issues are closed Lando
> should compute the final cost and post it somewhere.
>
> After the core mechanics are in place, I want to run a targeted experiment on
> how to decrease the cost per issue by tweaking a variable.

**Claude's process:** entered plan mode and launched two parallel research
subagents — one exploring the kyber codebase (architecture, Discord integration,
skills distribution, any existing token/cost telemetry), one exploring
falcon-dev-common and the agent identity repos via the GitHub CLI. While those
ran, it asked me three scoping questions. My answers:

1. **Submission packaging** → a new public repo as the front door (this repo),
   with the real changes landing as PRs in the repos they belong to.
2. **Where the final cost lands** → both a Discord thread summary AND a running
   ledger (I picked two of the three offered options; the ledger matters for the
   experiment comparison).
3. **Experiment variable** → context/charter size.

### Turn 2 — research results and the decision that reshaped scope

The research came back with two findings that changed the shape of the project:

- **Kyber already has a token telemetry pipeline** (an in-pod reporter tails the
  Claude Code transcript → sidecar → control plane → Redis accumulator → a priced
  metrics API), but it has a real bug: **output tokens are parsed and then
  dropped** — never stored, never priced. The PWA even renders an Output column
  that is always zero. Since output tokens are the dominant cost term, every cost
  figure the system has ever produced is understated. Cache-creation tokens are
  counted but unpriced too. And attribution granularity is (agent, model) only —
  nothing ties spend to an issue.
- **The team layer already has cost hooks, but thin ones**: Lando's completion
  summary cites "total cost (est.) from Kyber's metrics API", queried by time
  window only. Workers never report their own tokens or model. No ledger exists.
  There is a standing team directive: never fabricate cost data — unpriced must
  render as "unavailable", never $0.00.

Claude asked three more questions. This is where I pushed back on its
recommendation for the first time:

1. **The kyber output-token bug**: Claude recommended filing it as a GitHub issue
   and letting the Falcon team fix it through its own pipeline — a meta-demo of
   the new cost tracking. I overrode: **I'll fix it myself in kyber, outside the
   team**, because accurate platform metrics are a *prerequisite* for the cost
   tracking to be truthful, not a good first test subject for it.
2. **Live runs** → small batch, ~3 issues per experiment arm (the team shares one
   Anthropic account spend cap; a big batch can exhaust it).
3. **Ledger home** → `lando-agent/reports/cost-ledger.jsonl`, next to Lando's
   existing committed ship reports.

Claude then launched two parallel design subagents: one for the team-layer
mechanics, one for the kyber fix.

### Turn 3 — "record everything"

I reminded Claude to record everything, including the conversation turns
themselves. It began keeping this log inside its plan file (plan mode restricts
writes to that single file) with the explicit step of transposing it here as the
first act of implementation — which is the document you are reading.

### Turn 4 — designs merged into the final plan

The two designs landed:

- **Team layer**: a new `token-usage.sh` in falcon-dev-common that each worker
  runs at stage pickup and completion — it sums finalized assistant entries
  across the agent's own transcript tree (deduplicated by message id, skipping
  still-streaming entries, whole-tree scan so transcript rotation is harmless)
  and embeds the baseline and the per-stage report as hidden HTML-comment markers
  inside the pickup/complete GitHub comments the team already posts. The
  worker→Lando ack contract stays untouched (changing it would require a platform
  binding change). Lando aggregates the markers at issue close, prices them from
  a vendored copy of kyber's machine-generated rate table (provenance stamp
  included — the team's "no hand-typed prices" directive holds), cross-checks
  against the metrics API with labeled discrepancy notes, posts the Discord
  summary card, and appends a ledger row. A `VARIANT` file in the vendored
  charter tags every report with the experiment arm automatically.
- **Kyber fix**: a file-level plan wiring output tokens end-to-end and pricing
  cache-creation from the upstream LiteLLM feed (verified: the pinned feed
  already exposes `cache_creation_input_token_cost` — no hardcoded prices). One
  genuinely subtle design point: output tokens are per-message, not cumulative,
  and the in-pod reporter re-POSTs the same last message every poll — so the
  delta rule counts output only when the usage tuple changes (i.e., a genuinely
  new message).

Two places I (or reality) overruled the AI, recorded honestly:
- The team-layer designer recommended ≥6 issues per experiment arm for
  statistical weight; I had chosen ~3 for budget reasons. We kept 3 and will
  report medians with an explicit "directional, n=3" caveat.
- Claude flagged that the summed estimates exceed the assignment's 4–8 hour
  guideline (the kyber fix alone is ~1 nominal developer-day) and recorded a trim
  order in the plan rather than pretending the scope fits.

I approved the final plan. Phases: (0) this repo + process doc, (1) kyber PR,
(2) team-layer changes, (3) end-to-end dry run + baseline arm, (4) charter-size
experiment, (5) write-up.

### Turn 5 — implementation begins

Plan approved; Claude created the phase task list, created this repository, and
transposed the log. Next: the kyber PR.

### Session 1, continued — Phases 1+2 in parallel

Claude delegated the kyber fix (Phase 1) to a background implementation agent
with the full file-level design (branch `fix/output-token-cost`, no push until I
review), and built the team layer (Phase 2) in the foreground:

- **`scripts/token-usage.sh`** (falcon-dev-common) — the per-stage self-report.
  Wrote it plus an 18-case test suite. The tests immediately caught one real
  bug: the filename sanitizer used `echo`, whose trailing newline got translated
  into a stray `_` in the baseline filename. Worth noting: the AI wrote both the
  bug and the test that caught it — the value of insisting on tests for "simple"
  shell scripts.
- **`scripts/issue-cost.sh`** — Lando's close-path aggregator (collect markers →
  price from the vendored rate snapshot → cross-check metrics → emit the ledger
  row). 17-case suite covering the truthfulness ladder (`exact` / `lower_bound` /
  `unavailable`), unpriced-model handling (never $0.00), date-suffix rate lookup,
  and the cross-check labeling of the platform's missing-output-tokens gap.
  Design choice made here (deviating slightly from the plan, which had this
  logic inline in Lando's skill doc): ~200 lines of aggregation/pricing logic
  belongs in a *tested script*, not in prose instructions an LLM re-interprets
  every run. The skill doc now just calls the script.
- Charter/contract edits: CONTRACTS **§10** (normative marker registry),
  CHARTER comment shapes + Lando bookends, `handle-inbound.md` Steps 2b/4b,
  the single chartered 📊 ban-list carve-out in `discord-post.md`,
  `config/team-roster.yaml`, the rates snapshot copy, `VARIANT`, CHANGELOG.
- Lando skill edits: Step 1.7 mini-charter (marker + 🧭 card), Step 6b rewired
  to call `issue-cost.sh`, append the ledger, and derive all card/DM cost lines
  from the ledger row (the metrics API demoted from source-of-truth to labeled
  cross-check). Claude caught its own dangling `$PR_NUMBERS` reference during
  review and added the missing derivation.
- Ran fdc's full existing test suite: 3 failures — verified **pre-existing on a
  clean tree** (dev-lock / pre-commit-guard / sync-vendor; look
  macOS-vs-pod-environment related), so not chased. Both new suites pass.
- Committed on `feat/cost-tracking` branches in both private repos and mirrored
  the scripts + full patches into `docs/mirror/` here, since reviewers can't see
  the private repos.

### Session 1, continued — the kyber PR lands ([kyber#23](https://github.com/matty-v/kyber/pull/23))

The background implementation agent finished the platform fix: output tokens
wired end-to-end (parser → snapshot → accumulator → delta → windowed series →
metrics API → PWA), cache-creation priced from the upstream LiteLLM feed
(regenerated at the already-pinned sha — byte-identical across runs, no
hand-typed prices), and the subtle part — the per-message output delta rule
(count output only when the usage tuple changed; an identical re-report from the
interval reporter contributes zero) — pinned by an 8-case white-box test.

Human/AI interaction notes for this phase:
- I (via Claude's review pass) read the critical hunks before anything was
  pushed: the delta rule, the accumulator back-compat (missing `output` hash
  field intentionally reads 0), and the pricing math. This is the change where a
  silent bug would corrupt cost data going forward, so it got the closest read.
- The agent surfaced honest deviations rather than papering over them: no
  Redis-backed accumulator test (would need a new miniredis dependency — repo
  rules say ask first), the regeneration timestamp is the actual re-fetch time,
  and `make lint`/nodeagent tests fail on macOS on clean main too (CI is Linux).
  Each was verified against a clean checkout instead of being taken on faith.
- Verification: linux build+vet green, targeted + full test suites green
  (pre-existing darwin failures unchanged), pwa-views 601 tests + version bump
  0.21.0, helm lint/template green.

Phase 1 + Phase 2 are now code-complete. What remains needs the LIVE system and
me in the loop (the pipeline's approval gates are mine by design): merge fdc +
lando-agent branches, fan out the vendor re-pin to the 8 agent repos, merge +
release kyber#23, then the scratch-issue E2E run and the two experiment arms.

## Session 2 — "review, fix, and then merge the 3 branches"

My prompt: exactly that, one line. Claude ran three independent adversarial
reviews in parallel — two custom review agents on the private-repo branches and
the code-review tooling on kyber#23 (whose first run targeted the wrong branch
and had to be redone — noted honestly: the tool reviewed the checked-out docs
branch instead of the PR).

This round is the strongest evidence in this whole exercise for the "don't
accept the first thing the AI gives you" principle — **the AI's reviewers tore
real holes in the AI's implementation**, and every hole was verified before
being fixed (several were reproduced with actual commands, not just argued):

**falcon-dev-common (8 findings, all fixed, +12 regression tests):**
1. The vendored rate table was stale — zero `cache_creation` lines, so the
   ledger would have silently excluded ~half of real Claude Code spend while
   labeling totals `priced: true`. (Fixed from kyber's regenerated feed. The
   irony is noted: the cost-tracking branch shipped with the exact class of
   silent understatement it was built to eliminate.)
2. Resumed sessions could FABRICATE spend: dedup attributed replayed history to
   whichever file sorted first lexically, so a `--resume` could inject
   pre-baseline tokens into a "lower_bound" report. Reproduced, then fixed with
   oldest-mtime-first attribution + a regression test.
3. `gh api --paginate` emits one JSON array per page — a single `json.loads`
   would choke past 100 comments and silently drop every usage marker on a
   busy issue. The tests' gh stub had masked it. Fixed with a raw_decode loop.
4. The fenced-fallback baseline marker was unrecoverable after a pod recycle
   (recovery only knew the one-line form).
5. The baseline blob rode inside the load-bearing `falcon:pickup` comment and
   grew without bound — past GitHub's 64KB body limit it would have taken
   stall-recovery down with it. Now: pruned + posted as its own comment.
6. Skill-doc bash blocks defined a variable in one block and consumed it two
   blocks later — but shell state doesn't persist between an agent's separate
   tool calls, so the usage marker would silently vanish. (A very AI-specific
   bug: instructions that are correct prose but wrong as executed reality.)
7. An empty/misconfigured transcript dir yielded a confident "exact 0 tokens" →
   a $0.00 ledger row, the one number the charter bans. Now `unavailable`.
8. The metrics cross-check summed kyber's `priced:false` placeholder zeros
   without labeling them.

**lando-agent (4 findings, 3 fixed, 1 resolved by merge ordering):** the
vendored scripts don't exist at the current vendor pin (merge-ordering gate —
resolved by fdc's auto fan-out workflow); PR numbers were sourced from a
pipeline field the repo's own docs call usually-unwritten, which would silently
drop review/deploy-stage tokens (fixed properly in `issue-cost.sh`: linked PRs
are now auto-discovered from the issue timeline); the eval card block broke on
apostrophes and null counts (now shlex-quoted + coerced, exercised against
adversarial rows); a charter-variant format ambiguity.

**kyber#23 (10 findings, 8 CONFIRMED):** the harshest and best. The top four
showed my approved per-message output design was structurally lossy: only the
last message per 30s reporter tick was counted (busy agents lose most output),
the dedup tuple depended on a 5-minute-TTL cache (double-counts after any gap),
negative values weren't clamped on one accumulator path, and identical-usage
messages collided to a false zero. The reviewers' shared root fix — make output
CUMULATIVE (reporter-side accumulation for Claude; Codex already exposes a
cumulative counter) so it flows through the existing safeDelta path and the
tuple heuristic disappears — is simply a better design than the one I approved
in planning. Rework dispatched to the implementation agent; two cleanup
findings (Redis pipelining, token-type SSOT refactor) deliberately deferred as
follow-ups rather than scope-creeping the PR.

---

## Appendix A — the assignment (verbatim)

> **Technical Engineering Manager: Take-Home Assessment**
>
> Thanks for your interest in working with Origin. Before the technical
> interview, we ask candidates to complete a short take-home assessment. This
> document explains what we're looking for and how to submit.
>
> **Goal:** Build a functional software tool that solves a real problem, one you
> actually care about, using the same tools and approach you would use on the
> job.
>
> **Task:** Pick a problem, pick your tools, decide what "done" looks like. Use
> AI tools (Claude Code, Codex, Cursor, etc.) throughout for planning, writing
> code, debugging, whatever you find useful.
>
> **The why:** Our engineers use AI tools daily not as a novelty, but as a core
> part of how we build. This exercise is designed to reflect that reality. We
> want to see your actual workflow: how you scope a problem, how you interact
> with AI output, where you push back on it, and how you shape the result into
> something you're satisfied with.
>
> **The challenge** — a few things we're looking for:
> - The problem should be real: a tool you'd actually use, an annoyance you'd
>   actually want fixed. The best submissions come from candidates who picked
>   something they were personally motivated by.
> - The scope should be small but deliberate. This is a 4-8 hour project. A
>   well-scoped, finished tool beats an ambitious one that's half-done.
> - Use AI as much as you want. There's no restriction on which tools or how you
>   use them. We want your real workflow.
> - Don't just accept the first thing the AI gives you. We're interested in how
>   you interact with AI output and whether you iterate, push back, catch
>   mistakes, and shape the result.
>
> **What to submit** — two things:
> 1. Your project. A working codebase. A GitHub repo is easiest but a zip works
>    too. It should run, or be close enough that we can follow what's going on.
> 2. A short write-up. A few paragraphs that cover: what problem you chose and
>    why it interested you; how you used AI and what worked or didn't; where the
>    AI got things wrong and how you dealt with it; what you'd improve with more
>    time; any limitations/rough edges you're aware of.
>
> Be honest. We'd rather hear "this part is janky because I ran out of time"
> than read a polished pitch for code we can see ourselves.
>
> **What happens next:** Your submission is the basis for the technical
> interview. The hiring manager will review what you built, and the conversation
> will focus on your project, your choices, and your process. We may ask you to
> extend or modify something live, so be comfortable enough with your code to
> work in it. We're not trying to catch you off guard, we want a real
> conversation about the problem you solved.
>
> **Logistics:** Expected effort: 4-8 hours. Submission window: 3-5 days from
> receipt. If you need more time for scheduling reasons, let us know. How to
> submit: Upload your project link and write-up directly to the submission box
> below.
>
> **Note:** This exercise is intentionally open-ended. There's no spec to follow
> and no single right answer. That's by design, we care about the choices you
> make and the thinking behind them. If you have clarifying questions, we're
> happy to answer them. You're also welcome to make reasonable assumptions; just
> document them and explain how they shaped your approach.
