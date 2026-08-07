#!/usr/bin/env bash
set -euo pipefail

# issue-cost.sh — aggregate an issue's per-stage token self-reports into the
# final-cost ledger row (cost tracking, CONTRACTS §10.4). Lando-only; called
# from process-worker-ack.md Step 6b at issue close.
#
#   issue-cost.sh <owner/repo#N> [--pr <num>]... [--metrics-json <file>]
#                 [--title <text>] [--wall-clock-s <secs>] [--kickbacks <n>]
#                 [--report-path <path>]
#
# Reads:
#   - the issue's comments + body (and each --pr's comments) via the App-token
#     wrapper — collecting every  <!-- falcon:usage:v1 … -->  marker and the
#     <!-- falcon:charter:v1 … -->  mini-charter
#   - config/provider-rates.yaml (+ .meta provenance) — the vendored verbatim
#     copy of Kyber's GENERATED rate table (never hand-typed; Matt 2026-06-07)
#   - optionally a metrics-API response file (Lando fetches it — this script
#     has no cluster creds) for the independent cross-check
#
# Prints ONE JSON ledger row to stdout — append it verbatim to
# lando-agent/reports/cost-ledger.jsonl. Truthfulness rules (NORMATIVE):
# any stage with quality "unavailable" forces totals.priced=false and
# cost_usd=null; models absent from the rate table render unpriced (never
# $0.00); every exclusion is named in totals.cost_notes.
#
# Env overrides (tests): FALCON_RATES_FILE, FALCON_RATES_META, FALCON_GH_ISSUE.

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RATES_FILE="${FALCON_RATES_FILE:-${SCRIPT_ROOT}/config/provider-rates.yaml}"
RATES_META="${FALCON_RATES_META:-${SCRIPT_ROOT}/config/provider-rates.meta}"
GH="${FALCON_GH_ISSUE:-${SCRIPT_ROOT}/hooks/gh-issue.sh}"

usage() { sed -n '3,12p' "$0"; exit 2; }

[[ $# -lt 1 ]] && usage
ISSUE="$1"; shift
REPO="${ISSUE%#*}"; NUM="${ISSUE##*#}"

PRS=(); METRICS_FILE=""; TITLE=""; WALL=""; KICKBACKS=""; REPORT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PRS+=("$2"); shift 2 ;;
    --metrics-json) METRICS_FILE="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --wall-clock-s) WALL="$2"; shift 2 ;;
    --kickbacks) KICKBACKS="$2"; shift 2 ;;
    --report-path) REPORT_PATH="$2"; shift 2 ;;
    *) usage ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Auto-discover linked PRs from the issue timeline (cross-referenced PRs in the
# same repo) and union them with any --pr args: the pipeline record's pr_ref is
# usually unwritten (CONTRACTS §9.5), and review/deploy stages post their usage
# markers on the PR — missing those would silently undercount the issue.
TIMELINE="$("$GH" api "repos/${REPO}/issues/${NUM}/timeline" --paginate 2>/dev/null || true)"
if [[ -n "${TIMELINE}" ]]; then
  DISCOVERED="$(TIMELINE_JSON="${TIMELINE}" REPO_ARG="${REPO}" python3 - <<'PYEOF'
import json, os

def decode_pages(text):
    dec, idx, out = json.JSONDecoder(), 0, []
    text = text.strip()
    while idx < len(text):
        try:
            doc, end = dec.raw_decode(text, idx)
        except ValueError:
            break
        out.extend(doc if isinstance(doc, list) else [doc])
        idx = end
        while idx < len(text) and text[idx] in " \t\r\n":
            idx += 1
    return out

repo = os.environ["REPO_ARG"]
nums = set()
for ev in decode_pages(os.environ["TIMELINE_JSON"]):
    if not isinstance(ev, dict) or ev.get("event") != "cross-referenced":
        continue
    src = (ev.get("source") or {}).get("issue") or {}
    if "pull_request" not in src:
        continue
    if ((src.get("repository") or {}).get("full_name") or repo) != repo:
        continue
    if src.get("number"):
        nums.add(str(src["number"]))
print(" ".join(sorted(nums)))
PYEOF
)"
  for pr in ${DISCOVERED}; do
    [[ " ${PRS[*]:-} " == *" ${pr} "* ]] || PRS+=("${pr}")
  done
fi

# Comments from the issue and every linked PR (the issues comments endpoint
# serves both), plus the issue body (mini-charter marker lives there).
"$GH" api "repos/${REPO}/issues/${NUM}/comments" --paginate > "${WORK}/comments-issue.json" 2>/dev/null || echo '[]' > "${WORK}/comments-issue.json"
"$GH" api "repos/${REPO}/issues/${NUM}" > "${WORK}/issue.json" 2>/dev/null || echo '{}' > "${WORK}/issue.json"
for pr in "${PRS[@]:-}"; do
  [[ -z "${pr}" ]] && continue
  [[ "${pr}" == "${NUM}" ]] && continue
  "$GH" api "repos/${REPO}/issues/${pr}/comments" --paginate > "${WORK}/comments-pr-${pr}.json" 2>/dev/null || echo '[]' > "${WORK}/comments-pr-${pr}.json"
done
[[ -n "${METRICS_FILE}" && -r "${METRICS_FILE}" ]] && cp "${METRICS_FILE}" "${WORK}/metrics.json"

ISSUE_ARG="${ISSUE}" TITLE_ARG="${TITLE}" WALL_ARG="${WALL}" KICK_ARG="${KICKBACKS}" \
REPORT_ARG="${REPORT_PATH}" RATES_FILE_ARG="${RATES_FILE}" RATES_META_ARG="${RATES_META}" \
python3 - "${WORK}" <<'PYEOF'
import glob, json, os, re, sys
from datetime import datetime, timezone

work = sys.argv[1]
issue = os.environ["ISSUE_ARG"]

# ---- rate table (flat generated YAML: "model:" at col 0, "    key: num") ----
def load_rates(path):
    rates, model = {}, None
    try:
        with open(path) as f:
            for line in f:
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if not line.startswith((" ", "\t")) and line.rstrip().endswith(":"):
                    model = line.strip()[:-1]
                    rates[model] = {}
                elif model and ":" in line:
                    k, v = line.strip().split(":", 1)
                    try:
                        rates[model][k.strip()] = float(v)
                    except ValueError:
                        pass
    except OSError:
        pass
    return rates

def load_meta(path):
    meta = {}
    try:
        with open(path) as f:
            for line in f:
                if ":" in line and not line.lstrip().startswith("#"):
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip()
    except OSError:
        pass
    return meta

rates = load_rates(os.environ["RATES_FILE_ARG"])
meta = load_meta(os.environ["RATES_META_ARG"])
DATE_SUFFIX = re.compile(r"-\d{8}$")

def lookup(model):
    if model in rates:
        return rates[model]
    stripped = DATE_SUFFIX.sub("", model)
    if stripped in rates:
        return rates[stripped]
    for k, v in rates.items():          # table key carries the date suffix
        if DATE_SUFFIX.sub("", k) == model:
            return v
    return None

# ---- collect markers -------------------------------------------------------
USAGE = re.compile(r"<!-- falcon:usage:v1 (\{.*?\}) -->", re.S)
USAGE_FENCED = re.compile(r"<!-- falcon:usage:v1 -->\s*```json\s*(\{.*?\})\s*```", re.S)
CHARTER = re.compile(r"<!-- falcon:charter:v1 (\{.*?\}) -->", re.S)

# `gh api --paginate` emits one JSON array PER PAGE, concatenated — decode
# document-by-document (a single json.load fails past 100 comments and would
# silently drop every marker on a busy issue).
def decode_pages(text):
    dec, idx, out = json.JSONDecoder(), 0, []
    text = text.strip()
    while idx < len(text):
        try:
            doc, end = dec.raw_decode(text, idx)
        except ValueError:
            break
        out.extend(doc if isinstance(doc, list) else [doc])
        idx = end
        while idx < len(text) and text[idx] in " \t\r\n":
            idx += 1
    return out

reports, charter = [], None
bodies = []
for path in sorted(glob.glob(os.path.join(work, "comments-*.json"))):
    with open(path) as f:
        data = decode_pages(f.read())
    bodies += [c.get("body") or "" for c in data if isinstance(c, dict)]
try:
    issue_obj = json.load(open(os.path.join(work, "issue.json")))
except ValueError:
    issue_obj = {}
issue_body = issue_obj.get("body") or ""

for body in bodies:
    for pat in (USAGE, USAGE_FENCED):
        for m in pat.finditer(body):
            try:
                r = json.loads(m.group(1))
            except ValueError:
                continue
            if r.get("v") == 1:
                reports.append(r)
m = CHARTER.search(issue_body)
if m:
    try:
        charter = json.loads(m.group(1))
    except ValueError:
        charter = None

# ---- price -----------------------------------------------------------------
TYPES = ("input", "output", "cache_read", "cache_creation")
totals = {t: 0 for t in TYPES}
cost = 0.0
priced = True
notes = []
stages = []
variants = set()
unpriced_models, no_cc_rate = set(), set()

for r in reports:
    q = r.get("quality") or "unavailable"
    stage = {"stage": r.get("stage_label"), "agent": r.get("agent"),
             "envelope_id": r.get("envelope_id"), "quality": q,
             "reason": r.get("reason"), "models": r.get("models") or {},
             "from": (r.get("window") or {}).get("from"),
             "to": (r.get("window") or {}).get("to")}
    stages.append(stage)
    if r.get("charter_variant"):
        variants.add(r["charter_variant"])
    if q == "unavailable":
        priced = False
        notes.append("%s/%s: usage unavailable (%s)" % (r.get("agent"), r.get("stage_label"), r.get("reason")))
        continue
    if q == "lower_bound":
        notes.append("%s/%s: lower bound (%s)" % (r.get("agent"), r.get("stage_label"), r.get("reason")))
    for model, c in (r.get("models") or {}).items():
        for t in TYPES:
            totals[t] += int(c.get(t) or 0)
        rt = lookup(model)
        if rt is None:
            priced = False
            unpriced_models.add(model)
            continue
        cost += (c.get("input") or 0) * rt.get("input", 0.0) / 1e6
        cost += (c.get("output") or 0) * rt.get("output", 0.0) / 1e6
        cost += (c.get("cache_read") or 0) * rt.get("cache_read", 0.0) / 1e6
        if "cache_creation" in rt:
            cost += (c.get("cache_creation") or 0) * rt["cache_creation"] / 1e6
        elif c.get("cache_creation"):
            no_cc_rate.add(model)

for m_ in sorted(unpriced_models):
    notes.append("model %s has no rate — unpriced (never $0.00)" % m_)
for m_ in sorted(no_cc_rate):
    notes.append("excludes cache_creation for %s (no cache-write rate in table)" % m_)

# planned vs actual model check
mismatch = False
if charter and stages:
    planned = {p.get("agent"): p.get("model") for p in charter.get("planned") or []}
    for s in stages:
        want = planned.get(s.get("agent"))
        if want and s["models"] and want not in s["models"] and DATE_SUFFIX.sub("", want) not in {DATE_SUFFIX.sub("", k) for k in s["models"]}:
            mismatch = True

# ---- metrics cross-check ---------------------------------------------------
metrics_check = None
mpath = os.path.join(work, "metrics.json")
if os.path.exists(mpath):
    try:
        rows = json.load(open(mpath))
    except ValueError:
        rows = None
    if isinstance(rows, list):
        agents = {s.get("agent") for s in stages}
        crows = [r for r in rows if r.get("agent") in agents]
        win_cost = sum(r.get("costUsd") or 0.0 for r in crows)
        mnotes = ["window attribution — includes any concurrent work by the same agents"]
        has_output = any("output" in (r.get("tokens") or {}) for r in rows)
        if not has_output:
            mnotes.append("platform metric excludes output tokens (kyber gap — fix pending)")
        # kyber emits costUsd:0 as an explicit placeholder on priced:false rows;
        # summing those zeros silently would understate the window — label it.
        unpriced_rows = sorted({r.get("model") or "?" for r in crows if r.get("priced") is False})
        if unpriced_rows:
            mnotes.append("window total excludes unpriced rows: %s" % ", ".join(unpriced_rows))
        metrics_check = {"window_cost_usd": round(win_cost, 2), "notes": mnotes}

row = {
    "v": 1,
    "closed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "issue": issue,
    "title": os.environ["TITLE_ARG"] or (issue_obj.get("title") or None),
    "charter_variant": sorted(variants)[0] if len(variants) == 1 else (sorted(variants) or None),
    "planned": (charter or {}).get("planned"),
    "planned_vs_actual_model_mismatch": mismatch,
    "wall_clock_s": int(os.environ["WALL_ARG"]) if os.environ["WALL_ARG"] else None,
    "kickbacks": int(os.environ["KICK_ARG"]) if os.environ["KICK_ARG"] else None,
    "stages": stages,
    "totals": {
        "tokens": totals,
        "cost_usd": round(cost, 2) if (priced and stages) else None,
        "priced": bool(priced and stages),
        "cost_notes": notes,
        "rates_provenance": "%s@%s fetched %s" % (
            meta.get("source", "unknown"),
            (meta.get("upstream_commit") or "unknown")[:7],
            meta.get("fetched_at", "unknown")),
    },
    "metrics_check": metrics_check,
    "report_path": os.environ["REPORT_ARG"] or None,
}
if not stages:
    row["totals"]["cost_notes"].append("no falcon:usage:v1 reports found — cost unavailable")
elif row["totals"]["priced"] and not any(totals.values()):
    # Stages reported but measured nothing at all: a confident $0.00 is the one
    # number the charter bans — render it unpriced instead.
    row["totals"]["priced"] = False
    row["totals"]["cost_usd"] = None
    row["totals"]["cost_notes"].append("all stages measured zero tokens — implausible for LLM work, cost unavailable")
if len(variants) > 1:
    row["totals"]["cost_notes"].append("MIXED charter variants mid-issue: %s" % ", ".join(sorted(variants)))
print(json.dumps(row, sort_keys=True))
PYEOF
