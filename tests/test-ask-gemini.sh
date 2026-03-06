#!/bin/bash
#
# Tests for ask-gemini.sh - one-shot consultation with mock Gemini
#
# All tests use a mock gemini binary (no real Gemini calls).
# Mock behavior is controlled via exported environment variables:
#   MOCK_GEMINI_EXIT_CODE - exit code the mock returns (default: 0)
#   MOCK_GEMINI_STDOUT    - text the mock writes to stdout
#   MOCK_GEMINI_STDERR    - text the mock writes to stderr
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

ASK_GEMINI_SCRIPT="$SCRIPT_DIR/../scripts/ask-gemini.sh"

echo "=========================================="
echo "Ask Gemini Tests (mock)"
echo "=========================================="
echo ""

# ========================================
# Setup: mock gemini binary and test project
# ========================================

setup_test_dir

# Create a mock git repo as PROJECT_ROOT
MOCK_PROJECT="$TEST_DIR/project"
init_test_git_repo "$MOCK_PROJECT"

# Create mock gemini binary directory
MOCK_BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"

cat > "$MOCK_BIN_DIR/gemini" << 'MOCK_EOF'
#!/bin/bash
# Mock gemini binary for testing ask-gemini.sh
# Controlled via environment variables.
if [[ -n "${MOCK_GEMINI_STDERR:-}" ]]; then
    echo "$MOCK_GEMINI_STDERR" >&2
fi
if [[ -n "${MOCK_GEMINI_STDOUT:-}" ]]; then
    echo "$MOCK_GEMINI_STDOUT"
fi
exit "${MOCK_GEMINI_EXIT_CODE:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN_DIR/gemini"

# Export mock variables so child processes (the mock gemini) can see them
export MOCK_GEMINI_EXIT_CODE=""
export MOCK_GEMINI_STDOUT=""
export MOCK_GEMINI_STDERR=""

# Reset mock state between tests
reset_mock() {
    export MOCK_GEMINI_EXIT_CODE="0"
    export MOCK_GEMINI_STDOUT=""
    export MOCK_GEMINI_STDERR=""
}

# Helper: run ask-gemini with mock gemini in PATH, inside mock project
run_ask_gemini() {
    (
        cd "$MOCK_PROJECT"
        export CLAUDE_PROJECT_DIR="$MOCK_PROJECT"
        export XDG_CACHE_HOME="$TEST_DIR/cache"
        PATH="$MOCK_BIN_DIR:$PATH" bash "$ASK_GEMINI_SCRIPT" "$@"
    )
}

# ========================================
# Validation Tests
# ========================================

echo "--- Validation Tests ---"
echo ""

# Test: empty question
EXIT_CODE=0
OUTPUT=$(run_ask_gemini 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "No question or task provided"; then
    pass "empty question exits 1 with error message"
else
    fail "empty question exits 1 with error message" "exit 1 + error" "exit=$EXIT_CODE"
fi

# Test: --help exits 0
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --help 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "USAGE"; then
    pass "--help exits 0 with usage info"
else
    fail "--help exits 0 with usage info" "exit 0 + USAGE" "exit=$EXIT_CODE"
fi

# Test: unknown option exits 1
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --bad-flag test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "Unknown option"; then
    pass "unknown option exits 1"
else
    fail "unknown option exits 1" "exit 1 + Unknown option" "exit=$EXIT_CODE"
fi

# Test: --gemini-model without argument
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --gemini-model 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "requires a MODEL"; then
    pass "--gemini-model without argument exits 1"
else
    fail "--gemini-model without argument exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: --gemini-timeout without argument
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --gemini-timeout 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "requires a number"; then
    pass "--gemini-timeout without argument exits 1"
else
    fail "--gemini-timeout without argument exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: --gemini-timeout non-numeric
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --gemini-timeout abc test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "must be a positive integer"; then
    pass "--gemini-timeout non-numeric exits 1"
else
    fail "--gemini-timeout non-numeric exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: invalid model characters
EXIT_CODE=0
OUTPUT=$(run_ask_gemini --gemini-model 'bad;model' test 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "invalid characters"; then
    pass "invalid model characters exits 1"
else
    fail "invalid model characters exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# ========================================
# Successful Run Tests
# ========================================

echo ""
echo "--- Successful Run Tests ---"
echo ""

# Test: successful gemini response appears on stdout
reset_mock
export MOCK_GEMINI_STDOUT="This is the answer"
STDOUT=$(run_ask_gemini "What is 1+1?" 2>/dev/null)
if echo "$STDOUT" | grep -q "This is the answer"; then
    pass "successful run outputs gemini response to stdout"
else
    fail "successful run outputs gemini response to stdout" "This is the answer" "$STDOUT"
fi

# Test: successful run creates output.md in skill dir
SKILL_DIRS_BEFORE=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
reset_mock
export MOCK_GEMINI_STDOUT="Test output for file"
run_ask_gemini "file test" > /dev/null 2>&1
SKILL_DIRS_AFTER=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
NEW_DIR=$(comm -13 <(echo "$SKILL_DIRS_BEFORE") <(echo "$SKILL_DIRS_AFTER") | head -1)
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/output.md" ]] && grep -q "Test output for file" "$NEW_DIR/output.md"; then
    pass "successful run creates output.md with gemini response"
else
    fail "successful run creates output.md with gemini response" "output.md with content" "dir=$NEW_DIR"
fi

# Test: successful run creates metadata.md with status: success
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/metadata.md" ]] && grep -q "status: success" "$NEW_DIR/metadata.md"; then
    pass "successful run creates metadata.md with status: success"
else
    fail "successful run creates metadata.md with status: success"
fi

# Test: successful run creates input.md with the question
if [[ -n "$NEW_DIR" ]] && [[ -f "$NEW_DIR/input.md" ]] && grep -q "file test" "$NEW_DIR/input.md"; then
    pass "successful run saves question to input.md"
else
    fail "successful run saves question to input.md"
fi

# Test: successful run exits 0
reset_mock
export MOCK_GEMINI_STDOUT="ok"
EXIT_CODE=0
run_ask_gemini "exit code test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "successful run exits 0"
else
    fail "successful run exits 0" "exit 0" "exit=$EXIT_CODE"
fi

# ========================================
# Error Handling Tests
# ========================================

echo ""
echo "--- Error Handling Tests ---"
echo ""

# Test: gemini non-zero exit propagates
reset_mock
export MOCK_GEMINI_EXIT_CODE="42"
export MOCK_GEMINI_STDERR="something broke"
EXIT_CODE=0
run_ask_gemini "error test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 42 ]]; then
    pass "gemini non-zero exit code propagates"
else
    fail "gemini non-zero exit code propagates" "exit 42" "exit=$EXIT_CODE"
fi

# Test: gemini error creates metadata with status: error
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: error" "$LATEST_DIR/metadata.md"; then
    pass "gemini error creates metadata with status: error"
else
    fail "gemini error creates metadata with status: error"
fi

# Test: gemini empty response exits 1
reset_mock
export MOCK_GEMINI_STDOUT=""
EXIT_CODE=0
run_ask_gemini "empty test" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "empty gemini response exits 1"
else
    fail "empty gemini response exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# Test: empty response creates metadata with status: empty_response
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: empty_response" "$LATEST_DIR/metadata.md"; then
    pass "empty response creates metadata with status: empty_response"
else
    fail "empty response creates metadata with status: empty_response"
fi

# Test: gemini timeout (exit 124) is handled
reset_mock
export MOCK_GEMINI_EXIT_CODE="124"
EXIT_CODE=0
STDERR=$(run_ask_gemini --gemini-timeout 999 "timeout test" 2>&1 >/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 124 ]] && echo "$STDERR" | grep -q "timed out"; then
    pass "timeout exit 124 is handled with error message"
else
    fail "timeout exit 124 is handled with error message" "exit 124 + timed out" "exit=$EXIT_CODE"
fi

# Test: timeout creates metadata with status: timeout
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && [[ -f "$LATEST_DIR/metadata.md" ]] && grep -q "status: timeout" "$LATEST_DIR/metadata.md"; then
    pass "timeout creates metadata with status: timeout"
else
    fail "timeout creates metadata with status: timeout"
fi

# ========================================
# Directory Uniqueness Tests
# ========================================

echo ""
echo "--- Directory Uniqueness Tests ---"
echo ""

# Test: two rapid calls produce different skill directories
DIRS_BEFORE=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

reset_mock
export MOCK_GEMINI_STDOUT="call-concurrent"
run_ask_gemini "uniqueness test 1" > /dev/null 2>&1 &
PID1=$!
run_ask_gemini "uniqueness test 2" > /dev/null 2>&1 &
PID2=$!
wait "$PID1" 2>/dev/null || true
wait "$PID2" 2>/dev/null || true

DIRS_AFTER=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
NEW_DIRS=$(comm -13 <(echo "$DIRS_BEFORE") <(echo "$DIRS_AFTER"))
NEW_DIR_COUNT=$(echo "$NEW_DIRS" | grep -c . || true)

if [[ "$NEW_DIR_COUNT" -ge 2 ]]; then
    pass "two concurrent calls create distinct skill directories"
else
    fail "two concurrent calls create distinct skill directories" ">=2 new dirs" "$NEW_DIR_COUNT new dirs"
fi

# Test: cache directories are also unique
CACHE_BASE="$TEST_DIR/cache/humanize"
if [[ -d "$CACHE_BASE" ]]; then
    CACHE_DIRS=$(find "$CACHE_BASE" -maxdepth 2 -mindepth 2 -type d -name "skill-*" 2>/dev/null | sort)
    CACHE_DIR_COUNT=$(echo "$CACHE_DIRS" | grep -c . || true)
    if [[ "$CACHE_DIR_COUNT" -ge 2 ]]; then
        pass "concurrent calls create distinct cache directories"
    else
        fail "concurrent calls create distinct cache directories" ">=2 cache dirs" "$CACHE_DIR_COUNT"
    fi
else
    fail "concurrent calls create distinct cache directories" "cache dir exists" "not found"
fi

# ========================================
# Argument Parsing Tests
# ========================================

echo ""
echo "--- Argument Parsing Tests ---"
echo ""

# Test: --gemini-model sets model
reset_mock
export MOCK_GEMINI_STDOUT="model-test"
run_ask_gemini --gemini-model "custom-model" "model test" > /dev/null 2>&1
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && grep -q "Model: custom-model" "$LATEST_DIR/input.md"; then
    pass "--gemini-model sets model in input.md"
else
    fail "--gemini-model sets model in input.md"
fi

# Test: -- separator treats remaining args as question
reset_mock
export MOCK_GEMINI_STDOUT="separator-test"
run_ask_gemini -- --not-a-flag "is question" > /dev/null 2>&1
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && grep -qF -- "--not-a-flag" "$LATEST_DIR/input.md"; then
    pass "-- separator passes remaining args as question text"
else
    fail "-- separator passes remaining args as question text"
fi

# Test: --gemini-timeout is recorded in input.md
reset_mock
export MOCK_GEMINI_STDOUT="timeout-val"
run_ask_gemini --gemini-timeout 123 "timeout value test" > /dev/null 2>&1
LATEST_DIR=$(find "$MOCK_PROJECT/.humanize/skill" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_DIR" ]] && grep -q "Timeout: 123s" "$LATEST_DIR/input.md"; then
    pass "--gemini-timeout value is recorded in input.md"
else
    fail "--gemini-timeout value is recorded in input.md"
fi

# ========================================
# Cache Directory Tests
# ========================================

echo ""
echo "--- Cache Directory Tests ---"
echo ""

# Test: cache directory contains expected files
reset_mock
export MOCK_GEMINI_STDOUT="cache-file-test"
EXIT_CODE=0
STDERR=$(run_ask_gemini "cache test" 2>&1 >/dev/null) || EXIT_CODE=$?
# Extract cache path from stderr
CACHE_PATH=$(echo "$STDERR" | grep "ask-gemini: cache=" | sed 's/ask-gemini: cache=//')
if [[ -n "$CACHE_PATH" ]] && [[ -f "$CACHE_PATH/gemini-run.cmd" ]]; then
    pass "cache directory contains gemini-run.cmd"
else
    fail "cache directory contains gemini-run.cmd" "gemini-run.cmd exists" "cache=$CACHE_PATH"
fi

if [[ -n "$CACHE_PATH" ]] && [[ -f "$CACHE_PATH/gemini-run.out" ]]; then
    pass "cache directory contains gemini-run.out"
else
    fail "cache directory contains gemini-run.out"
fi

if [[ -n "$CACHE_PATH" ]] && grep -q "cache test" "$CACHE_PATH/gemini-run.cmd"; then
    pass "gemini-run.cmd records the question"
else
    fail "gemini-run.cmd records the question"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Ask Gemini Test Summary"
