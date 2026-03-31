# TICKET-016: Centralize chat handler error/trace construction

**Status:** Closed
**Priority:** P2
**Type:** Cleanup / DRY

---

## Problem

`Sources/Handlers.swift` repeats the same failure-shape assembly for most early exits in `handleChatCompletion(...)`:

- create an OpenAI error response
- truncate request/response bodies for logs
- build a `ChatRequestTrace`
- append an event string

This pattern appears in JSON decode failures, validation failures, unsupported-parameter failures, image rejection, context-build failures, and model failures.

## Why It Matters

- The handler mixes business logic with response boilerplate.
- It is easy to make one branch diverge from the others.
- Small future changes to trace formatting would require touching many branches.

## Suggested Fix

- Extract a helper that builds the `(Response, ChatRequestTrace)` pair for failure paths.
- Keep status codes, error types, event messages, and log truncation behavior identical.
- Prefer keeping the helper local to `Handlers.swift` to avoid expanding surface area.

## Files

- `Sources/Handlers.swift`

## Validation

- `swift run apfel-tests`
- `swift build`
- `bash Tests/integration/run_tests.sh`
