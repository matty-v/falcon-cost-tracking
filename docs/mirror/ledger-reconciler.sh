#!/usr/bin/env bash
# ledger-reconciler.sh — Deterministic backstop for the cost ledger
# (CONTRACTS §10.4). Lando's Step 6b is the fast path; when Lando detours
# (the 2026-08-07 snapdex#995 close-out was skipped when the smoke-test
# green-light collided with a promotion HOLD + global freeze), this pass
# writes the missing row. A cron script cannot detour — that is the point.
#
# Invoked from discord-summary-reconciler.sh's preamble BEFORE its Discord
# guard (the ledger needs no Discord), so it rides the existing 15-min cron
# with no agent-spec change. Idempotent: an issue already present in the
# ledger is skipped; issues without usage markers (pre-cost-tracking) are
# skipped. The metrics cross-check is omitted on the backstop path — the row
# notes carry the self-report data only (metrics_check: null).
#
# Env overrides (tests): FALCON_GH_ISSUE, FALCON_LEDGER_FILE, AGENT_HOME,
# FALCON_LOOKBACK_HOURS, FALCON_LEDGER_NO_GIT.

set -uo pipefail

: "${SCRIPT_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${AGENT_HOME:=${HOME}/dev/lando-agent}"
: "${FALCON_LEDGER_FILE:=${AGENT_HOME}/reports/cost-ledger.jsonl}"
: "${FALCON_LOOKBACK_HOURS:=48}"

GH="${FALCON_GH_ISSUE:-${SCRIPT_ROOT}/hooks/gh-issue.sh}"
IC="${SCRIPT_ROOT}/scripts/issue-cost.sh"

# In-scope repos — fixed allowlist, matches list-in-scope-repos.sh.
REPOS=(kyber kyber-deploy holocron snapdex)

since="$(date -u -d "-${FALCON_LOOKBACK_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -v-"${FALCON_LOOKBACK_HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"

appended=0
for repo in "${REPOS[@]}"; do
  issues="$("$GH" api "repos/matty-v/${repo}/issues?state=closed&since=${since}&per_page=50" 2>/dev/null || echo '[]')"
  nums="$(printf '%s' "$issues" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    data = []
for i in data if isinstance(data, list) else []:
    # the issues endpoint returns PRs too — a PR row carries "pull_request"
    if isinstance(i, dict) and "pull_request" not in i and i.get("number"):
        print(i["number"])' 2>/dev/null || true)"
  for num in $nums; do
    ref="matty-v/${repo}#${num}"
    # Idempotency: the ledger itself is the ledger of what has been ledgered.
    grep -qs "\"issue\": \"${ref}\"" "$FALCON_LEDGER_FILE" 2>/dev/null && continue
    comments="$("$GH" api "repos/matty-v/${repo}/issues/${num}/comments" --paginate 2>/dev/null || true)"
    printf '%s' "$comments" | grep -q "falcon:usage:v1" || continue  # pre-cost-tracking issue
    row="$(FALCON_GH_ISSUE="$GH" bash "$IC" "$ref" 2>/dev/null || true)"
    if [ -z "$row" ]; then
      echo "ledger-reconciler: WARN aggregation failed for ${ref}" >&2
      continue
    fi
    mkdir -p "$(dirname "$FALCON_LEDGER_FILE")"
    printf '%s\n' "$row" >> "$FALCON_LEDGER_FILE"
    appended=$((appended + 1))
    echo "ledger-reconciler: appended ${ref}"
  done
done

if [ "$appended" -gt 0 ] && [ -d "${AGENT_HOME}/.git" ] && [ -z "${FALCON_LEDGER_NO_GIT:-}" ]; then
  git -C "$AGENT_HOME" add "$(realpath "$FALCON_LEDGER_FILE" 2>/dev/null || echo reports/cost-ledger.jsonl)" 2>/dev/null || true
  git -C "$AGENT_HOME" commit -q -m "ledger-reconciler: backstop row(s) for ${appended} issue(s)" || true
  git -C "$AGENT_HOME" push -q || echo "ledger-reconciler: WARN push failed (rows committed locally)" >&2
fi

exit 0
