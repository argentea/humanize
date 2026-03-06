# Code Review Phase - Round {{REVIEW_ROUND}}

This file documents the code review invocation for audit purposes.
Note: Gemini is called with a git diff prompt and outputs issues with `[P0-9]` severity markers.

## Review Configuration

- **Base Branch**: {{BASE_BRANCH}}
- **Review Round**: {{REVIEW_ROUND}}
- **Timestamp**: {{TIMESTAMP}}

## What This Phase Does

1. Runs `git diff {{BASE_BRANCH}}..HEAD` to get all changes
2. Sends the diff to Gemini for code review
3. Scans output for `[P0-9]` severity markers indicating issues
4. If issues found: Returns fix prompt to Claude for remediation
5. If no issues: Transitions to Finalize Phase

## Expected Output Format

Gemini review outputs issues in this format:
```
- [P0] Critical issue description - /path/to/file.py:line-range
  Detailed explanation of the issue.

- [P1] High priority issue - /path/to/file.py:line-range
  Detailed explanation.
```

## Files Generated

- `round-{{REVIEW_ROUND}}-review-prompt.md` - This audit file
- `round-{{REVIEW_ROUND}}-review-result.md` - Review output (in loop directory)
- `round-{{REVIEW_ROUND}}-gemini-review.cmd` - Command invocation (in cache)
- `round-{{REVIEW_ROUND}}-gemini-review.out` - Stdout capture (in cache)
- `round-{{REVIEW_ROUND}}-gemini-review.log` - Stderr capture (in cache)
