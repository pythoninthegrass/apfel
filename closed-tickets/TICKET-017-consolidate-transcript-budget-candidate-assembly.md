# TICKET-017: Consolidate transcript budget candidate assembly

**Status:** Closed
**Priority:** P3
**Type:** Cleanup / DRY

---

## Problem

`Sources/Session.swift` and `Sources/Summarizer.swift` rebuild transcript candidate arrays in multiple places:

- `trimNewestFirst(...)`
- `trimOldestFirst(...)`
- `trimSlidingWindow(...)`
- the recent-entry loop inside `trimWithSummary(...)`

Each path manually appends `base`, a candidate history slice, and an optional final prompt before counting tokens.

## Why It Matters

- The trimming rules are correctness-sensitive.
- Duplicate candidate assembly makes off-by-one and ordering bugs harder to spot.
- Shared logic would make the strategies easier to reason about and maintain.

## Suggested Fix

- Extract a helper that assembles candidate entries for token-budget checks.
- Keep ordering identical for every strategy.
- Add coverage where possible for ordering-sensitive behavior or at minimum verify via build/tests after refactor.

## Files

- `Sources/Session.swift`
- `Sources/Summarizer.swift`

## Validation

- `swift run apfel-tests`
- `swift build`
- `bash Tests/integration/run_tests.sh`
