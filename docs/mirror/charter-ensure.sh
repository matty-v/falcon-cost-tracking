#!/usr/bin/env bash
set -uo pipefail

# charter-ensure.sh — deterministic mini-charter creation (CONTRACTS §10.3).
# Lando-only; called from dispatch Step 5c and process-github-event Step 1.7.
# Replaces the prose procedure both skills described: two live dispatches on
# snapdex#997 (2026-08-08) skipped the prose backstop entirely, while script
# invocations were followed 8/8 by workers on #995 — instructions that ARE a
# command get executed; instructions that DESCRIBE a procedure get skipped.
#
#   charter-ensure.sh <owner/repo#N> [--stage <current-stage-label>] [--dry-run]
#
# Open-if-missing and idempotent: exits 0 immediately when the issue body
# already carries a falcon:charter:v1 marker. Otherwise appends the marker
# (planned = remaining pipeline stages from --stage forward, crew/models from
# the vendored team-roster.yaml, variant from VARIANT@pin) and posts the 🧭
# Team-plan card to the issue's Discord thread. Never blocks a dispatch:
# always exits 0; failures print to stdout so the caller's transcript shows
# them.

REPO_ROOT="${HOME}/dev/lando-agent"
VENDOR="${FALCON_VENDOR_DIR:-${REPO_ROOT}/vendor/falcon-dev-common}"
GH="${FALCON_GH_ISSUE:-${VENDOR}/hooks/gh-issue.sh}"
DP="${VENDOR}/scripts/discord-post.sh"

[ $# -lt 1 ] && { echo "usage: charter-ensure.sh <owner/repo#N> [--stage <label>] [--dry-run]"; exit 0; }
ISSUE="$1"; shift
REPO="${ISSUE%#*}"; NUM="${ISSUE##*#}"
STAGE=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    *) shift ;;
  esac
done

BODY="$("$GH" api "repos/${REPO}/issues/${NUM}" --jq '.body // ""' 2>/dev/null)" || BODY=""
case "$BODY" in *"falcon:charter:v1"*) echo "charter-ensure: already present on ${ISSUE}"; exit 0 ;; esac

TITLE="$("$GH" api "repos/${REPO}/issues/${NUM}" --jq '.title // "?"' 2>/dev/null || echo "?")"

MARKER_AND_CARD="$(python3 - "$ISSUE" "$STAGE" "$VENDOR" "$REPO_ROOT" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

issue, stage, vendor, repo_root = sys.argv[1:5]

# Pipeline stage order (CONTRACTS §4); planned = current stage forward.
ORDER = ["needs-triage", "needs-architecture", "needs-challenge",
         "needs-deploy-review", "ready-for-implementation", "merge-requested",
         "needs-delivery"]
STAGE_ROLE = {"needs-triage": "yoda", "needs-architecture": "obi-wan",
              "needs-challenge": "yoda", "needs-deploy-review": "ackbar",
              "ready-for-implementation": "han/luke", "merge-requested": "chewie",
              "needs-delivery": "ackbar"}

# Roster: flat hand parse (no PyYAML in pods) of config/team-roster.yaml.
roster = {}
cur = None
try:
    for line in open(os.path.join(vendor, "config", "team-roster.yaml")):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 2 and line.rstrip().endswith(":"):
            cur = line.strip()[:-1]
            roster[cur] = {}
        elif indent >= 4 and cur and ":" in line:
            k, v = line.strip().split(":", 1)
            roster[cur][k.strip()] = v.strip()
except OSError:
    pass

def variant():
    v = "unknown"
    try:
        v = open(os.path.join(vendor, "VARIANT")).read().strip()
    except OSError:
        pass
    try:
        pin = open(os.path.join(repo_root, "vendor", "falcon-dev-common-version")).read().split()[0][:7]
        if "@" not in v:
            v = f"{v}@{pin}"
    except OSError:
        pass
    return v

start = ORDER.index(stage) if stage in ORDER else 0
planned = []
for s in ORDER[start:]:
    for agent in STAGE_ROLE[s].split("/"):
        planned.append({"agent": agent, "role": roster.get(agent, {}).get("role", s),
                        "model": roster.get(agent, {}).get("model", "unknown"),
                        "stage": s})

charter = {"v": 1, "issue": issue,
           "kickoff_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "planned": planned, "charter_variant": variant(),
           "backstop": stage != "" and start > 0}
marker = "<!-- falcon:charter:v1 " + json.dumps(charter, sort_keys=True) + " -->"

crew_bits, seen = [], set()
for p in planned:
    if p["agent"] in seen:
        continue
    seen.add(p["agent"])
    crew_bits.append(f"{p['agent'].capitalize()} ({p['stage'].replace('needs-','').replace('ready-for-','')})")
models = sorted({p["model"].replace("claude-", "").rsplit("-", 0)[0] for p in planned if p["model"] != "unknown"})
card = ("🧭 **Team plan — " + issue.split("/")[-1] + "**\n"
        + "• Crew: " + " → ".join(crew_bits) + "\n"
        + "• Models: " + (", ".join(models) if models else "per roster") + "\n"
        + "• 💸 Cost tracking on (variant: " + charter["charter_variant"].split("@")[0] + ")")
print(json.dumps({"marker": marker, "card": card}))
PYEOF
)" || { echo "charter-ensure: WARN compose failed for ${ISSUE}"; exit 0; }

MARKER="$(printf '%s' "$MARKER_AND_CARD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["marker"])')"
CARD="$(printf '%s' "$MARKER_AND_CARD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["card"])')"

if $DRY; then
  echo "DRY RUN — would append to ${ISSUE} body:"; echo "$MARKER"
  echo "DRY RUN — would post card:"; echo "$CARD"
  exit 0
fi

printf '%s\n%s' "$BODY" "$MARKER" | "$GH" issue edit "$NUM" --repo "$REPO" --body-file - >/dev/null 2>&1 \
  && echo "charter-ensure: marker appended to ${ISSUE}" \
  || echo "charter-ensure: WARN body edit failed for ${ISSUE}"

if [ -n "${USER_DISCORD_WEBHOOK_URL:-}" ] && [ -x "$DP" ]; then
  SHORTREPO="${REPO#matty-v/}"
  TID="$("$DP" ensure-thread "$SHORTREPO" "$NUM" "$TITLE" 2>/dev/null || true)"
  if [ -n "$TID" ]; then
    "$DP" post "$TID" "lando" "$CARD" >/dev/null 2>&1 \
      && echo "charter-ensure: 🧭 card posted" \
      || echo "charter-ensure: WARN card post failed (marker is in place)"
  fi
fi
exit 0
