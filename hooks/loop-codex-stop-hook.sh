#!/bin/bash
#
# Stop Hook for RLCR loop
#
# Intercepts Claude's exit attempts and uses Gemini to review work.
# If Gemini doesn't confirm completion, blocks exit and feeds review back.
#
# State directory: .humanize/rlcr/<timestamp>/
# State file: state.md (current_round, max_iterations, codex config)
# Summary file: round-N-summary.md (Claude's work summary)
# Review prompt: round-N-review-prompt.md (prompt sent to Codex)
# Review result: round-N-review-result.md (Codex's review)
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# DEFAULT_GEMINI_MODEL is provided by loop-common.sh (sourced below)
DEFAULT_GEMINI_TIMEOUT=5400

# ========================================
# Read Hook Input
# ========================================

HOOK_INPUT=$(cat)

# NOTE: We intentionally do NOT check stop_hook_active here.
# For iterative loops, stop_hook_active will be true when Claude is continuing
# from a previous blocked stop. We WANT to run Codex review each iteration.
# Loop termination is controlled by:
# - No active loop directory (no state.md) -> exit early below
# - Codex outputs MARKER_COMPLETE -> allow exit
# - current_round >= max_iterations -> allow exit

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Source shared loop functions and template loader
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# Source portable timeout wrapper for git operations
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Template directory is set by loop-common.sh via template-loader.sh

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$HOOK_INPUT")

LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")

# If no active loop (or session_id mismatch), allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

# ========================================
# Detect Loop Phase: Normal or Finalize
# ========================================
# Normal loop: state.md exists
# Finalize Phase: finalize-state.md exists (after Codex COMPLETE, before final completion)

STATE_FILE=$(resolve_active_state_file "$LOOP_DIR")
if [[ -z "$STATE_FILE" ]]; then
    # No state file found, allow exit
    exit 0
fi

IS_FINALIZE_PHASE=false
if [[ "$STATE_FILE" == *"/finalize-state.md" ]]; then
    IS_FINALIZE_PHASE=true
fi

# ========================================
# Parse State File (using shared function)
# ========================================

# First extract raw frontmatter to check which fields are actually present
# This prevents silently using defaults for missing critical fields
RAW_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" 2>/dev/null || echo "")

# Check if critical fields are present before parsing (which applies defaults)
RAW_CURRENT_ROUND=$(echo "$RAW_FRONTMATTER" | grep "^current_round:" || true)
RAW_MAX_ITERATIONS=$(echo "$RAW_FRONTMATTER" | grep "^max_iterations:" || true)
RAW_FULL_REVIEW_ROUND=$(echo "$RAW_FRONTMATTER" | grep "^full_review_round:" || true)

# Use tolerant parsing to extract values
# Note: parse_state_file applies defaults for missing current_round/max_iterations
if ! parse_state_file "$STATE_FILE" 2>/dev/null; then
    echo "Warning: parse_state_file returned non-zero, proceeding to schema validation" >&2
fi

# Map STATE_* variables to local names for backward compatibility
PLAN_TRACKED="$STATE_PLAN_TRACKED"
START_BRANCH="$STATE_START_BRANCH"
BASE_BRANCH="${STATE_BASE_BRANCH:-}"
BASE_COMMIT="${STATE_BASE_COMMIT:-}"
PLAN_FILE="$STATE_PLAN_FILE"
CURRENT_ROUND="$STATE_CURRENT_ROUND"
MAX_ITERATIONS="$STATE_MAX_ITERATIONS"
PUSH_EVERY_ROUND="$STATE_PUSH_EVERY_ROUND"
FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"
REVIEW_STARTED="$STATE_REVIEW_STARTED"
GEMINI_MODEL="${STATE_GEMINI_MODEL:-$DEFAULT_GEMINI_MODEL}"
GEMINI_TIMEOUT="${STATE_GEMINI_TIMEOUT:-$DEFAULT_GEMINI_TIMEOUT}"
ASK_GEMINI_QUESTION="${STATE_ASK_GEMINI_QUESTION:-false}"
AGENT_TEAMS="${STATE_AGENT_TEAMS:-false}"

# Validate Gemini model for YAML safety (in case state.md was manually edited)
if [[ ! "$GEMINI_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Invalid gemini_model in state file: $GEMINI_MODEL" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

# Validate critical fields were actually present (not just defaulted)
# This prevents silently treating a truncated state file as round 0
if [[ -z "$RAW_CURRENT_ROUND" ]]; then
    echo "Error: State file missing required field: current_round" >&2
    echo "  State file may be truncated or corrupted" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi
if [[ -z "$RAW_MAX_ITERATIONS" ]]; then
    echo "Error: State file missing required field: max_iterations" >&2
    echo "  State file may be truncated or corrupted" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

# Validate numeric fields
if [[ ! "$CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (current_round not numeric), stopping loop" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (max_iterations not numeric), using default" >&2
    MAX_ITERATIONS=42
fi

# ========================================
# Quick-check 0: Schema Validation (v1.1.2+ fields)
# ========================================
# If schema is outdated, terminate loop as unexpected

if [[ -z "$PLAN_TRACKED" || -z "$START_BRANCH" ]]; then
    REASON="RLCR loop state file is missing required fields (plan_tracked or start_branch).

This indicates the loop was started with an older version of humanize.

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.1.2+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.1: Schema Validation (v1.5.0+ fields)
# ========================================
# Validate review_started and base_branch fields for v1.5.0+ state files

if [[ -z "$REVIEW_STARTED" || ( "$REVIEW_STARTED" != "true" && "$REVIEW_STARTED" != "false" ) ]]; then
    REASON="RLCR loop state file is missing or has invalid review_started field.

This indicates the loop was started with an older version of humanize (pre-1.5.0).

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.5.0+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated (missing review_started)" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ -z "$BASE_BRANCH" ]]; then
    REASON="RLCR loop state file is missing base_branch field.

This indicates the loop was started with an older version of humanize (pre-1.5.0).

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.5.0+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated (missing base_branch)" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.2: Schema Warning (v1.5.2+ fields)
# ========================================
# Warn about missing full_review_round field (introduced in v1.5.2)
# This is a non-blocking warning - we continue with default value (5)

if [[ -z "$RAW_FULL_REVIEW_ROUND" ]]; then
    echo "Note: State file missing full_review_round field (introduced in v1.5.2)." >&2
    echo "  Using default value: 5 (Full Alignment Checks at rounds 4, 9, 14, ...)" >&2
    echo "  To use configurable Full Alignment Check intervals, upgrade to humanize v1.5.2+" >&2
    echo "  and restart the RLCR loop with --full-review-round <N> option." >&2
fi

# ========================================
# Quick-check 0.5: Branch Consistency
# ========================================

# Use || GIT_EXIT_CODE=$? to prevent set -e from aborting on non-zero exit
CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_EXIT_CODE=$?
GIT_EXIT_CODE=${GIT_EXIT_CODE:-0}
if [[ $GIT_EXIT_CODE -ne 0 || -z "$CURRENT_BRANCH" ]]; then
    REASON="Git operation failed or timed out.

Cannot verify branch consistency. This may indicate:
- Git is not responding
- Repository is in an invalid state
- Network issues (if remote operations are involved)

Please check git status manually and try again."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git operation failed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ -n "$START_BRANCH" && "$CURRENT_BRANCH" != "$START_BRANCH" ]]; then
    REASON="Git branch changed during RLCR loop.

Started on: $START_BRANCH
Current: $CURRENT_BRANCH

Branch switching is not allowed. Switch back to $START_BRANCH or cancel the loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - branch changed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.6: Plan File Integrity
# ========================================
# Skip this check in Review Phase (review_started=true)
# In review phase, the plan file is no longer needed - only code review matters.
# This is especially important for skip-impl mode where no real plan file exists.

if [[ "$REVIEW_STARTED" == "true" ]]; then
    echo "Review phase: skipping plan file integrity check (plan no longer needed)" >&2
else

BACKUP_PLAN="$LOOP_DIR/plan.md"
FULL_PLAN_PATH="$PROJECT_ROOT/$PLAN_FILE"

# Check backup exists
if [[ ! -f "$BACKUP_PLAN" ]]; then
    REASON="Plan file backup not found in loop directory.

Please copy the plan file to the loop directory:
  cp \"$FULL_PLAN_PATH\" \"$BACKUP_PLAN\"

This backup is required for plan integrity verification."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan backup missing" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check original plan file still matches backup
if [[ ! -f "$FULL_PLAN_PATH" ]]; then
    REASON="Project plan file has been deleted.

Original: $PLAN_FILE
Backup available at: $BACKUP_PLAN

You can restore from backup if needed. Plan file modifications are not allowed during RLCR loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file deleted" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check plan file integrity
# For tracked files: check both git status (uncommitted) AND content diff (committed changes)
# For gitignored files: check content diff only
if [[ "$PLAN_TRACKED" == "true" ]]; then
    # Tracked file: first check git status for uncommitted changes
    PLAN_GIT_STATUS=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null || echo "")
    if [[ -n "$PLAN_GIT_STATUS" ]]; then
        REASON="Plan file has uncommitted modifications.

File: $PLAN_FILE
Status: $PLAN_GIT_STATUS

This RLCR loop was started with --track-plan-file. Plan file modifications are not allowed during the loop."
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified (uncommitted)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# Plan changes are now allowed: plan.md is a symlink to the original, so this diff always passes
if ! diff -q "$FULL_PLAN_PATH" "$BACKUP_PLAN" &>/dev/null; then
    FALLBACK="# Plan File Modified

The plan file \`$PLAN_FILE\` has been modified since the RLCR loop started.

**Modifying plan files is forbidden during an active RLCR loop.**

If you need to change the plan:
1. Cancel the current loop: \`/humanize:cancel-rlcr-loop\`
2. Update the plan file
3. Start a new loop: \`/humanize:start-rlcr-loop $PLAN_FILE\`

Backup available at: \`$BACKUP_PLAN\`"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-modified.md" "$FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "BACKUP_PATH=$BACKUP_PLAN")
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

fi  # End of REVIEW_STARTED != true check for plan file integrity

# ========================================
# Quick Check: Are All Tasks Completed?
# ========================================
# Before running expensive Codex review, check if Claude still has
# incomplete tasks. If yes, block immediately and tell Claude to finish.
# Supports both legacy TodoWrite and new Task system (TaskCreate/TaskUpdate).

TODO_CHECKER="$SCRIPT_DIR/check-todos-from-transcript.py"

if [[ -f "$TODO_CHECKER" ]]; then
    # Pass hook input to the task checker
    TODO_RESULT=$(echo "$HOOK_INPUT" | python3 "$TODO_CHECKER" 2>&1) || TODO_EXIT=$?
    TODO_EXIT=${TODO_EXIT:-0}

    if [[ "$TODO_EXIT" -eq 2 ]]; then
        # Parse error - block and surface the error
        REASON="Task checker encountered a parse error.

Error: $TODO_RESULT

This may indicate an issue with the hook input or transcript format.
Please try again or cancel the loop if this persists."
        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - task checker parse error" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    if [[ "$TODO_EXIT" -eq 1 ]]; then
        # Incomplete tasks found - block immediately without Codex review
        # Extract the incomplete task list from the result
        INCOMPLETE_LIST=$(echo "$TODO_RESULT" | tail -n +2)

        FALLBACK="# Incomplete Tasks

Complete these tasks before exiting:

{{INCOMPLETE_LIST}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/incomplete-todos.md" "$FALLBACK" \
            "INCOMPLETE_LIST=$INCOMPLETE_LIST")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - incomplete tasks detected, please finish all tasks first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Helper: Clean Up Stale index.lock
# ========================================
# git status (and other git commands) temporarily create .git/index.lock
# while refreshing the index. If a git process is killed mid-operation
# (e.g., by a timeout wrapper), the lock file can be left behind,
# causing subsequent git add/commit to fail with:
#   fatal: Unable to create '.git/index.lock': File exists.
# This helper removes the stale lock so Claude's commit won't fail.
cleanup_stale_index_lock() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
    if [[ -f "$git_dir/index.lock" ]]; then
        echo "Removing stale $git_dir/index.lock" >&2
        rm -f "$git_dir/index.lock"
    fi
}

# ========================================
# Cache Git Status Output
# ========================================
# Cache git status output to avoid calling it multiple times.
# Used by both large file check and git clean check below.
# IMPORTANT: Fail-closed on git failures to prevent bypassing checks.

GIT_STATUS_CACHED=""
GIT_IS_REPO=false

if command -v git &>/dev/null && run_with_timeout "$GIT_TIMEOUT" git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_IS_REPO=true
    # Capture exit code to detect timeout/failure - do NOT use || echo "" which would fail-open
    GIT_STATUS_EXIT=0
    GIT_STATUS_CACHED=$(run_with_timeout "$GIT_TIMEOUT" git status --porcelain 2>/dev/null) || GIT_STATUS_EXIT=$?

    if [[ $GIT_STATUS_EXIT -ne 0 ]]; then
        # Git status failed or timed out - fail-closed by blocking exit
        # The timed-out git status may have left a stale index.lock
        cleanup_stale_index_lock
        FALLBACK="# Git Status Failed

Git status operation failed or timed out (exit code {{GIT_STATUS_EXIT}}).

Cannot verify repository state. Please check git status manually and try again."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-status-failed.md" "$FALLBACK" \
            "GIT_STATUS_EXIT=$GIT_STATUS_EXIT")
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git status failed (exit $GIT_STATUS_EXIT)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# ========================================
# Quick Check: Large File Detection
# ========================================
# Check if any tracked or new files exceed the line limit.
# Large files should be split into smaller modules.

MAX_LINES=2000

if [[ "$GIT_IS_REPO" == "true" ]]; then
    LARGE_FILES=""

    while IFS= read -r line; do
        # Skip empty lines
        if [ -z "$line" ]; then
            continue
        fi

        # Extract filename (skip first 3 chars: "XY ")
        filename="${line#???}"

        # Handle renames: "old -> new" format
        case "$filename" in
            *" -> "*) filename="${filename##* -> }" ;;
        esac

        # Skip deleted files
        if [ ! -f "$filename" ]; then
            continue
        fi

        # Get file extension and convert to lowercase
        ext="${filename##*.}"
        ext_lower=$(to_lower "$ext")

        # Determine file type based on extension
        case "$ext_lower" in
            py|js|ts|tsx|jsx|java|c|cpp|cc|cxx|h|hpp|cs|go|rs|rb|php|swift|kt|kts|scala|sh|bash|zsh)
                file_type="code"
                ;;
            md|rst|txt|adoc|asciidoc)
                file_type="documentation"
                ;;
            *)
                continue
                ;;
        esac

        # Count lines and trim whitespace (portable across shells)
        line_count=$(wc -l < "$filename" 2>/dev/null | tr -d ' ') || continue

        # Validate line_count is numeric before comparison
        [[ "$line_count" =~ ^[0-9]+$ ]] || continue

        if [ "$line_count" -gt "$MAX_LINES" ]; then
            LARGE_FILES="${LARGE_FILES}
- \`${filename}\`: ${line_count} lines (${file_type} file)"
        fi
    done <<< "$GIT_STATUS_CACHED"

    if [ -n "$LARGE_FILES" ]; then
        FALLBACK="# Large Files Detected

Files exceeding {{MAX_LINES}} lines:

{{LARGE_FILES}}

Split these into smaller modules before continuing."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/large-files.md" "$FALLBACK" \
            "MAX_LINES=$MAX_LINES" \
            "LARGE_FILES=$LARGE_FILES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - large files detected (>${MAX_LINES} lines), please split into smaller modules" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Quick Check: Git Clean and Pushed?
# ========================================
# Before running expensive Codex review, check if all changes have been
# committed and pushed. This ensures work is properly saved.

# Use cached git status from above
if [[ "$GIT_IS_REPO" == "true" ]]; then
    GIT_ISSUES=""
    SPECIAL_NOTES=""

    # Check for uncommitted changes (staged or unstaged) using cached status
    if [[ -n "$GIT_STATUS_CACHED" ]]; then
        GIT_ISSUES="uncommitted changes"

        # Check for special cases in untracked files
        UNTRACKED=$(echo "$GIT_STATUS_CACHED" | grep '^??' || true)

        # Check if .humanize* directories are untracked (includes .humanize/ and any legacy .humanize-* dirs)
        if echo "$UNTRACKED" | grep -q '\.humanize'; then
            HUMANIZE_LOCAL_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-humanize-local.md" 2>/dev/null)
            if [[ -z "$HUMANIZE_LOCAL_NOTE" ]]; then
                HUMANIZE_LOCAL_NOTE="Note: .humanize* directories are intentionally untracked."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$HUMANIZE_LOCAL_NOTE"
        fi

        # Check for other untracked files (potential artifacts)
        OTHER_UNTRACKED=$(echo "$UNTRACKED" | grep -v '\.humanize' || true)
        if [[ -n "$OTHER_UNTRACKED" ]]; then
            UNTRACKED_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-untracked.md" 2>/dev/null)
            if [[ -z "$UNTRACKED_NOTE" ]]; then
                UNTRACKED_NOTE="Review untracked files - add to .gitignore or commit them."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$UNTRACKED_NOTE"
        fi
    fi

    # Block if there are uncommitted changes
    if [[ -n "$GIT_ISSUES" ]]; then
        # Clean up stale index.lock before Claude attempts git add/commit
        cleanup_stale_index_lock
        # Git has uncommitted changes - block and remind Claude to commit
        FALLBACK="# Git Not Clean

Detected: {{GIT_ISSUES}}

Please commit all changes before exiting.
{{SPECIAL_NOTES}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-not-clean.md" "$FALLBACK" \
            "GIT_ISSUES=$GIT_ISSUES" \
            "SPECIAL_NOTES=$SPECIAL_NOTES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - $GIT_ISSUES detected, please commit first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    # ========================================
    # Check Unpushed Commits (only when push_every_round is true)
    # ========================================

    if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
        # Check if local branch is ahead of remote (unpushed commits)
        GIT_AHEAD=$(run_with_timeout "$GIT_TIMEOUT" git status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
        if [[ -n "$GIT_AHEAD" ]]; then
            AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
            CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

            FALLBACK="# Unpushed Commits

You have {{AHEAD_COUNT}} unpushed commit(s) on branch {{CURRENT_BRANCH}}.

Please push before exiting."
            REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/unpushed-commits.md" "$FALLBACK" \
                "AHEAD_COUNT=$AHEAD_COUNT" \
                "CURRENT_BRANCH=$CURRENT_BRANCH")

            jq -n \
                --arg reason "$REASON" \
                --arg msg "Loop: Blocked - $AHEAD_COUNT unpushed commit(s) detected, please push first" \
                '{
                    "decision": "block",
                    "reason": $reason,
                    "systemMessage": $msg
                }'
            exit 0
        fi
    fi
fi

# ========================================
# Check Summary File Exists
# ========================================

# In Finalize Phase, expect finalize-summary.md instead of round-N-summary.md
if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
    SUMMARY_FILE="$LOOP_DIR/finalize-summary.md"
else
    SUMMARY_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-summary.md"
fi

if [[ ! -f "$SUMMARY_FILE" ]]; then
    # Summary file doesn't exist - Claude didn't write it
    # Block exit and remind Claude to write summary

    FALLBACK="# Work Summary Missing

Please write your work summary to: {{SUMMARY_FILE}}"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/work-summary-missing.md" "$FALLBACK" \
        "SUMMARY_FILE=$SUMMARY_FILE")

    if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
        SYSTEM_MSG="Loop: Finalize Phase - summary file missing"
    else
        SYSTEM_MSG="Loop: Summary file missing for round $CURRENT_ROUND"
    fi

    jq -n \
        --arg reason "$REASON" \
        --arg msg "$SYSTEM_MSG" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# ========================================
# Check Goal Tracker Initialization (Round 0 only, skip in Finalize Phase)
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

# Skip this check in Finalize Phase, Review Phase, or when review_started is already true (skip-impl mode)
# - Finalize Phase: goal tracker was already initialized before COMPLETE
# - Review Phase (review_started=true): skip-impl mode skips implementation, no goal tracker needed
if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ "$REVIEW_STARTED" != "true" ]] && [[ "$CURRENT_ROUND" -eq 0 ]] && [[ -f "$GOAL_TRACKER_FILE" ]]; then
    # Check if goal-tracker.md still contains placeholder text
    # Extract each section and check for generic placeholder pattern within that section
    # This avoids coupling to specific placeholder wording and prevents false positives
    # from stray mentions of placeholder text elsewhere in the file

    HAS_GOAL_PLACEHOLDER=false
    HAS_AC_PLACEHOLDER=false
    HAS_TASKS_PLACEHOLDER=false

    # Extract Ultimate Goal section (### Ultimate Goal to next heading)
    # Use awk to extract lines between start and end patterns, excluding end pattern
    GOAL_SECTION=$(awk '/^### Ultimate Goal/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$GOAL_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_GOAL_PLACEHOLDER=true
    fi

    # Extract Acceptance Criteria section (### Acceptance Criteria to next heading)
    AC_SECTION=$(awk '/^### Acceptance Criteria/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$AC_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_AC_PLACEHOLDER=true
    fi

    # Extract Active Tasks section (#### Active Tasks to next heading or EOF)
    # Active Tasks is a level-4 heading, so match any ## or higher
    TASKS_SECTION=$(awk '/^#### Active Tasks/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$TASKS_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_TASKS_PLACEHOLDER=true
    fi

    # Build list of missing items
    MISSING_ITEMS=""
    if [[ "$HAS_GOAL_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Ultimate Goal**: Still contains placeholder text"
    fi
    if [[ "$HAS_AC_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Acceptance Criteria**: Still contains placeholder text"
    fi
    if [[ "$HAS_TASKS_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Active Tasks**: Still contains placeholder text"
    fi

    if [[ -n "$MISSING_ITEMS" ]]; then
        FALLBACK="# Goal Tracker Not Initialized

Please fill in the Goal Tracker ({{GOAL_TRACKER_FILE}}):
{{MISSING_ITEMS}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-not-initialized.md" "$FALLBACK" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "MISSING_ITEMS=$MISSING_ITEMS")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Goal Tracker not initialized in Round 0" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Check Max Iterations (skip in Finalize Phase - already post-COMPLETE)
# ========================================

NEXT_ROUND=$((CURRENT_ROUND + 1))

# Skip max iterations check in Finalize Phase or Review Phase
# - Finalize Phase: already received COMPLETE from codex
# - Review Phase: must continue until [P?] issues are cleared, regardless of iteration count
if [[ "$IS_FINALIZE_PHASE" != "true" ]] && [[ "$REVIEW_STARTED" != "true" ]] && [[ $NEXT_ROUND -gt $MAX_ITERATIONS ]]; then
    echo "RLCR loop did not complete, but reached max iterations ($MAX_ITERATIONS). Exiting." >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_MAXITER"
    exit 0
fi

# ========================================
# Finalize Phase Completion (skip Codex review)
# ========================================
# If we're in Finalize Phase and all checks have passed, complete the loop
# No Codex review is performed - this is the final step after Codex already confirmed COMPLETE

if [[ "$IS_FINALIZE_PHASE" == "true" ]]; then
    echo "Finalize Phase complete. All checks passed. Loop finished!" >&2
    # Rename finalize-state.md to complete-state.md
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    echo "State preserved as: $LOOP_DIR/complete-state.md" >&2
    exit 0
fi

# ========================================
# Get Docs Path from Config
# ========================================

# Note: PLUGIN_ROOT already defined at line 51
DOCS_PATH="docs"

# ========================================
# Build Codex Review Prompt
# ========================================

PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-prompt.md"
REVIEW_RESULT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-result.md"

SUMMARY_CONTENT=$(cat "$SUMMARY_FILE")

# Inline plan and goal-tracker content for Gemini (which cannot read files autonomously)
PLAN_CONTENT=""
if [[ -n "$PLAN_FILE" && -f "$PROJECT_ROOT/$PLAN_FILE" ]]; then
    PLAN_CONTENT=$(cat "$PROJECT_ROOT/$PLAN_FILE")
fi

GOAL_TRACKER_CONTENT=""
if [[ -f "$GOAL_TRACKER_FILE" ]]; then
    GOAL_TRACKER_CONTENT=$(cat "$GOAL_TRACKER_FILE")
fi

# Shared prompt section for Goal Tracker Update Requests (used in both Full Alignment and Regular reviews)
GOAL_TRACKER_SECTION_FALLBACK="## Goal Tracker Updates
If Claude's summary includes a Goal Tracker Update Request section, apply the requested changes to {{GOAL_TRACKER_FILE}}."
GOAL_TRACKER_UPDATE_SECTION=$(load_and_render_safe "$TEMPLATE_DIR" "codex/goal-tracker-update-section.md" "$GOAL_TRACKER_SECTION_FALLBACK" \
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE")

# Determine if this is a Full Alignment Check round (every FULL_REVIEW_ROUND rounds)
# Full Alignment Checks occur at rounds (N-1), (2N-1), (3N-1), etc. where N=FULL_REVIEW_ROUND
# Validate FULL_REVIEW_ROUND is a positive integer (default to 5 if invalid/corrupted)
if ! [[ "$FULL_REVIEW_ROUND" =~ ^[0-9]+$ ]] || [[ "$FULL_REVIEW_ROUND" -lt 2 ]]; then
    echo "Warning: Invalid full_review_round value '$FULL_REVIEW_ROUND', defaulting to 5" >&2
    FULL_REVIEW_ROUND=5
fi
FULL_ALIGNMENT_CHECK=false
if [[ $((CURRENT_ROUND % FULL_REVIEW_ROUND)) -eq $((FULL_REVIEW_ROUND - 1)) ]]; then
    FULL_ALIGNMENT_CHECK=true
fi

# Calculate derived values for templates
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
COMPLETED_ITERATIONS=$((CURRENT_ROUND + 1))
# Clamp previous round indices to 0 minimum to avoid negative file references
# This can happen with --full-review-round 2 where first alignment check is at round 1
PREV_ROUND=$(( CURRENT_ROUND > 0 ? CURRENT_ROUND - 1 : 0 ))
PREV_PREV_ROUND=$(( CURRENT_ROUND > 1 ? CURRENT_ROUND - 2 : 0 ))

# Build the review prompt
FULL_ALIGNMENT_FALLBACK="# Full Alignment Review (Round {{CURRENT_ROUND}})

Review Claude's work against the plan and goal tracker. Check all goals are being met.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

REGULAR_REVIEW_FALLBACK="# Code Review (Round {{CURRENT_ROUND}})

Review Claude's work for this round.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    # Full Alignment Check prompt
    load_and_render_safe "$TEMPLATE_DIR" "codex/full-alignment-review.md" "$FULL_ALIGNMENT_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "PLAN_CONTENT=$PLAN_CONTENT" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "GOAL_TRACKER_CONTENT=$GOAL_TRACKER_CONTENT" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"

else
    # Regular review prompt with goal alignment section
    load_and_render_safe "$TEMPLATE_DIR" "codex/regular-review.md" "$REGULAR_REVIEW_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "PLAN_CONTENT=$PLAN_CONTENT" \
        "PROMPT_FILE=$PROMPT_FILE" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "GOAL_TRACKER_CONTENT=$GOAL_TRACKER_CONTENT" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"
fi

# ========================================
# Shared Setup: Cache Directory and Gemini Arguments
# ========================================
# Initialize these before the REVIEW_STARTED guard so they are available in both
# impl phase (gemini summary review) and review phase (gemini code review)

# First, check if gemini command exists
if ! command -v gemini &>/dev/null; then
    REASON="# Gemini Not Found

The 'gemini' command is not installed or not in PATH.
RLCR loop requires Gemini CLI to perform reviews.

**To fix:**
1. Install Gemini CLI: https://github.com/google-gemini/gemini-cli
2. Retry the exit

Or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
fi

# Debug log files go to XDG_CACHE_HOME/humanize/<project-path>/<timestamp>/ to avoid polluting project dir
# Respects XDG_CACHE_HOME for testability in restricted environments (falls back to $HOME/.cache)
# This prevents Claude and Codex from reading these debug files during their work
# The project path is sanitized to replace problematic characters with '-'
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
# Sanitize project root path: replace / and other problematic chars with -
# This matches Claude Code's convention (e.g., /home/sihao/github.com/foo -> -home-sihao-github-com-foo)
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR="$CACHE_BASE/humanize/$SANITIZED_PROJECT_PATH/$LOOP_TIMESTAMP"
mkdir -p "$CACHE_DIR"

# Note: portable-timeout.sh already sourced at line 52

# Gemini model is already set above (GEMINI_MODEL)

# ========================================
# Helper Functions for Code Review Phase
# ========================================

# Run gemini code review with git diff and changed file contents
# Arguments: $1=round_number
# Sets: GEMINI_REVIEW_EXIT_CODE, GEMINI_REVIEW_LOG_FILE
# Returns: exit code from gemini
run_gemini_code_review() {
    local round="$1"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine review base: prefer BASE_COMMIT over BASE_BRANCH to avoid empty diffs
    # when working on the base branch itself (branch ref advances with each commit)
    local review_base="${BASE_COMMIT:-$BASE_BRANCH}"
    local review_base_type="branch"
    if [[ -n "$BASE_COMMIT" ]]; then
        review_base_type="commit"
    fi

    GEMINI_REVIEW_CMD_FILE="$CACHE_DIR/round-${round}-gemini-review.cmd"
    GEMINI_REVIEW_LOG_FILE="$CACHE_DIR/round-${round}-gemini-review.log"
    local prompt_file="$LOOP_DIR/round-${round}-review-prompt.md"

    # Gather git diff
    local git_diff=""
    git_diff=$(git -C "$PROJECT_ROOT" diff "${review_base}..HEAD" 2>/dev/null) || git_diff="(git diff failed)"

    # Gather changed file contents (skip binaries and files >500 lines)
    local changed_files=""
    changed_files=$(git -C "$PROJECT_ROOT" diff --name-only "${review_base}..HEAD" 2>/dev/null) || changed_files=""

    local changed_files_content=""
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue
        local full_path="$PROJECT_ROOT/$filepath"
        [[ ! -f "$full_path" ]] && continue
        local line_count
        line_count=$(wc -l < "$full_path" 2>/dev/null | tr -d ' ') || continue
        [[ ! "$line_count" =~ ^[0-9]+$ ]] && continue
        [[ "$line_count" -gt 500 ]] && continue
        # Skip likely binary files by extension
        local ext="${filepath##*.}"
        local ext_lower
        ext_lower=$(to_lower "$ext")
        case "$ext_lower" in
            png|jpg|jpeg|gif|bmp|ico|pdf|zip|tar|gz|bz2|xz|7z|exe|dll|so|dylib|bin|wasm)
                continue ;;
        esac
        changed_files_content="${changed_files_content}### ${filepath}
\`\`\`
$(cat "$full_path")
\`\`\`

"
    done <<< "$changed_files"

    # Build the review prompt directly (not via template system to avoid escaping issues with diff content)
    {
        echo "# Code Review - Round ${round}"
        echo ""
        echo "You are an expert code reviewer. Review the following git diff and changed file contents for issues."
        echo "Report every issue using severity markers in this exact format:"
        echo ""
        echo "\`\`\`"
        echo "- [P0] Critical issue - /path/to/file.py:line-range"
        echo "  Explanation."
        echo ""
        echo "- [P1] High priority issue - /path/to/file.py:line-range"
        echo "  Explanation."
        echo "\`\`\`"
        echo ""
        echo "Severity: [P0]=critical [P1]=high [P2]=medium [P3]=low [P4-P9]=informational"
        echo ""
        echo "## Review Configuration"
        echo "- Base: ${review_base} (${review_base_type})"
        echo "- Round: ${round}"
        echo "- Timestamp: ${timestamp}"
        echo ""
        echo "## Git Diff"
        echo ""
        echo "\`\`\`diff"
        echo "$git_diff"
        echo "\`\`\`"
        echo ""
        echo "## Changed File Contents"
        echo ""
        echo "$changed_files_content"
        echo ""
        echo "## Instructions"
        echo "1. Review the diff and changed files carefully."
        echo "2. Report every issue with a [P0-9] severity marker."
        echo "3. Be specific: include file path and line range for each issue."
        echo "4. If you find no issues, output only: No issues found."
        echo "5. Do NOT output explanatory preamble - start directly with issues or 'No issues found.'"
    } > "$prompt_file"

    echo "Gemini review prompt saved to: $prompt_file" >&2

    {
        echo "# Gemini review invocation debug info"
        echo "# Timestamp: $timestamp"
        echo "# Working directory: $PROJECT_ROOT"
        echo "# Base branch: $BASE_BRANCH"
        echo "# Base commit: ${BASE_COMMIT:-N/A}"
        echo "# Review base ($review_base_type): $review_base"
        echo "# Model: $GEMINI_MODEL"
        echo "# Timeout: $GEMINI_TIMEOUT seconds"
        echo ""
        echo "gemini --model $GEMINI_MODEL -p \"<prompt>\""
    } > "$GEMINI_REVIEW_CMD_FILE"

    echo "Gemini review command saved to: $GEMINI_REVIEW_CMD_FILE" >&2
    echo "Running gemini review with timeout ${GEMINI_TIMEOUT}s (base: $review_base)..." >&2

    local gemini_prompt
    gemini_prompt=$(cat "$prompt_file")

    GEMINI_REVIEW_EXIT_CODE=0
    (cd "$PROJECT_ROOT" && run_with_timeout "$GEMINI_TIMEOUT" gemini --model "$GEMINI_MODEL" -p "$gemini_prompt") \
        > "$GEMINI_REVIEW_LOG_FILE" 2>&1 || GEMINI_REVIEW_EXIT_CODE=$?

    echo "Gemini review exit code: $GEMINI_REVIEW_EXIT_CODE" >&2
    echo "Gemini review log saved to: $GEMINI_REVIEW_LOG_FILE" >&2

    return "$GEMINI_REVIEW_EXIT_CODE"
}

# Note: detect_review_issues() is defined in loop-common.sh and sourced above

# Run code review and handle the result
# Arguments: $1=round_number, $2=success_system_message
# On success (no issues), calls enter_finalize_phase and exits
# On issues found, calls continue_review_loop_with_issues and exits
# On failure, calls block_review_failure and exits
run_and_handle_code_review() {
    local round="$1"
    local success_msg="$2"

    echo "Running gemini review against base: ${BASE_COMMIT:-$BASE_BRANCH}..." >&2

    # Run gemini review; IMPORTANT: failure is blocking - do NOT skip to finalize
    if ! run_gemini_code_review "$round"; then
        block_review_failure "$round" "Gemini review command failed" "$GEMINI_REVIEW_EXIT_CODE"
    fi

    # detect_review_issues returns: 0=issues found, 1=no issues, 2=log missing (hard error)
    local merged_content=""
    local detect_exit=0
    merged_content=$(detect_review_issues "$round") || detect_exit=$?

    if [[ "$detect_exit" -eq 2 ]]; then
        block_review_failure "$round" "Gemini review produced no output" "N/A"
    elif [[ "$detect_exit" -eq 0 ]] && [[ -n "$merged_content" ]]; then
        # Issues found - continue review loop
        continue_review_loop_with_issues "$round" "$merged_content"
    else
        # No issues found (exit code 1) - proceed to finalize
        echo "Code review passed with no issues. Proceeding to finalize phase." >&2
        enter_finalize_phase "" "$success_msg"
    fi
}

# Enter finalize phase with appropriate prompt
# Arguments: $1=skip_reason (empty if not skipped), $2=system_message
enter_finalize_phase() {
    local skip_reason="$1"
    local system_msg="$2"

    mv "$STATE_FILE" "$LOOP_DIR/finalize-state.md"
    echo "State file renamed to: $LOOP_DIR/finalize-state.md" >&2

    local finalize_summary_file="$LOOP_DIR/finalize-summary.md"
    local finalize_prompt

    if [[ -n "$skip_reason" ]]; then
        local fallback="# Finalize Phase (Review Skipped)

**Warning**: Code review was skipped due to: {{REVIEW_SKIP_REASON}}

The implementation could not be fully validated. You are now in the **Finalize Phase**.

## Important Notice
Since the code review was skipped, please manually verify your changes before finalizing:
1. Review your code changes for any obvious issues
2. Run any available tests to verify correctness
3. Check for common code quality issues

## Simplification (Optional)
If time permits, use the \`code-simplifier:code-simplifier\` agent via the Task tool to simplify and refactor your code. Focus more on changes between branch from {{BASE_BRANCH}} to {{START_BRANCH}}.

## Constraints
- Must NOT change existing functionality
- Must NOT fail existing tests
- Must NOT introduce new bugs
- Only perform functionality-equivalent code refactoring and simplification

## Before Exiting
1. Complete all todos
2. Commit your changes
3. Write your finalize summary to: {{FINALIZE_SUMMARY_FILE}}"

        finalize_prompt=$(load_and_render_safe "$TEMPLATE_DIR" "claude/finalize-phase-skipped-prompt.md" "$fallback" \
            "FINALIZE_SUMMARY_FILE=$finalize_summary_file" \
            "PLAN_FILE=$PLAN_FILE" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "REVIEW_SKIP_REASON=$skip_reason" \
            "BASE_BRANCH=$BASE_BRANCH" \
            "START_BRANCH=$START_BRANCH")
    else
        local fallback="# Finalize Phase

Codex review has passed. The implementation is complete.

You are now in the **Finalize Phase**. Use the \`code-simplifier:code-simplifier\` agent via the Task tool to simplify and refactor your code.

## Constraints
- Must NOT change existing functionality
- Must NOT fail existing tests
- Must NOT introduce new bugs
- Only perform functionality-equivalent code refactoring and simplification

## Focus
Focus on the code changes made during this RLCR session. Focus more on changes between branch from {{BASE_BRANCH}} to {{START_BRANCH}}.

## Before Exiting
1. Complete all todos
2. Commit your changes
3. Write your finalize summary to: {{FINALIZE_SUMMARY_FILE}}"

        finalize_prompt=$(load_and_render_safe "$TEMPLATE_DIR" "claude/finalize-phase-prompt.md" "$fallback" \
            "FINALIZE_SUMMARY_FILE=$finalize_summary_file" \
            "PLAN_FILE=$PLAN_FILE" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "BASE_BRANCH=$BASE_BRANCH" \
            "START_BRANCH=$START_BRANCH")
    fi

    jq -n \
        --arg reason "$finalize_prompt" \
        --arg msg "$system_msg" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Continue review loop when issues are found
# Arguments: $1=round_number, $2=review_content
continue_review_loop_with_issues() {
    local round="$1"
    local review_content="$2"

    echo "Code review found issues. Continuing review loop..." >&2

    # Update round number in state file
    local temp_file="${STATE_FILE}.tmp.$$"
    sed "s/^current_round: .*/current_round: $round/" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"

    # Build review-fix prompt for Claude
    local next_prompt_file="$LOOP_DIR/round-${round}-prompt.md"
    local next_summary_file="$LOOP_DIR/round-${round}-summary.md"

    local fallback="# Code Review Findings

You are in the **Review Phase** of the RLCR loop. Codex has performed a code review and found issues.

## Review Results

{{REVIEW_CONTENT}}

## Instructions

1. Address all issues marked with [P0-9] severity markers
2. Focus on fixes only - do not add new features
3. Commit your changes after fixing the issues
4. Write your summary to: {{SUMMARY_FILE}}"

    load_and_render_safe "$TEMPLATE_DIR" "claude/review-phase-prompt.md" "$fallback" \
        "REVIEW_CONTENT=$review_content" \
        "SUMMARY_FILE=$next_summary_file" > "$next_prompt_file"

    jq -n \
        --arg reason "$(cat "$next_prompt_file")" \
        --arg msg "Loop: Review Phase Round $round - Fix code review issues" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# Block exit when gemini review fails or produces no output
# This is a hard error - the review phase cannot be skipped
# Arguments: $1=round_number, $2=failure_reason, $3=exit_code (optional)
block_review_failure() {
    local round="$1"
    local failure_reason="$2"
    local exit_code="${3:-unknown}"

    echo "ERROR: Gemini review failed. Blocking exit and requiring retry." >&2

    local stderr_content=""
    local stderr_file="$CACHE_DIR/round-${round}-gemini-review.log"
    if [[ -f "$stderr_file" ]]; then
        stderr_content=$(tail -50 "$stderr_file" 2>/dev/null || echo "(unable to read stderr)")
    fi

    local fallback="# Gemini Review Failed

The code review could not be completed. This is a blocking error that requires retry.

## Error Details

**Reason**: {{FAILURE_REASON}}
**Round**: {{ROUND_NUMBER}}
**Base Branch**: {{BASE_BRANCH}}
**Exit Code**: {{EXIT_CODE}}

## What Happened

The Gemini review command failed to produce valid output. This can occur due to:
- Network connectivity issues
- Gemini service timeout or unavailability
- Invalid review configuration
- Internal Gemini errors

## Required Action

**You must retry the exit.** The review phase cannot be skipped - the loop must continue until code review passes with no \`[P0-9]\` issues found.

Steps to retry:
1. Ensure your changes are committed
2. Write your summary to the expected file
3. Attempt to exit again

If this error persists, consider canceling and restarting the loop: \`/humanize:cancel-rlcr-loop\`

## Debug Information

Stderr (last 50 lines):
\`\`\`
{{STDERR_CONTENT}}
\`\`\`"

    local reason
    reason=$(load_and_render_safe "$TEMPLATE_DIR" "block/codex-review-failed.md" "$fallback" \
        "FAILURE_REASON=$failure_reason" \
        "ROUND_NUMBER=$round" \
        "BASE_BRANCH=$BASE_BRANCH" \
        "EXIT_CODE=$exit_code" \
        "STDERR_CONTENT=$stderr_content" \
        "REVIEW_RESULT_FILE=$LOOP_DIR/round-${round}-review-result.md" \
        "REVIEW_LOG_FILE=$CACHE_DIR/round-${round}-gemini-review.log")

    jq -n \
        --arg reason "$reason" \
        --arg msg "Loop: Blocked - Gemini review failed, retry required" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
}

# ========================================
# Run Gemini Review (Implementation Phase Only)
# ========================================
# Skip when in review phase - review phase uses gemini code review instead

if [[ "$REVIEW_STARTED" == "true" ]]; then
    echo "In review phase - skipping gemini summary review, will run gemini code review instead..." >&2
    # Jump directly to Review Phase section below (after the COMPLETE/STOP handling)
else

echo "Running Gemini review for round $CURRENT_ROUND..." >&2

GEMINI_CMD_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-gemini-run.cmd"
GEMINI_STDOUT_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-gemini-run.out"
GEMINI_STDERR_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-gemini-run.log"

# Save the command and prompt for debugging
GEMINI_PROMPT_CONTENT=$(cat "$REVIEW_PROMPT_FILE")
{
    echo "# Gemini invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Model: $GEMINI_MODEL"
    echo "# Timeout: $GEMINI_TIMEOUT seconds"
    echo ""
    echo "gemini --model $GEMINI_MODEL -p \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$GEMINI_PROMPT_CONTENT"
} > "$GEMINI_CMD_FILE"

echo "Gemini command saved to: $GEMINI_CMD_FILE" >&2
echo "Running gemini with timeout ${GEMINI_TIMEOUT}s..." >&2

GEMINI_EXIT_CODE=0
run_with_timeout "$GEMINI_TIMEOUT" gemini --model "$GEMINI_MODEL" -p "$GEMINI_PROMPT_CONTENT" \
    > "$GEMINI_STDOUT_FILE" 2> "$GEMINI_STDERR_FILE" || GEMINI_EXIT_CODE=$?

echo "Gemini exit code: $GEMINI_EXIT_CODE" >&2
echo "Gemini stdout saved to: $GEMINI_STDOUT_FILE" >&2
echo "Gemini stderr saved to: $GEMINI_STDERR_FILE" >&2

# ========================================
# Check Gemini Execution Result
# ========================================

# Helper function to print Gemini failure and block exit for retry
gemini_failure_exit() {
    local error_type="$1"
    local details="$2"

    REASON="# Gemini Review Failed

**Error Type:** $error_type

$details

**Debug files:**
- Command: $GEMINI_CMD_FILE
- Stdout: $GEMINI_STDOUT_FILE
- Stderr: $GEMINI_STDERR_FILE

Please retry or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
}

# Check 1: Gemini exit code indicates failure
if [[ "$GEMINI_EXIT_CODE" -ne 0 ]]; then
    STDERR_CONTENT=""
    if [[ -f "$GEMINI_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -30 "$GEMINI_STDERR_FILE" 2>/dev/null || echo "(unable to read stderr)")
    fi

    gemini_failure_exit "Non-zero exit code ($GEMINI_EXIT_CODE)" \
"Gemini exited with code $GEMINI_EXIT_CODE.
This may indicate:
  - Invalid arguments or configuration
  - Authentication failure
  - Network issues
  - Prompt format issues

Stderr output (last 30 lines):
$STDERR_CONTENT"
fi

# Gemini writes to stdout; copy to review result file
if [[ -s "$GEMINI_STDOUT_FILE" ]]; then
    if ! cp "$GEMINI_STDOUT_FILE" "$REVIEW_RESULT_FILE" 2>/dev/null; then
        gemini_failure_exit "Failed to save review output" \
"Could not copy Gemini output to: $REVIEW_RESULT_FILE
Source: $GEMINI_STDOUT_FILE

This may indicate permission issues or disk space problems."
    fi
fi

# Check 2: Review result file still doesn't exist or is empty
if [[ ! -f "$REVIEW_RESULT_FILE" ]] || [[ ! -s "$REVIEW_RESULT_FILE" ]]; then
    STDOUT_PREVIEW=""
    if [[ -f "$GEMINI_STDOUT_FILE" ]]; then
        STDOUT_PREVIEW=$(tail -10 "$GEMINI_STDOUT_FILE" 2>/dev/null || echo "(no output)")
    fi
    gemini_failure_exit "Review result file missing or empty" \
"Expected: $REVIEW_RESULT_FILE
Gemini completed (exit code 0) but produced no output.

Stdout preview:
$STDOUT_PREVIEW"
fi

# Read the review result
REVIEW_CONTENT=$(cat "$REVIEW_RESULT_FILE")

# Check if the last non-empty line is exactly "COMPLETE" or "STOP"
# The word must be on its own line to avoid false positives like "CANNOT COMPLETE"
# Use strict matching: only whitespace before/after the word is allowed
LAST_LINE=$(echo "$REVIEW_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Handle COMPLETE - enter Review Phase or Finalize Phase
if [[ "$LAST_LINE_TRIMMED" == "$MARKER_COMPLETE" ]]; then
    # In review phase, COMPLETE signal is ignored - only absence of [P0-9] triggers finalize
    if [[ "$REVIEW_STARTED" == "true" ]]; then
        echo "COMPLETE signal ignored in review phase. Gemini code review determines exit." >&2
        # Fall through to continue with gemini code review logic below
    else
        # Implementation phase complete - transition to review phase
        # Max iterations check
        if [[ $CURRENT_ROUND -ge $MAX_ITERATIONS ]]; then
            echo "Gemini review passed but at max iterations ($MAX_ITERATIONS). Terminating as MAXITER." >&2
            end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_MAXITER"
            exit 0
        fi

        # Initialize skip tracking variables before any skip paths
        REVIEW_SKIPPED=""
        REVIEW_SKIP_REASON=""

        # Check if base_branch is available for code review
        if [[ -z "$BASE_BRANCH" ]]; then
            echo "Warning: No base_branch configured, skipping code review phase." >&2
            REVIEW_SKIPPED="true"
            REVIEW_SKIP_REASON="No base_branch configured for code review"
        else
            echo "Implementation complete. Entering Review Phase..." >&2

            # Update state to indicate review phase has started
            TEMP_FILE="${STATE_FILE}.tmp.$$"
            sed "s/^review_started: .*/review_started: true/" "$STATE_FILE" > "$TEMP_FILE"
            mv "$TEMP_FILE" "$STATE_FILE"
            REVIEW_STARTED="true"

            # Create marker file to validate review phase was properly entered
            # Also record which round build finished for monitor display
            echo "build_finish_round=$CURRENT_ROUND" > "$LOOP_DIR/.review-phase-started"

            # Run code review and handle results (may exit on issues/failure/success)
            # Pass CURRENT_ROUND + 1 so all review phase files use the next round number
            echo "Implementation complete. Running initial code review..." >&2
            run_and_handle_code_review "$((CURRENT_ROUND + 1))" "Loop: Finalize Phase - Simplify and refactor code before completion"
        fi
    fi
fi

fi  # End of implementation phase gemini review block (skipped when review_started is true)

# ========================================
# Review Phase: Run Code Review (when review_started is true)
# ========================================
# When in review phase, run gemini code review on every exit attempt
# The loop continues until no [P0-9] patterns are found in the review output

if [[ "$REVIEW_STARTED" == "true" && -n "$BASE_BRANCH" ]]; then
    # Validate that review phase was properly entered (marker file must exist)
    # This prevents manual toggle attacks where someone edits state.md directly
    if [[ ! -f "$LOOP_DIR/.review-phase-started" ]]; then
        REASON="Review phase state inconsistency detected.

The state file indicates review_started=true, but no review phase marker exists.
This can happen if the state file was manually edited.

**To fix:**
Reset the state by canceling and restarting the loop.

Use \`/humanize:cancel-rlcr-loop\` to end this loop."
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - invalid review phase state" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi

    echo "Review Phase: Running gemini code review..." >&2

    # Run code review and handle results (may exit on issues/failure/success)
    # Pass CURRENT_ROUND + 1 so all review phase files use the next round number
    run_and_handle_code_review "$((CURRENT_ROUND + 1))" "Loop: Finalize Phase - Code review passed"
fi

# Handle STOP - circuit breaker triggered
if [[ "$LAST_LINE_TRIMMED" == "$MARKER_STOP" ]]; then
    echo "" >&2
    echo "========================================" >&2
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "CIRCUIT BREAKER TRIGGERED" >&2
        echo "========================================" >&2
        echo "Gemini detected development stagnation during Full Alignment Check (Round $CURRENT_ROUND)." >&2
        echo "The loop has been stopped to prevent further unproductive iterations." >&2
        echo "" >&2
        echo "Review the historical round files in .humanize/rlcr/$(basename "$LOOP_DIR")/ to understand what went wrong." >&2
        echo "Consider:" >&2
        echo "  - Revisiting the original plan for clarity" >&2
        echo "  - Breaking down the task into smaller pieces" >&2
        echo "  - Manually addressing the blocking issues" >&2
    else
        echo "UNEXPECTED CIRCUIT BREAKER" >&2
        echo "========================================" >&2
        echo "Gemini output STOP during a non-alignment round (Round $CURRENT_ROUND)." >&2
        echo "This is unusual - STOP is normally only expected during Full Alignment Checks (every $FULL_REVIEW_ROUND rounds)." >&2
        echo "Honoring the STOP request and terminating the loop." >&2
        echo "" >&2
        echo "Review the review result to understand why Codex requested an early stop:" >&2
        echo "  $REVIEW_RESULT_FILE" >&2
    fi
    echo "========================================" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_STOP"
    exit 0
fi

# ========================================
# Review Found Issues - Continue Loop
# ========================================

# Update state file for next round
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^current_round: .*/current_round: $NEXT_ROUND/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Create next round prompt
NEXT_PROMPT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-prompt.md"
NEXT_SUMMARY_FILE="$LOOP_DIR/round-${NEXT_ROUND}-summary.md"

# Build the next round prompt from templates
NEXT_ROUND_FALLBACK="# Next Round Instructions

Review the feedback below and address all issues.

## Gemini Review
{{REVIEW_CONTENT}}

Reference: {{PLAN_FILE}}, {{GOAL_TRACKER_FILE}}"
load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-prompt.md" "$NEXT_ROUND_FALLBACK" \
    "PLAN_FILE=$PLAN_FILE" \
    "REVIEW_CONTENT=$REVIEW_CONTENT" \
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" > "$NEXT_PROMPT_FILE"

# Check for Open Questions in review content and inject notice if enabled
# Detection: line containing "Open Question" substring with total length < 40 chars
if [[ "$ASK_GEMINI_QUESTION" == "true" ]]; then
    HAS_OPEN_QUESTION=false
    while IFS= read -r line; do
        if [[ ${#line} -lt 40 ]] && echo "$line" | grep -q "Open Question"; then
            HAS_OPEN_QUESTION=true
            break
        fi
    done < "$REVIEW_RESULT_FILE"

    if [[ "$HAS_OPEN_QUESTION" == "true" ]]; then
        echo "Detected Open Question(s) in Gemini review - injecting AskUserQuestion notice" >&2
        OPEN_QUESTION_NOTICE=$(load_template "$TEMPLATE_DIR" "claude/open-question-notice.md" 2>/dev/null)
        if [[ -z "$OPEN_QUESTION_NOTICE" ]]; then
            OPEN_QUESTION_NOTICE="**IMPORTANT**: Gemini has found Open Question(s). You must use \`AskUserQuestion\` to clarify those questions with user first, before proceeding to resolve any other Gemini findings."
        fi
        # Insert notice between "<!-- CODEX's REVIEW RESULT  END  -->" line + "---" line and "## Goal Tracker Reference"
        TEMP_PROMPT_FILE="${NEXT_PROMPT_FILE}.tmp.$$"
        awk -v notice="$OPEN_QUESTION_NOTICE" '
            /<!-- CODEX.*REVIEW RESULT.*END.*-->/ {
                print
                getline
                if (/^---/) {
                    print
                    print ""
                    print notice
                    next
                }
            }
            { print }
        ' "$NEXT_PROMPT_FILE" > "$TEMP_PROMPT_FILE"
        mv "$TEMP_PROMPT_FILE" "$NEXT_PROMPT_FILE"
    fi
fi

# Add special instructions for post-Full Alignment Check rounds
if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    POST_ALIGNMENT=$(load_template "$TEMPLATE_DIR" "claude/post-alignment-action-items.md" 2>/dev/null)
    if [[ -n "$POST_ALIGNMENT" ]]; then
        echo "$POST_ALIGNMENT" >> "$NEXT_PROMPT_FILE"
    fi
fi

# Add footer with commit/summary instructions
FOOTER_FALLBACK="## Before Exiting
Commit your changes and write summary to {{NEXT_SUMMARY_FILE}}"
load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-footer.md" "$FOOTER_FALLBACK" \
    "NEXT_SUMMARY_FILE=$NEXT_SUMMARY_FILE" >> "$NEXT_PROMPT_FILE"

# Add push instruction only if push_every_round is true
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
    PUSH_NOTE=$(load_template "$TEMPLATE_DIR" "claude/push-every-round-note.md" 2>/dev/null)
    if [[ -z "$PUSH_NOTE" ]]; then
        PUSH_NOTE="Also push your changes after committing."
    fi
    echo "$PUSH_NOTE" >> "$NEXT_PROMPT_FILE"
fi

# Add goal tracker update request template
GOAL_UPDATE_REQUEST=$(load_template "$TEMPLATE_DIR" "claude/goal-tracker-update-request.md" 2>/dev/null)
if [[ -z "$GOAL_UPDATE_REQUEST" ]]; then
    GOAL_UPDATE_REQUEST="Include a Goal Tracker Update Request section in your summary if needed."
fi
echo "$GOAL_UPDATE_REQUEST" >> "$NEXT_PROMPT_FILE"

# Add agent-teams continuation instructions (only during implementation phase, not review phase)
# Loads both continuation header and shared core template for full team leader guidance
if [[ "$AGENT_TEAMS" == "true" ]] && [[ "$REVIEW_STARTED" != "true" ]]; then
    AGENT_TEAMS_CONTINUE=$(load_template "$TEMPLATE_DIR" "claude/agent-teams-continue.md" 2>/dev/null)
    AGENT_TEAMS_CORE=$(load_template "$TEMPLATE_DIR" "claude/agent-teams-core.md" 2>/dev/null)
    if [[ -n "$AGENT_TEAMS_CONTINUE" ]] && [[ -n "$AGENT_TEAMS_CORE" ]]; then
        echo "" >> "$NEXT_PROMPT_FILE"
        echo "$AGENT_TEAMS_CONTINUE" >> "$NEXT_PROMPT_FILE"
        echo "" >> "$NEXT_PROMPT_FILE"
        echo "$AGENT_TEAMS_CORE" >> "$NEXT_PROMPT_FILE"
    else
        # Fallback if templates are missing
        cat >> "$NEXT_PROMPT_FILE" << 'AGENT_TEAMS_FALLBACK_EOF'

## Agent Teams Continuation

Continue using **Agent Teams mode** as the **Team Leader**.
Split remaining work among team members and coordinate their efforts.
Do NOT do implementation work yourself - delegate all coding to team members.
AGENT_TEAMS_FALLBACK_EOF
    fi
fi

# Build system message
SYSTEM_MSG="Loop: Round $NEXT_ROUND/$MAX_ITERATIONS - Codex found issues to address"

# Block exit and send review feedback
jq -n \
    --arg reason "$(cat "$NEXT_PROMPT_FILE")" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $reason,
        "systemMessage": $msg
    }'

exit 0
