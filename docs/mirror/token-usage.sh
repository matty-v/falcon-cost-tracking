#!/usr/bin/env bash
set -euo pipefail

# token-usage.sh — per-stage token self-accounting for Falcon Dev workers
# (cost-tracking, fdc#TBD). Each worker measures its OWN spend for a dispatch by
# summing its Claude Code session transcripts at pickup (baseline) and at
# completion (report = now − baseline), per model, including output tokens.
#
# Subcommands:
#   baseline <envelope-id> [--marker]
#       Scan every transcript, write the baseline snapshot to
#       .runtime/usage-baseline-<envelope>.json, print it (or its issue-comment
#       marker form with --marker). Run from handle-inbound Step 2b; the marker
#       line is appended INSIDE the falcon:pickup comment so the baseline
#       survives a pod recycle (.runtime/ does not).
#   report <envelope-id> --stage <stage-label> --issue <owner/repo#N> [--marker]
#       Recompute, subtract the baseline (recovering it from the issue's pickup
#       comment via the App-token wrapper if .runtime/ was lost), and print the
#       per-model usage report (or its marker form). Run from Step 4b; the
#       marker line is appended INSIDE the falcon:complete comment.
#
# Truthfulness ladder (NEVER fabricate — team directive):
#   quality "exact"       clean delta over an intact transcript tree
#   quality "lower_bound" one or more transcript files rotated/compacted/reset
#                         mid-stage; discontinuous files are EXCLUDED, so the
#                         figure is a floor, and reason says why
#   quality "unavailable" no baseline anywhere (or nothing measurable) — callers
#                         must render "token usage unavailable (<reason>)",
#                         never 0, never a guess
#
# Transcript facts (schema per kyber pkg/tokenreport/parser.go, verified
# 2026-08-07): $HOME/.claude/projects/<slug>/<session>.jsonl, one JSON object
# per line; assistant lines carry message.model + message.usage token counts;
# usage.speed=="?" (or empty) means still streaming — skip; multi-block
# messages repeat identical usage on several lines — dedup by message.id, then
# uuid, then leafUuid. Sidechain (subagent) entries are real spend — included.
# Files are append-only and rotation starts a NEW file, so a whole-tree scan
# makes rotation a non-event for deltas.
#
# Env overrides (tests): CLAUDE_PROJECTS_DIR, FALCON_RUNTIME_DIR,
# FALCON_AGENT_NAME, FALCON_VARIANT_FILE.

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # …/vendor/falcon-dev-common
REPO_ROOT="$(cd "${SCRIPT_ROOT}/../.." && pwd)"   # the agent's identity repo

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
RUNTIME_DIR="${FALCON_RUNTIME_DIR:-${REPO_ROOT}/.runtime}"
VARIANT_FILE="${FALCON_VARIANT_FILE:-${SCRIPT_ROOT}/VARIANT}"
AGENT_NAME="${FALCON_AGENT_NAME:-$(basename "${REPO_ROOT}" | sed 's/-agent$//')}"

usage() { sed -n '3,26p' "$0"; exit 2; }

# variant — "<name>@<sha7>", e.g. "full@9c63b54". The name comes from the
# vendored VARIANT file; the sha from the identity repo's existing vendor pin
# (vendor/falcon-dev-common-version), so the tag needs no per-run bookkeeping.
variant() {
  local v="unknown" pinfile="${REPO_ROOT}/vendor/falcon-dev-common-version"
  [[ -r "${VARIANT_FILE}" ]] && v="$(tr -d '[:space:]' < "${VARIANT_FILE}")"
  if [[ "${v}" != *@* && -r "${pinfile}" ]]; then
    v="${v}@$(head -1 "${pinfile}" | cut -c1-7)"
  fi
  printf '%s\n' "${v}"
}

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# scan_tree — emit {"files":{path:{"size":N,"models":{...}}},"totals":{model:{...}}}
scan_tree() {
  python3 - "$PROJECTS_DIR" <<'PYEOF'
import glob, json, os, sys

root = sys.argv[1]
ZERO = lambda: {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0, "api_calls": 0}
files, totals, seen = {}, {}, set()

for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
    per = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") != "assistant":
                    continue
                m = e.get("message") or {}
                u = m.get("usage") or {}
                if u.get("speed") in (None, "", "?"):  # not finalized yet
                    continue
                key = m.get("id") or e.get("uuid") or e.get("leafUuid")
                if key is not None:
                    if key in seen:
                        continue
                    seen.add(key)
                b = per.setdefault(m.get("model") or "unknown", ZERO())
                b["input"] += int(u.get("input_tokens") or 0)
                b["output"] += int(u.get("output_tokens") or 0)
                b["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
                b["cache_creation"] += int(u.get("cache_creation_input_tokens") or 0)
                b["api_calls"] += 1
        files[path] = {"size": os.path.getsize(path), "models": per}
    except OSError:
        continue
    for model, b in per.items():
        t = totals.setdefault(model, ZERO())
        for k in t:
            t[k] += b[k]

print(json.dumps({"files": files, "totals": totals}, sort_keys=True))
PYEOF
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# wrap_marker <kind> <json> — one-line hidden comment; JSON containing "--"
# would terminate an HTML comment early, so fall back to a fenced block.
wrap_marker() {
  local kind="$1" json="$2"
  if [[ "${json}" == *--* ]]; then
    printf '<!-- %s -->\n```json\n%s\n```\n' "${kind}" "${json}"
  else
    printf '<!-- %s %s -->\n' "${kind}" "${json}"
  fi
}

cmd_baseline() {
  local envelope="$1"; shift
  local marker=false
  [[ "${1:-}" == "--marker" ]] && marker=true
  mkdir -p "${RUNTIME_DIR}"
  local scan taken file
  scan="$(scan_tree)"
  taken="$(now_iso)"
  file="${RUNTIME_DIR}/usage-baseline-$(sanitize "${envelope}").json"
  local json
  json="$(SCAN_JSON="${scan}" python3 - "$envelope" "$taken" <<'PYEOF'
import json, os, sys
scan = json.loads(os.environ["SCAN_JSON"])
print(json.dumps({"v": 1, "envelope_id": sys.argv[1], "taken_at": sys.argv[2],
                  "files": scan["files"], "totals": scan["totals"]}, sort_keys=True))
PYEOF
)"
  printf '%s\n' "${json}" > "${file}"
  if ${marker}; then wrap_marker "falcon:usage-baseline:v1" "${json}"; else printf '%s\n' "${json}"; fi
}

# recover_baseline <envelope> <owner/repo#N> — pull the baseline marker back out
# of the issue's pickup comment. Prints baseline JSON or nothing.
recover_baseline() {
  local envelope="$1" issue="$2"
  local repo="${issue%#*}" num="${issue##*#}"
  local comments
  comments="$("${SCRIPT_ROOT}/hooks/gh-issue.sh" api "repos/${repo}/issues/${num}/comments" --paginate 2>/dev/null || true)"
  [[ -z "${comments}" ]] && return 0
  COMMENTS_JSON="${comments}" python3 - "$envelope" <<'PYEOF'
import json, os, re, sys

envelope = sys.argv[1]
try:
    comments = json.loads(os.environ["COMMENTS_JSON"])
except ValueError:
    sys.exit(0)
pat = re.compile(r"<!-- falcon:usage-baseline:v1 (\{.*?\}) -->", re.S)
for c in comments if isinstance(comments, list) else []:
    for m in pat.finditer(c.get("body") or ""):
        try:
            b = json.loads(m.group(1))
        except ValueError:
            continue
        if b.get("envelope_id") == envelope:
            print(json.dumps(b, sort_keys=True))
            sys.exit(0)
PYEOF
}

cmd_report() {
  local envelope="$1"; shift
  local stage="" issue="" marker=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage) stage="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --marker) marker=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -z "${stage}" || -z "${issue}" ]] && usage

  local bfile="${RUNTIME_DIR}/usage-baseline-$(sanitize "${envelope}").json"
  local baseline=""
  if [[ -r "${bfile}" ]]; then
    baseline="$(cat "${bfile}")"
  else
    baseline="$(recover_baseline "${envelope}" "${issue}")"
  fi

  local scan json
  scan="$(scan_tree)"
  json="$(BASELINE_JSON="${baseline}" SCAN_JSON="${scan}" \
    python3 - "${AGENT_NAME}" "${envelope}" "${stage}" "${issue}" "$(now_iso)" "$(variant)" <<'PYEOF'
import json, os, sys

agent, envelope, stage, issue, now, variant = sys.argv[1:7]
ZERO = lambda: {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0, "api_calls": 0}
scan = json.loads(os.environ["SCAN_JSON"])
raw = os.environ.get("BASELINE_JSON") or ""

out = {"v": 1, "agent": agent, "envelope_id": envelope, "stage_label": stage,
       "issue": issue, "window": {"from": None, "to": now}, "models": {},
       "charter_variant": variant, "quality": "exact", "reason": None}

if not raw.strip():
    out["quality"], out["reason"] = "unavailable", "no baseline (pod recycled before pickup comment landed)"
    print(json.dumps(out, sort_keys=True))
    sys.exit(0)

base = json.loads(raw)
out["window"]["from"] = base.get("taken_at")
discontinuous = 0
models = {}

def add(dst, src, sign=1):
    for k in dst:
        dst[k] += sign * src.get(k, 0)

# Per-file delta: surviving intact files subtract their baseline; files that
# vanished or shrank (compaction/session reset) are EXCLUDED entirely — we
# cannot attribute their contents, so the total becomes a floor, not a guess.
for path, b in (base.get("files") or {}).items():
    cur = scan["files"].get(path)
    if cur is None or cur["size"] < b["size"]:
        discontinuous += 1
        if cur is not None:
            del scan["files"][path]
        continue
    neg = False
    delta = {}
    for model in set(list(cur["models"]) + list(b["models"])):
        d = ZERO()
        add(d, cur["models"].get(model, ZERO()))
        add(d, b["models"].get(model, ZERO()), -1)
        if any(v < 0 for v in d.values()):
            neg = True
            break
        delta[model] = d
    del scan["files"][path]
    if neg:  # same path, same-or-larger size, yet counts went down: rewritten file
        discontinuous += 1
        continue
    for model, d in delta.items():
        add(models.setdefault(model, ZERO()), d)

for path, cur in scan["files"].items():  # brand-new files count in full
    for model, b in cur["models"].items():
        add(models.setdefault(model, ZERO()), b)

out["models"] = {m: c for m, c in models.items() if any(v > 0 for v in c.values())}
if discontinuous:
    out["quality"] = "lower_bound"
    out["reason"] = "transcript discontinuity: %d file(s) rotated or compacted mid-stage" % discontinuous
if not out["models"] and discontinuous:
    out["quality"], out["reason"] = "unavailable", out["reason"] + "; nothing measurable survived"
print(json.dumps(out, sort_keys=True))
PYEOF
)"
  if ${marker}; then wrap_marker "falcon:usage:v1" "${json}"; else printf '%s\n' "${json}"; fi
}

[[ $# -lt 2 ]] && usage
cmd="$1"; shift
case "${cmd}" in
  baseline) cmd_baseline "$@" ;;
  report)   cmd_report "$@" ;;
  *) usage ;;
esac
