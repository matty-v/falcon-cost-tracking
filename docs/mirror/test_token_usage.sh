#!/usr/bin/env bash
set -euo pipefail

# test_token_usage.sh — unit tests for scripts/token-usage.sh.
# Builds a fake ~/.claude/projects tree (CLAUDE_PROJECTS_DIR override), runs
# baseline/report, and asserts the delta math, dedup, streaming-skip, the
# marker forms, and the fail-loud quality ladder. No network; the baseline
# recovery path is exercised with a stubbed gh-issue wrapper via PATH-free env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SUT="${ROOT}/scripts/token-usage.sh"

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

jqget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1"; }

# assistant transcript line: model, in, out, cr, cc, speed, msgid
line() {
  printf '{"type":"assistant","uuid":"u-%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"speed":"%s"}}}\n' \
    "$RANDOM$RANDOM" "$7" "$1" "$2" "$3" "$4" "$5" "$6"
}

make_sandbox() {
  SBX="$(mktemp -d)"
  export CLAUDE_PROJECTS_DIR="${SBX}/projects"
  export FALCON_RUNTIME_DIR="${SBX}/runtime"
  export FALCON_AGENT_NAME="han"
  export FALCON_VARIANT_FILE="${SBX}/VARIANT"
  echo "full@test123" > "${FALCON_VARIANT_FILE}"
  mkdir -p "${CLAUDE_PROJECTS_DIR}/slug-a"
  T1="${CLAUDE_PROJECTS_DIR}/slug-a/sess1.jsonl"
}

# --- 1. baseline counts finalized entries, skips streaming, dedups ----------
make_sandbox
{
  line claude-sonnet-4-5 100 10 1000 200 standard m1
  line claude-sonnet-4-5 100 10 1000 200 standard m1     # dup message.id — once
  line claude-sonnet-4-5 50  5  500  100 '?'      m2     # streaming — skipped
  line claude-opus-4-5   10  1  100  20  standard m3     # second model
} > "${T1}"
B="$("${SUT}" baseline env-1)"
[[ "$(echo "$B" | jqget totals.claude-sonnet-4-5.input)" == "100" ]] && pass "dedup by message.id" || fail "dedup: $B"
[[ "$(echo "$B" | jqget totals.claude-sonnet-4-5.api_calls)" == "1" ]] && pass "streaming entry skipped" || fail "streaming: $B"
[[ "$(echo "$B" | jqget totals.claude-opus-4-5.output)" == "1" ]] && pass "per-model grouping" || fail "grouping: $B"
[[ -f "${FALCON_RUNTIME_DIR}/usage-baseline-env-1.json" ]] && pass "baseline persisted to .runtime" || fail "baseline file missing"

# --- 2. report = clean delta, exact quality, variant tag --------------------
{
  line claude-sonnet-4-5 300 40 3000 600 standard m4
  line claude-sonnet-4-5 200 25 2500 300 fast     m5
} >> "${T1}"
R="$("${SUT}" report env-1 --stage ready-for-implementation --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.input)" == "500" ]] && pass "delta input 500" || fail "delta input: $R"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.output)" == "65" ]] && pass "delta output 65" || fail "delta output: $R"
[[ "$(echo "$R" | jqget quality)" == "exact" ]] && pass "quality exact" || fail "quality: $R"
[[ "$(echo "$R" | jqget charter_variant)" == "full@test123" ]] && pass "variant tagged" || fail "variant: $R"
echo "$R" | grep -q '"claude-opus-4-5"' && fail "zero-delta model should be omitted" || pass "zero-delta model omitted"

# --- 3. new file after rotation counts in full, still exact -----------------
T2="${CLAUDE_PROJECTS_DIR}/slug-a/sess2.jsonl"
line claude-sonnet-4-5 70 7 700 70 standard m6 > "${T2}"
R="$("${SUT}" report env-1 --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.output)" == "72" ]] && pass "rotated-in file counted (65+7)" || fail "rotation: $R"
[[ "$(echo "$R" | jqget quality)" == "exact" ]] && pass "rotation is not a discontinuity" || fail "rotation quality: $R"

# --- 4. vanished baseline file → lower_bound floor --------------------------
make_sandbox
line claude-sonnet-4-5 100 10 1000 200 standard m1 > "${T1}"
"${SUT}" baseline env-2 >/dev/null
rm "${T1}"                                   # session reset wipes the file
line claude-sonnet-4-5 30 3 300 30 standard m7 > "${CLAUDE_PROJECTS_DIR}/slug-a/fresh.jsonl"
R="$("${SUT}" report env-2 --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget quality)" == "lower_bound" ]] && pass "wipe → lower_bound" || fail "wipe quality: $R"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.input)" == "30" ]] && pass "floor counts only new file" || fail "floor: $R"

# --- 5. shrunken file → excluded, lower_bound -------------------------------
make_sandbox
{ line claude-sonnet-4-5 100 10 1000 200 standard m1; line claude-sonnet-4-5 100 10 1000 200 standard m8; } > "${T1}"
"${SUT}" baseline env-3 >/dev/null
line claude-sonnet-4-5 100 10 1000 200 standard m1 > "${T1}"   # compacted smaller
R="$("${SUT}" report env-3 --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget quality)" == "unavailable" ]] && pass "all-discontinuous → unavailable" || fail "shrink: $R"

# --- 6. no baseline at all → unavailable, never zero ------------------------
make_sandbox
line claude-sonnet-4-5 10 1 0 0 standard m9 > "${T1}"
R="$("${SUT}" report env-nope --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget quality)" == "unavailable" ]] && pass "missing baseline → unavailable" || fail "missing baseline: $R"
echo "$R" | grep -q '"models": {}' || echo "$R" | grep -q '"models":{}' && pass "no fabricated counts" || fail "fabricated: $R"

# --- 6b. resumed session replaying history must not fabricate spend ---------
# A --resume writes a NEW file replaying old message ids. Oldest-mtime-first
# scanning keeps replayed entries attributed to the original file, so the
# report sees only genuinely-new messages (lexical order would attribute the
# replay to the new file ~half the time and count pre-baseline history).
make_sandbox
line claude-sonnet-4-5 100 10 5000000 200 standard m1 > "${CLAUDE_PROJECTS_DIR}/slug-a/z-old-session.jsonl"
touch -t 202608070900 "${CLAUDE_PROJECTS_DIR}/slug-a/z-old-session.jsonl"
"${SUT}" baseline env-resume >/dev/null
{ line claude-sonnet-4-5 100 10 5000000 200 standard m1;   # replayed history
  line claude-sonnet-4-5 7 3 0 0 standard m-new; } > "${CLAUDE_PROJECTS_DIR}/slug-a/a-resumed.jsonl"
touch -t 202608071000 "${CLAUDE_PROJECTS_DIR}/slug-a/a-resumed.jsonl"
R="$("${SUT}" report env-resume --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.input)" == "7" ]] && pass "resume replay not double-counted" || fail "resume: $R"
[[ "$(echo "$R" | jqget quality)" == "exact" ]] && pass "resume is not a discontinuity" || fail "resume quality: $R"

# --- 6c. empty projects tree → unavailable, never exact-zero ----------------
make_sandbox
"${SUT}" baseline env-empty >/dev/null
R="$("${SUT}" report env-empty --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget quality)" == "unavailable" ]] && pass "empty tree → unavailable" || fail "empty tree: $R"
echo "$R" | grep -q "projects dir empty or misconfigured" && pass "empty-tree reason named" || fail "empty reason: $R"

# --- 6d. baseline prunes zero-usage files (comment-size bound) --------------
make_sandbox
line claude-sonnet-4-5 10 1 0 0 standard m1 > "${T1}"
printf '{"type":"user","uuid":"u1"}\n' > "${CLAUDE_PROJECTS_DIR}/slug-a/no-usage.jsonl"
B="$("${SUT}" baseline env-prune)"
echo "$B" | grep -q "no-usage.jsonl" && fail "zero-usage file not pruned" || pass "zero-usage file pruned from baseline"

# --- 6e. baseline recovery: fenced form + paginated (concatenated) arrays ---
make_sandbox
mkdir -p "${SBX}/ghstub"
line claude-sonnet-4-5 100 10 1000 200 standard m1 > "${T1}"
B_JSON="$("${SUT}" baseline env-rec)"
rm -rf "${FALCON_RUNTIME_DIR}"           # simulate pod recycle
{ line claude-sonnet-4-5 100 10 1000 200 standard m1; line claude-sonnet-4-5 40 4 400 40 standard m2; } > "${T1}"
# Stub gh-issue.sh: serve TWO concatenated arrays (gh --paginate page-per-array),
# with the baseline in the SECOND page wrapped in the FENCED form.
STUB="${SBX}/ghstub/gh-issue.sh"
cat > "${STUB}" <<STUBEOF
#!/usr/bin/env bash
cat "${SBX}/ghstub/pages.txt"
STUBEOF
python3 - "${SBX}/ghstub/pages.txt" "$B_JSON" <<'PYEOF'
import json, sys
fenced = "<!-- falcon:usage-baseline:v1 -->\n```json\n" + sys.argv[2] + "\n```"
open(sys.argv[1], "w").write(json.dumps([{"body": "noise"}]) + json.dumps([{"body": fenced}]))
PYEOF
chmod +x "${STUB}"
# Point the script's gh wrapper at the stub by shadowing hooks/gh-issue.sh via PATH-free env:
R="$(FALCON_GH_ISSUE_OVERRIDE="${STUB}" "${SUT}" report env-rec --stage s --issue matty-v/snapdex#42)"
[[ "$(echo "$R" | jqget quality)" == "exact" ]] && pass "fenced+paginated baseline recovered" || fail "recovery: $R"
[[ "$(echo "$R" | jqget models.claude-sonnet-4-5.input)" == "40" ]] && pass "recovered delta correct" || fail "recovered delta: $R"

# --- 7. marker forms --------------------------------------------------------
make_sandbox
line claude-sonnet-4-5 10 1 0 0 standard m1 > "${T1}"
M="$("${SUT}" baseline env-4 --marker)"
echo "$M" | grep -q '^<!-- falcon:usage-baseline:v1 {' && pass "baseline marker one-liner" || fail "baseline marker: $M"
{ line claude-sonnet-4-5 20 2 0 0 standard m2; } >> "${T1}"
M="$("${SUT}" report env-4 --stage s --issue matty-v/snapdex#42 --marker)"
echo "$M" | grep -q '^<!-- falcon:usage:v1 {' && pass "report marker one-liner" || fail "report marker: $M"

echo
echo "token-usage: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
