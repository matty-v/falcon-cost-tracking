#!/usr/bin/env bash
set -euo pipefail

# test_ledger_reconciler.sh — unit tests for scripts/ledger-reconciler.sh.
# Stubs the gh wrapper (FALCON_GH_ISSUE) with canned responses; asserts the
# backstop appends a row for a closed issue with usage markers, is idempotent,
# and skips pre-cost-tracking issues. No network, no git (FALCON_LEDGER_NO_GIT).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SUT="${ROOT}/scripts/ledger-reconciler.sh"

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

SBX="$(mktemp -d)"
mkdir -p "${SBX}/gh"

cat > "${SBX}/rates.yaml" <<'EOF'
claude-opus-5:
    input: 5
    output: 25
    cache_read: 0.5
    cache_creation: 6.25
EOF
printf 'source: litellm\nupstream_commit: b45b4b7300000000\nfetched_at: 2026-08-07T21:20:54Z\n' > "${SBX}/rates.meta"
export FALCON_RATES_FILE="${SBX}/rates.yaml"
export FALCON_RATES_META="${SBX}/rates.meta"
export FALCON_GH_ISSUE="${SBX}/gh-stub.sh"
export FALCON_LEDGER_FILE="${SBX}/ledger.jsonl"
export AGENT_HOME="${SBX}/not-a-git-repo"
export FALCON_LEDGER_NO_GIT=1

# input 0.1M*5 + output 40k*25 + cache_read 10M*0.5 + cache_creation 0.4M*6.25
# = 0.5 + 1.0 + 5.0 + 2.5 = $9.00 exactly.
MARKER='<!-- falcon:usage:v1 {"v":1,"agent":"han","envelope_id":"e-1","stage_label":"ready-for-implementation","issue":"matty-v/snapdex#42","window":{"from":"2026-08-07T10:00:00Z","to":"2026-08-07T11:00:00Z"},"models":{"claude-opus-5":{"input":100000,"output":40000,"cache_read":10000000,"cache_creation":400000,"api_calls":40}},"charter_variant":"full@abc1234","quality":"exact","reason":null} -->'

python3 - "$SBX" "$MARKER" <<'PYEOF'
import json, os, sys
sbx, marker = sys.argv[1], sys.argv[2]
san = lambda p: p.replace("/", "_")
g = lambda p, obj: json.dump(obj, open(os.path.join(sbx, "gh", san(p) + ".json"), "w"))
g("repos/matty-v/snapdex/issues/42/comments", [{"body": marker}])
g("repos/matty-v/snapdex/issues/42", {"title": "night-theme contrast", "body": ""})
g("repos/matty-v/snapdex/issues/41/comments", [{"body": "just a human comment"}])
PYEOF

# Stub: prefix-match the closed-issues list (its ?since= value varies per run);
# exact-match everything else from canned files; 404 otherwise (e.g. timeline —
# exercises issue-cost.sh's discovery-unavailable fallback).
cat > "${SBX}/gh-stub.sh" <<EOF
#!/usr/bin/env bash
p="\$2"
case "\$p" in
  repos/matty-v/snapdex/issues\?state=closed*)
    printf '[{"number":42},{"number":41},{"number":43,"pull_request":{}}]' ;;
  repos/matty-v/*/issues\?state=closed*)
    printf '[]' ;;
  *)
    f="${SBX}/gh/\$(echo "\$p" | tr '/' '_').json"
    [ -r "\$f" ] && cat "\$f" || { echo "stub 404: \$p" >&2; exit 1; } ;;
esac
EOF
chmod +x "${SBX}/gh-stub.sh"

# --- 1. appends a priced row for the marker-bearing closed issue ------------
OUT="$(bash "${SUT}" 2>/dev/null)"
echo "$OUT" | grep -q "appended matty-v/snapdex#42" && pass "row appended for #42" || fail "append: $OUT"
[ "$(wc -l < "${FALCON_LEDGER_FILE}" | tr -d ' ')" = "1" ] && pass "exactly one row" || fail "rows: $(cat "${FALCON_LEDGER_FILE}" 2>/dev/null)"
grep -q '"issue": "matty-v/snapdex#42"' "${FALCON_LEDGER_FILE}" && pass "row names the issue" || fail "row content"
grep -q '"cost_usd": 9.0,' "${FALCON_LEDGER_FILE}" && pass "row priced \$9.00" || fail "pricing: $(cat "${FALCON_LEDGER_FILE}")"

# --- 2. idempotent: second run appends nothing ------------------------------
bash "${SUT}" >/dev/null 2>&1
[ "$(wc -l < "${FALCON_LEDGER_FILE}" | tr -d ' ')" = "1" ] && pass "idempotent rerun" || fail "idempotency: $(wc -l < "${FALCON_LEDGER_FILE}")"

# --- 3. marker-less issue and PR both skipped -------------------------------
grep -q "matty-v/snapdex#41" "${FALCON_LEDGER_FILE}" && fail "#41 should be skipped" || pass "pre-cost-tracking issue skipped"
grep -q "matty-v/snapdex#43" "${FALCON_LEDGER_FILE}" && fail "PR #43 should be excluded" || pass "PR row excluded from issue list"

echo
echo "ledger-reconciler: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
