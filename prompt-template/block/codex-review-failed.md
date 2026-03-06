# Gemini Review Failed

The Gemini review process failed to produce output.

**Failure Reason**: {{FAILURE_REASON}}
**Round**: {{ROUND_NUMBER}}
**Base Branch**: {{BASE_BRANCH}}
**Exit Code**: {{EXIT_CODE}}

**Review Log**: {{REVIEW_LOG_FILE}}

**Stderr (last 50 lines)**:
```
{{STDERR_CONTENT}}
```

**You must retry the exit.** The review phase cannot be skipped - the loop must continue until code review passes with no `[P0-9]` issues found.

Steps to retry:
1. Ensure your changes are committed
2. Write your summary to the expected file
3. Attempt to exit again

If this error persists, consider canceling and restarting the loop: `/humanize:cancel-rlcr-loop`
