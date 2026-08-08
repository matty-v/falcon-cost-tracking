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

**The rework and the merges.** The implementation agent rebuilt output
accounting as cumulative: a new `outputTracker` in the reporter (per-file byte
offsets so nothing scrolls out of the tail window, rotation draining, bounded
FIFO dedup, init-at-EOF so a restart can never double-count — the restart gap
undercounts, which is the honest direction), Codex switched to its native
cumulative `total_token_usage`, and the tuple heuristic was deleted in favor of
the same `safeDelta` path the other three token types use (negative clamp for
free). New tests ran under `-race -count=3`; the multi-message-per-tick
undercount got a named regression test. I reviewed the tracker and delta hunks
directly before pushing.

Merged, in dependency order:
1. **kyber#23** (squash → `9b1a3d5`) after CI went green.
2. **falcon-dev-common#118** (→ `2698293`), which auto-triggered the vendor
   fan-out workflow — vendor-bump PRs opened in all 8 agent identity repos and
   auto-merged, so the whole fleet is pinned to the cost-tracking contract.
   (A momentary scare here: my first check found no vendor PR — I had simply
   raced the workflow by seconds. Logged because "verify, don't assume" cuts
   both ways.)
3. **lando-agent#106** (vendor bump) then **#105** (mini-charter + ledger).

Still ahead of the live E2E: a kyber release so the deployed control plane
actually serves output-token costs (CI never deploys; ArgoCD does), and pod
session restarts so running agents pick up the re-linked skills.

### Session 2, continued — cutting release v1.0.1

My prompt: "kick off the release and let me know when it's ready to deploy to
the kyber cluster where the falcon dev team is running." Claude read the
release runbook first rather than winging it, ran two preflights (verified
`v1.0.1` has no GHCR tag collision with the pre-open-source internal version
line — a known launch-day gotcha — by querying the registry API directly after
the PAT lacked `read:packages`; confirmed the workflow's input shape), then
dispatched `prepare-release.yml` with `version=1.0.1` and armed a four-stage
monitor: chart-bump merge → tag push → `release.yml` (8 images + GitHub
Release) → the auto-merged digest-pinned falcon bump PR on kyber-deploy. It
also corrected my mental model from the runbook: the human gate is the
*approval before the tag* — once cut, falcon promotes automatically, so "ready
to deploy" actually arrives as "deploying."

### Session 2, continued — "how do I confirm an agent runs the newest skills?"

My question surfaced a real bug before it answered anything: while verifying
what to check, Claude found the vendor fan-out workflow replaces the vendored
bundle but never updates `vendor/falcon-dev-common-version` — so every agent
repo's pin file was lying (`9c63b54` while the bundle is `2698293`), and that
stale sha is exactly what `token-usage.sh` stamps into every usage report's
`charter_variant`. The same pass found the fan-out's trigger paths were
missing `CONTRACTS.md`, `config/**`, and `VARIANT` — meaning a rates refresh
or an experiment variant flip would silently not propagate to the fleet.
Both fixed in fdc#119 + a corrective workflow_dispatch to repair the 8 stale
pins. Lesson recorded: "how do I verify X" questions are bug-finders — the
verification artifact itself was broken.

The actual answer (confirmed against kyber's boot script, kyber#323): a
session restart fetch+merges the identity repo and re-links `skills/` +
`vendor/*/skills` into `~/.claude/skills`, so — (1) ask the agent to `cat
vendor/falcon-dev-common/VARIANT` (new-in-this-release canary: old bundles
error), (2) or `kubectl exec` the same check without involving the agent,
(3) running sessions that predate the merge stay on the old contract until
restarted — so the rollout plan is a session restart per agent, Lando first.

### Session 2, continued — the E2E scratch run goes live (snapdex#995)

Matt restarted the fleet and the team picked up snapdex#995 (a night-theme
contrast bug). Claude armed a milestone monitor on the issue (charter →
pickups/baselines → usage reports → close → ledger row). Findings from the
first minutes of live operation, in order:

1. **The worker side works on the first try.** Yoda posted the pickup comment
   and the separate usage-baseline comment (the two-comment shape from the
   review fixes), then a completion `falcon:usage:v1` marker: `quality:
   "exact"`, 23 API calls, full per-type token counts INCLUDING output, a
   7-minute stage window, and the corrected `full@d45760b` variant tag.
2. **Planned≠actual model detection paid off immediately**: the roster says
   Yoda runs claude-sonnet-4-5; the transcript says `claude-opus-5` — Matt
   upgraded models with the restart. The transcript is ground truth by
   design, so the report is right and the roster is stale (to update after
   the run, from observed actuals).
3. **`claude-opus-5` is missing from the pinned rate feed** (July 13 LiteLLM
   snapshot predates it), so this issue's total will render "partial — model
   has no rate" instead of a made-up number: the fail-loud ladder's first
   real exercise. Fix dispatched through the sanctioned pipeline (kyber's
   refresh-provider-rates workflow → bot PR from the latest upstream feed →
   copy to fdc → fan-out) — never hand-typed.
4. **No mini-charter yet**: the issue predates Lando's session restart, so
   dispatch likely came from a `labeled`/recovery path, not the
   `issues.opened` kickoff where Step 1.7 lives — the exact gap we left as a
   stretch item (dispatch-time charter backstop). If it holds, the ledger row
   carries `planned: null` and the backstop gets promoted from stretch to
   to-do.

### Session 2, continued — "is 3.1M tokens accurate?" (level vs flow)

Watching the live run, I challenged the first number the system produced: Yoda
reported 3.1M tokens while Kyber's context-pressure view showed him at ~150k.
Both are right — they measure different things, and the arithmetic connects
them: context pressure is a LEVEL (~150k window right now), the usage report
is a FLOW (23 API calls × ~131k re-read context ≈ 3.0M cache reads + 28.6k
output + 57.8k cache writes + 41 uncached input = 3.10M). 97% of the total is
cache reads at a 10×-cheaper rate, so the stage costs ~$2.60 at opus-5 rates
— not the ~$15.50 a naive tokens×input-rate read would suggest. This is
precisely why the pipeline tracks four token types instead of one number, and
why kyber's last-message sampling (context semantics) can never be the spend
source. My misread is itself a UX finding: the Discord 📊 bullet's raw token
count reads scarier than the money it represents — a format tweak was agreed and shipped
same-session (fdc#121): the bullet now carries the cache-read share —
`• 📊 ~10.4M tokens (~87% cache reads) · sonnet` — fixing the misread without
moving pricing into workers' hands (Lando still owns the $).

Meanwhile the run itself validated the multi-segment design unprompted: the
second usage report is Yoda AGAIN (`approval-verdict`, 1.41M tokens, 8 calls)
after his triage segment — same agent, two envelopes, two kept reports, which
is exactly the kickback-accounting scenario I'd described as a requirement
before we confirmed the design.

### Session 2, continued — the E2E completes, and catches its best bug at the finish line

snapdex#995 ran the full pipeline: 8 stage segments, ALL quality `exact`, all
claude-opus-5 — Yoda×3 (triage 3.10M / approval-verdict 1.41M / challenge
3.22M), Obi-wan architecture 4.86M, Ackbar deploy-review 2.54M, Han build
7.57M, Chewie review 10.17M (the review cost MORE than the build — invisible
until today) and smoke-test 4.20M. ~37M tokens, 98% cache reads. PR-keyed
segments landed on PR#996 as designed. The pre-build "thinking" stages alone
were ~$12 — exactly the overhead the charter-size experiment targets.

Then the finish line: **issue closed, no ledger row.** Lando's Step 6b close-out
was skipped when the smoke-test green-light collided with Matt's prod-promotion
HOLD and the global work freeze — Lando detoured into hold-handling, and the
accounting never ran. Diagnosis was clean because the monitor asserted the
ledger row explicitly instead of assuming close == done.

Two responses, both same-session:
1. **Verified the math independently**: ran `issue-cost.sh` locally (read-only)
   against the live markers — it found all 8 segments including both PR-side
   reports via timeline auto-discovery (no --pr hints), priced the issue at
   **$28.19**, and honestly flagged that the charter variant rolled THREE times
   mid-issue (the fleet's vendor bumps were landing while the issue was in
   flight). The aggregator is correct; only the trigger failed.
2. **Closed the gap structurally** (fdc#122): a deterministic
   `ledger-reconciler.sh` riding the existing 15-min cron — invoked BEFORE the
   summary reconciler's Discord guard, because the ledger must not depend on
   Discord — idempotently writing any missing row for recently-closed issues
   with usage markers. An LLM orchestrator can detour; a cron script cannot.
   That asymmetry is the design lesson of the day, and it rhymes with the
   earlier choice to put aggregation in a tested script instead of skill prose.

Correction from Matt watching Discord directly: the thread EXISTED — the
mirror works; only the charter card was missing (and the body marker my check
grepped for). So the single confirmed gap was the kickoff-only charter path,
now closed structurally: lando-agent#111 adds dispatch Step 5c, an
open-if-missing charter backstop (mid-pipeline entries list remaining stages
only — usage reports remain the record of what already happened). Lesson
logged: I asserted 'Discord broken' from an absent marker; the human's direct
observation corrected the inference. Verify the surface, not the proxy.

### Session 2, continued — the fleet debugs its own cost tracking (E2BIG)

The best moment of the project: the ledger row still wasn't appearing after
Lando's restart, and while we were diagnosing from the outside, **Lando
diagnosed it from the inside and escalated**: "ledger-reconciler dead via
env-var E2BIG in issue-cost.sh:62, masked by exit 0." The AI dev team found
the bug in the cost-tracking system the AI assistant built to measure the AI
dev team. Root cause: I passed the paginated issue timeline to python via an
environment variable; the kernel caps a single env string at ~128KB and kills
the exec with E2BIG. And per my own reconciler design — warnings to stderr,
exit 0 — the failure was invisible to the cron report. Two lessons shipped as
fdc#123: large payloads travel via temp files everywhere (the same latent
pattern existed in token-usage.sh's recovery and scan paths), and backstop
warnings print to stdout because a warning nobody can see is not a warning.
55 tests green including a 300KB-timeline E2BIG regression case.

### Session 2, continued — the first ledger row lands (and heals)

After the E2BIG fix propagated and Matt had Lando sync + rerun, the monitor
fired: **the first row of cost-ledger.jsonl exists** — snapdex#995, all 8
stages, 37M tokens. But unpriced: `model claude-opus-5 has no rate` and
`rates_provenance: unknown@unknown` — the rates file wasn't readable in
Lando's pod, cause TBD (locally the same aggregation prices $28.19). That
exposed one more design flaw worth its own entry: the backstop was
append-once, so an unpriced row could never heal. fdc#124 makes priced rows
final while unpriced rows retry and supersede in place (git history keeps
the original), and unpriced appends now self-diagnose whether the rates file
was readable. The running theme of this whole phase: every failure mode the
truthfulness ladder was designed for actually happened within hours of going
live — and each one produced an honest artifact instead of a wrong number.

**E2E COMPLETE**: after the supersede fix propagated and Lando re-ran the
reconciler, the row healed itself — `#995 ROW NOW PRICED: $28.19`, exactly
matching my independent local aggregation. The full chain is proven live:
worker transcript self-reports → GitHub comment markers → PR auto-discovery →
priced aggregation → durable ledger, with a cron backstop that retries,
supersedes, and self-diagnoses. Phase 3's scratch-issue objective is done;
next is the ~3-issue baseline arm.

### Session 2, continued — design confirmation: self-reports are the truth

I described my mental model back as a test: an agent that goes through a
lifecycle stage twice (spec kicked back by review) should report **two**
instances of tokens used, and Lando should sum all segments with their models
at the end to price the issue. Confirmed aligned, with two sharpenings from
the implementation: (1) the accounting unit is the **dispatch envelope**, not
the stage — a kickback re-dispatch mints a new envelope, hence a second
baseline/report pair, and the aggregator deliberately keeps every instance
("re-dispatch is real kickback spend", CONTRACTS §10.4), with a `kickbacks`
count in the ledger row so rework-expensive is distinguishable from
big-expensive; (2) the sum happens at **issue close** in Lando's ack path,
and a worker whose report failed renders the total "partial" rather than a
confidently-wrong number. Also reconfirmed: transcript self-reports are the
per-issue source of truth; the platform metrics API is a labeled time-window
cross-check, which the v1.0.1 fix makes converge instead of reading
structurally low.

---

### Session 3 — 2026-08-08 — baseline arm begins; prose loses to scripts, again

The baseline arm opened with snapdex#997 (grouped admin nav — comparable PWA
work to #995). Two stage reports landed cleanly — but the mini-charter never
appeared, even though the dispatch backstop (lando#111) was in Lando's tree:
**the prose procedure was skipped on two consecutive dispatches**, while every
script invocation in the pipeline has been followed 8/8. That settles the
pattern this project keeps re-learning: instructions that ARE a command get
executed; instructions that DESCRIBE a procedure get improvised away. Fix
(lando-agent#114): `charter-ensure.sh` — idempotent, open-if-missing,
never-blocking, dry-run-verified against the live issue — and both Lando
skills now just run it. Placed in lando-agent rather than falcon-dev-common
deliberately: the worker vendor bundle stays frozen mid-experiment, so the
arm's variant tags stay clean.

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
