# Code Review - Round {{REVIEW_ROUND}}

You are an expert code reviewer. Review the following git diff and changed file contents for issues.
Report every issue you find using severity markers in this exact format:

```
- [P0] Critical issue description - /path/to/file.py:line-range
  Detailed explanation.

- [P1] High priority issue - /path/to/file.py:line-range
  Detailed explanation.
```

Severity levels:
- [P0] Critical: Security vulnerability, data loss, crash, or broken functionality
- [P1] High: Significant bug or design flaw that must be fixed
- [P2] Medium: Non-trivial issue that should be addressed
- [P3] Low: Minor quality issue or style problem
- [P4]-[P9]: Informational, suggestions, or nitpicks

## Review Configuration

- **Base**: {{REVIEW_BASE}} ({{REVIEW_BASE_TYPE}})
- **Round**: {{REVIEW_ROUND}}
- **Timestamp**: {{TIMESTAMP}}

## Git Diff

```diff
{{GIT_DIFF}}
```

## Changed File Contents

{{CHANGED_FILES_CONTENT}}

## Instructions

1. Review the diff and changed files carefully
2. Report every issue with a [P0-9] severity marker
3. Be specific: include file path and line range for each issue
4. If you find no issues, output only: "No issues found."
5. Do NOT output explanatory preamble - start directly with the issue list or "No issues found."
