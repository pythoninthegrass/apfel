// ============================================================================
// Retry.swift — Exponential backoff retry for transient model errors
// Part of apfel — Apple Intelligence from the command line
// ============================================================================

import Foundation

/// Errors that should be retried (transient).
/// Safety filter refusals and invalid input should NOT be retried.
func isRetryableError(_ error: Error) -> Bool {
    let desc = error.localizedDescription.lowercased()
    // Retry on: timeout, unavailable, context window, generic model errors
    let retryablePatterns = [
        "timeout", "unavailable", "context window", "exceeded",
        "temporarily", "try again", "service", "overloaded"
    ]
    // Do NOT retry on: safety, unsafe, content policy
    let nonRetryablePatterns = [
        "unsafe", "safety", "content policy", "cannot assist",
        "not allowed", "inappropriate"
    ]

    if nonRetryablePatterns.contains(where: { desc.contains($0) }) {
        return false
    }
    if retryablePatterns.contains(where: { desc.contains($0) }) {
        return true
    }
    return false
}

/// Execute an async operation with exponential backoff retry.
/// - Parameters:
///   - maxRetries: Maximum number of retry attempts (default: 3)
///   - delays: Delay durations for each retry in seconds (default: 0.1, 0.5, 2.0)
///   - operation: The async throwing operation to execute
/// - Returns: The result of the successful operation
/// - Throws: The last error if all retries are exhausted
func withRetry<T: Sendable>(
    maxRetries: Int = 3,
    delays: [Double] = [0.1, 0.5, 2.0],
    operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 0...maxRetries {
        do {
            return try await operation()
        } catch {
            lastError = error

            // Don't retry non-retryable errors
            guard isRetryableError(error) else {
                throw error
            }

            // Don't retry if we've exhausted attempts
            guard attempt < maxRetries else {
                break
            }

            // Exponential backoff
            let delay = attempt < delays.count ? delays[attempt] : delays.last ?? 2.0
            printStderr("  retry \(attempt + 1)/\(maxRetries) after \(delay)s: \(error.localizedDescription)")
            try await Task.sleep(for: .seconds(delay))
        }
    }

    throw lastError!
}

// MARK: - Async Semaphore

/// A simple async semaphore for limiting concurrent operations.
/// Uses ID-based waiter tracking to prevent double-resume on timeout.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(value: Int) {
        self.count = value
    }

    /// Wait until a slot is available. Times out after the specified duration.
    func wait(timeout: Duration = .seconds(30)) async throws {
        if count > 0 {
            count -= 1
            return
        }

        let id = UUID()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            waiters.append((id: id, continuation: cont))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutWaiter(id: id)
            }
        }
    }

    /// Remove a waiter by ID and resume with timeout error.
    /// If signal() already resumed it, the waiter won't be in the array — no-op.
    private func timeoutWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(throwing: SemaphoreTimeoutError())
        }
    }

    /// Signal that a slot is available.
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            count += 1
        }
    }
}

struct SemaphoreTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Request queued too long — server at max concurrent capacity" }
}
