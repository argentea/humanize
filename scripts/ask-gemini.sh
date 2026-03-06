#!/bin/bash
#
# Ask Gemini - One-shot consultation with Gemini
#
# Sends a question or task to Gemini CLI and returns the response.
# This is an active, one-shot skill (unlike the passive RLCR loop).
#
# Usage:
#   ask-gemini.sh [--gemini-model MODEL] [--gemini-timeout SECONDS] [question...]
#
# Output:
#   stdout: Gemini's response (for Claude to read)
#   stderr: Status/debug info (model, log paths)
#
# Storage:
#   Project-local: .humanize/skill/<unique-id>/{input,output,metadata}.md
#   Cache: ~/.cache/humanize/<sanitized-path>/skill-<unique-id>/gemini-run.{cmd,out,log}
#

set -euo pipefail

# ========================================
# Source Shared Libraries
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source portable timeout wrapper
source "$SCRIPT_DIR/portable-timeout.sh"

# Source shared loop library for DEFAULT_GEMINI_MODEL
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

# ========================================
# Default Configuration
# ========================================

DEFAULT_ASK_GEMINI_TIMEOUT=3600

GEMINI_MODEL="$DEFAULT_GEMINI_MODEL"
GEMINI_TIMEOUT="$DEFAULT_ASK_GEMINI_TIMEOUT"

# ========================================
# Help
# ========================================

show_help() {
    cat << 'HELP_EOF'
ask-gemini - One-shot consultation with Gemini

USAGE:
  /humanize:ask-gemini [OPTIONS] <question or task>

OPTIONS:
  --gemini-model <MODEL>
                       Gemini model (default: gemini-3.1-pro-preview)
  --gemini-timeout <SECONDS>
                       Timeout for the Gemini query in seconds (default: 3600)
  -h, --help           Show this help message

DESCRIPTION:
  Sends a one-shot question or task to Gemini and returns the response.
  Unlike the RLCR loop, this is a single consultation without iteration.

  The response is saved to .humanize/skill/<unique-id>/output.md for reference.

EXAMPLES:
  /humanize:ask-gemini How should I structure the authentication module?
  /humanize:ask-gemini --gemini-model gemini-3.1-pro-preview What are the performance bottlenecks?
  /humanize:ask-gemini --gemini-timeout 300 Review the error handling in src/api/
HELP_EOF
    exit 0
}

# ========================================
# Parse Arguments
# ========================================

QUESTION_PARTS=()
OPTIONS_DONE=false

while [[ $# -gt 0 ]]; do
    if [[ "$OPTIONS_DONE" == "true" ]]; then
        # After first positional token or --, all remaining args are question text
        QUESTION_PARTS+=("$1")
        shift
        continue
    fi
    case $1 in
        -h|--help)
            show_help
            ;;
        --)
            # Explicit end-of-options marker
            OPTIONS_DONE=true
            shift
            ;;
        --gemini-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --gemini-model requires a MODEL argument" >&2
                exit 1
            fi
            GEMINI_MODEL="$2"
            shift 2
            ;;
        --gemini-timeout)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --gemini-timeout requires a number argument (seconds)" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --gemini-timeout must be a positive integer (seconds), got: $2" >&2
                exit 1
            fi
            GEMINI_TIMEOUT="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            # First positional token: stop parsing options, rest is question
            QUESTION_PARTS+=("$1")
            OPTIONS_DONE=true
            shift
            ;;
    esac
done

# Join question parts into a single string (bash 3.2 safe: empty array is unbound under set -u)
QUESTION=""
[[ ${#QUESTION_PARTS[@]} -gt 0 ]] && QUESTION="${QUESTION_PARTS[*]}"

# ========================================
# Validate Prerequisites
# ========================================

# Check gemini is available
if ! command -v gemini &>/dev/null; then
    echo "Error: 'gemini' command is not installed or not in PATH" >&2
    echo "" >&2
    echo "Please install Gemini CLI and retry: /humanize:ask-gemini <your question>" >&2
    exit 1
fi

# Check question is not empty
if [[ -z "$QUESTION" ]]; then
    echo "Error: No question or task provided" >&2
    echo "" >&2
    echo "Usage: /humanize:ask-gemini [OPTIONS] <question or task>" >&2
    echo "" >&2
    echo "For help: /humanize:ask-gemini --help" >&2
    exit 1
fi

# Validate gemini model for safety (alphanumeric, hyphen, underscore, dot)
if [[ ! "$GEMINI_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Gemini model contains invalid characters" >&2
    echo "  Model: $GEMINI_MODEL" >&2
    echo "  Only alphanumeric, hyphen, underscore, dot allowed" >&2
    exit 1
fi

# ========================================
# Detect Project Root
# ========================================

if git rev-parse --show-toplevel &>/dev/null; then
    PROJECT_ROOT=$(git rev-parse --show-toplevel)
else
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
fi

# ========================================
# Create Storage Directories
# ========================================

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
UNIQUE_ID="${TIMESTAMP}-$$-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Project-local storage: .humanize/skill/<unique-id>/
SKILL_DIR="$PROJECT_ROOT/.humanize/skill/$UNIQUE_ID"
mkdir -p "$SKILL_DIR"

# Cache storage: ~/.cache/humanize/<sanitized-path>/skill-<unique-id>/
# Falls back to project-local .humanize/cache/ if home cache is not writable
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR="$CACHE_BASE/humanize/$SANITIZED_PROJECT_PATH/skill-$UNIQUE_ID"
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    CACHE_DIR="$SKILL_DIR/cache"
    mkdir -p "$CACHE_DIR"
    echo "ask-gemini: warning: home cache not writable, using $CACHE_DIR" >&2
fi

# ========================================
# Save Input
# ========================================

cat > "$SKILL_DIR/input.md" << EOF
# Ask Gemini Input

## Question

$QUESTION

## Configuration

- Model: $GEMINI_MODEL
- Timeout: ${GEMINI_TIMEOUT}s
- Timestamp: $TIMESTAMP
EOF

# ========================================
# Save Debug Command
# ========================================

GEMINI_CMD_FILE="$CACHE_DIR/gemini-run.cmd"
GEMINI_STDOUT_FILE="$CACHE_DIR/gemini-run.out"
GEMINI_STDERR_FILE="$CACHE_DIR/gemini-run.log"

{
    echo "# Gemini ask-gemini invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $GEMINI_TIMEOUT seconds"
    echo ""
    echo "gemini --model $GEMINI_MODEL -p \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$QUESTION"
} > "$GEMINI_CMD_FILE"

# ========================================
# Run Gemini
# ========================================

echo "ask-gemini: model=$GEMINI_MODEL timeout=${GEMINI_TIMEOUT}s" >&2
echo "ask-gemini: cache=$CACHE_DIR" >&2
echo "ask-gemini: running gemini..." >&2

# Portable epoch-to-ISO8601 formatter (GNU date -d vs BSD date -r)
epoch_to_iso() {
    local epoch="$1"
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    echo "unknown"
}

START_TIME=$(date +%s)

GEMINI_EXIT_CODE=0
run_with_timeout "$GEMINI_TIMEOUT" gemini --model "$GEMINI_MODEL" -p "$QUESTION" \
    > "$GEMINI_STDOUT_FILE" 2> "$GEMINI_STDERR_FILE" || GEMINI_EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "ask-gemini: exit_code=$GEMINI_EXIT_CODE duration=${DURATION}s" >&2

# ========================================
# Handle Results
# ========================================

# Check for timeout
if [[ $GEMINI_EXIT_CODE -eq 124 ]]; then
    echo "Error: Gemini timed out after ${GEMINI_TIMEOUT} seconds" >&2
    echo "" >&2
    echo "Try increasing the timeout:" >&2
    echo "  /humanize:ask-gemini --gemini-timeout $((GEMINI_TIMEOUT * 2)) <your question>" >&2
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    # Save metadata even on timeout
    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: 124
duration: ${DURATION}s
status: timeout
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit 124
fi

# Check for non-zero exit
if [[ $GEMINI_EXIT_CODE -ne 0 ]]; then
    echo "Error: Gemini exited with code $GEMINI_EXIT_CODE" >&2
    if [[ -s "$GEMINI_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Gemini stderr (last 20 lines):" >&2
        tail -20 "$GEMINI_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    # Save metadata
    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: $GEMINI_EXIT_CODE
duration: ${DURATION}s
status: error
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit "$GEMINI_EXIT_CODE"
fi

# Check for empty stdout
if [[ ! -s "$GEMINI_STDOUT_FILE" ]]; then
    echo "Error: Gemini returned empty response" >&2
    if [[ -s "$GEMINI_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Gemini stderr (last 20 lines):" >&2
        tail -20 "$GEMINI_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: 0
duration: ${DURATION}s
status: empty_response
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit 1
fi

# ========================================
# Save Output and Metadata
# ========================================

# Save Gemini response to project-local storage
cp "$GEMINI_STDOUT_FILE" "$SKILL_DIR/output.md"

# Save metadata
cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: 0
duration: ${DURATION}s
status: success
started_at: $(epoch_to_iso "$START_TIME")
---
EOF

echo "ask-gemini: response saved to $SKILL_DIR/output.md" >&2

# ========================================
# Output Response
# ========================================

# Output Gemini's response to stdout (clean output for Claude to read)
cat "$GEMINI_STDOUT_FILE"
