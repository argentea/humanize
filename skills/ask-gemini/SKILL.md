---
name: ask-gemini
description: Consult Gemini as an independent expert. Sends a question or task to Gemini CLI and returns the response.
argument-hint: "[--gemini-model MODEL] [--gemini-timeout SECONDS] [question or task]"
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh:*)"
---

# Ask Gemini

Send a question or task to Gemini and return the response.

## How to Use

Execute the ask-gemini script with the user's arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ask-gemini.sh" $ARGUMENTS
```

## Interpreting Output

- The script outputs Gemini's response to **stdout** and status info to **stderr**
- Read the stdout output carefully and incorporate Gemini's response into your answer
- If the script exits with a non-zero code, report the error to the user

## Error Handling

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - Gemini response is in stdout |
| 1 | Validation error (missing gemini, empty question, invalid flags) |
| 124 | Timeout - suggest using `--gemini-timeout` with a larger value |
| Other | Gemini process error - report the exit code and any stderr output |

## Notes

- The response is saved to `.humanize/skill/<timestamp>/output.md` for reference
- Default model is `gemini-3.1-pro-preview` with a 3600-second timeout
