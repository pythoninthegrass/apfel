# TICKET-015: Deduplicate tool prompt/schema assembly

**Status:** Closed
**Priority:** P2
**Type:** Cleanup / DRY

---

## Problem

`Sources/Core/ToolCallHandler.swift` serializes tool schema arrays twice:

- `buildFallbackPrompt(tools:)`
- `buildSystemPrompt(tools:)`

Both functions:

- build the same `[[String: Any]]`
- parse `parametersJSON`
- serialize back to pretty-printed JSON
- fall back to `"[]"` on failure

This duplicates behavior in a high-surface compatibility path.

## Why It Matters

- Tool calling is one of the core OpenAI-compatibility features.
- Duplicate schema serialization makes fixes harder to apply consistently.
- Prompt-format changes currently require editing multiple functions.

## Suggested Fix

- Extract a single helper that serializes `[ToolDef]` into stable JSON.
- Reuse it from both prompt builders.
- Keep the emitted prompt text byte-for-byte equivalent unless explicitly intended otherwise.
- Add unit tests that cover:
  - descriptions
  - missing descriptions
  - invalid/missing `parametersJSON`
  - special-character escaping

## Files

- `Sources/Core/ToolCallHandler.swift`
- `Tests/apfelTests/ToolCallHandlerTests.swift`

## Validation

- `swift run apfel-tests`
- `swift build`
- `bash Tests/integration/run_tests.sh`
