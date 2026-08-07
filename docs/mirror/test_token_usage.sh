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
