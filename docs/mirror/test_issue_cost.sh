#!/usr/bin/env bash
set -euo pipefail

# test_issue_cost.sh — unit tests for scripts/issue-cost.sh. Stubs the App-token
# gh wrapper (FALCON_GH_ISSUE) with a script serving canned comment/issue JSON;
# uses a fixture rate table. Asserts pricing math, the truthfulness ladder,
# provenance, planned≠actual detection, and the metrics cross-check labels.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SUT="${ROOT}/scripts/issue-cost.sh"

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

jqget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1"; }

SBX="$(mktemp -d)"

# Fixture rates: sonnet fully rated (incl. cache_creation), opus missing cache_creation.
cat > "${SBX}/rates.yaml" <<'EOF'
claude-sonnet-4-5:
    input: 3
    output: 15
    cache_read: 0.3
    cache_creation: 3.75
claude-opus-4-5:
    input: 5
    output: 25
    cache_read: 0.5
EOF
cat > "${SBX}/rates.meta" <<'EOF'
source: litellm
upstream_commit: 8447cd3ad39817bee0cdf0b3272ff8d2a36f88a8
fetched_at: 2026-07-13T07:01:47Z
EOF
export FALCON_RATES_FILE="${SBX}/rates.yaml"
export FALCON_RATES_META="${SBX}/rates.meta"

usage_marker() { # agent stage model input output cr cc quality
  printf '<!-- falcon:usage:v1 {"v":1,"agent":"%s","envelope_id":"e-%s","stage_label":"%s","issue":"matty-v/snapdex#42","window":{"from":"2026-08-07T10:00:00Z","to":"2026-08-07T11:00:00Z"},"models":{"%s":{"input":%d,"output":%d,"cache_read":%d,"cache_creation":%d,"api_calls":5}},"charter_variant":"full@abc1234","quality":"%s","reason":null} -->' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# Stub gh wrapper: serves files from ${SBX}/gh/<sanitized-path>.json
mkdir -p "${SBX}/gh"
cat > "${SBX}/gh-stub.sh" <<EOF
#!/usr/bin/env bash
# \$1=api \$2=path (ignore remaining flags)
f="${SBX}/gh/\$(echo "\$2" | tr '/' '_').json"
[ -r "\$f" ] && cat "\$f" || { echo "not found: \$f" >&2; exit 1; }
EOF
chmod +x "${SBX}/gh-stub.sh"
export FALCON_GH_ISSUE="${SBX}/gh-stub.sh"

# --- fixture: charter on body, 2 clean stage reports on issue, 1 on PR ------
CHARTER='<!-- falcon:charter:v1 {"v":1,"issue":"matty-v/snapdex#42","kickoff_at":"2026-08-07T09:00:00Z","planned":[{"agent":"yoda","role":"product-triage","model":"claude-sonnet-4-5"},{"agent":"han","role":"builder","model":"claude-sonnet-4-5"},{"agent":"chewie","role":"review","model":"claude-sonnet-4-5"}],"charter_variant":"full@abc1234"} -->'
python3 - "$SBX" "$CHARTER" \
  "$(usage_marker yoda needs-triage claude-sonnet-4-5 100000 5000 1000000 200000 exact)" \
  "$(usage_marker han ready-for-implementation claude-sonnet-4-5 1000000 50000 10000000 2000000 exact)" \
  "$(usage_marker chewie merge-requested claude-sonnet-4-5 200000 10000 2000000 400000 exact)" <<'PYEOF'
import json, os, sys
sbx, charter, yoda, han, chewie = sys.argv[1:6]
g = lambda name, obj: json.dump(obj, open(os.path.join(sbx, "gh", name), "w"))
g("repos_matty-v_snapdex_issues_42_comments.json",
  [{"body": "<!-- falcon:pickup -->\npicked up"}, {"body": yoda}, {"body": han}])
g("repos_matty-v_snapdex_issues_42.json", {"title": "species detail view", "body": "desc\n" + charter})
g("repos_matty-v_snapdex_issues_99_comments.json", [{"body": chewie}])
PYEOF

R="$("${SUT}" matty-v/snapdex#42 --pr 99 --wall-clock-s 13260 --kickbacks 0)"
# cost: input 1.3M*3 + output 65k*15 + cr 13M*0.3 + cc 2.6M*3.75 = 3.9+0.975+3.9+9.75 = 18.53
[[ "$(echo "$R" | jqget totals.cost_usd)" == "18.53" ]] && pass "priced total 18.53" || fail "cost: $(echo "$R" | jqget totals.cost_usd)"
[[ "$(echo "$R" | jqget totals.priced)" == "True" ]] && pass "priced=true" || fail "priced: $R"
[[ "$(echo "$R" | jqget totals.tokens.output)" == "65000" ]] && pass "output summed across issue+PR" || fail "output: $R"
[[ "$(echo "$R" | jqget stages.2.agent)" == "chewie" ]] && pass "PR-comment report collected" || fail "stages: $R"
[[ "$(echo "$R" | jqget charter_variant)" == "full@abc1234" ]] && pass "variant propagated" || fail "variant: $R"
[[ "$(echo "$R" | jqget planned_vs_actual_model_mismatch)" == "False" ]] && pass "no model mismatch" || fail "mismatch: $R"
echo "$R" | grep -q "litellm@8447cd3 fetched 2026-07-13" && pass "rates provenance stamped" || fail "provenance: $R"
[[ "$(echo "$R" | jqget title)" == "species detail view" ]] && pass "title from issue" || fail "title: $R"

# --- unavailable stage forces unpriced --------------------------------------
python3 - "$SBX" "$(usage_marker han s claude-sonnet-4-5 1000 100 0 0 exact)" <<'PYEOF'
import json, os, sys
sbx, han = sys.argv[1:3]
unavail = '<!-- falcon:usage:v1 {"v":1,"agent":"yoda","envelope_id":"e2","stage_label":"needs-triage","issue":"matty-v/snapdex#43","window":{"from":null,"to":"2026-08-07T11:00:00Z"},"models":{},"charter_variant":"full@abc1234","quality":"unavailable","reason":"no baseline (pod recycled before pickup comment landed)"} -->'
json.dump([{"body": han}, {"body": unavail}], open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_43_comments.json"), "w"))
json.dump({"title": "t", "body": ""}, open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_43.json"), "w"))
PYEOF
R="$("${SUT}" matty-v/snapdex#43)"
[[ "$(echo "$R" | jqget totals.priced)" == "False" ]] && pass "unavailable stage → priced=false" || fail "unavail priced: $R"
[[ "$(echo "$R" | jqget totals.cost_usd)" == "None" ]] && pass "unavailable stage → cost null" || fail "unavail cost: $R"
echo "$R" | grep -q "usage unavailable" && pass "unavailable reason in notes" || fail "notes: $R"

# --- unknown model → unpriced, never \$0; missing cc rate noted --------------
python3 - "$SBX" \
  "$(usage_marker han s claude-nebula-9 1000 100 0 0 exact)" \
  "$(usage_marker ackbar s2 claude-opus-4-5 1000 100 0 50000 exact)" <<'PYEOF'
import json, os, sys
sbx, unknown, opus = sys.argv[1:4]
json.dump([{"body": unknown}, {"body": opus}], open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_44_comments.json"), "w"))
json.dump({"title": "t", "body": ""}, open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_44.json"), "w"))
PYEOF
R="$("${SUT}" matty-v/snapdex#44)"
[[ "$(echo "$R" | jqget totals.priced)" == "False" ]] && pass "unknown model → priced=false" || fail "unknown model: $R"
echo "$R" | grep -q "claude-nebula-9 has no rate" && pass "unknown model named in notes" || fail "unknown note: $R"
echo "$R" | grep -q "excludes cache_creation for claude-opus-4-5" && pass "missing cc rate noted" || fail "cc note: $R"

# --- date-suffix rate lookup ------------------------------------------------
python3 - "$SBX" "$(usage_marker han s claude-sonnet-4-5-20250929 1000000 0 0 0 exact)" <<'PYEOF'
import json, os, sys
sbx, m = sys.argv[1:3]
json.dump([{"body": m}], open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_45_comments.json"), "w"))
json.dump({"title": "t", "body": ""}, open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_45.json"), "w"))
PYEOF
R="$("${SUT}" matty-v/snapdex#45)"
[[ "$(echo "$R" | jqget totals.cost_usd)" == "3.0" ]] && pass "date-suffix lookup priced" || fail "suffix: $R"

# --- metrics cross-check labels the platform gap ----------------------------
cat > "${SBX}/metrics.json" <<'EOF'
[{"agent":"han","model":"claude-sonnet-4-5","tokens":{"input":900000,"cache_read":9000000,"cache_creation":1800000},"costUsd":3.10,"priced":true},
 {"agent":"r2-d2","model":"claude-sonnet-4-5","tokens":{"input":5},"costUsd":99.0,"priced":true}]
EOF
python3 - "$SBX" "$(usage_marker han s claude-sonnet-4-5 1000000 50000 10000000 2000000 exact)" <<'PYEOF'
import json, os, sys
sbx, m = sys.argv[1:3]
json.dump([{"body": m}], open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_46_comments.json"), "w"))
json.dump({"title": "t", "body": ""}, open(os.path.join(sbx, "gh", "repos_matty-v_snapdex_issues_46.json"), "w"))
PYEOF
R="$("${SUT}" matty-v/snapdex#46 --metrics-json "${SBX}/metrics.json")"
[[ "$(echo "$R" | jqget metrics_check.window_cost_usd)" == "3.1" ]] && pass "cross-check sums contributors only" || fail "xcheck sum: $R"
echo "$R" | grep -q "excludes output tokens" && pass "output-gap labeled" || fail "xcheck label: $R"

echo
echo "issue-cost: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
