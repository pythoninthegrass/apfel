import Foundation

public enum ApfelError: Error, Equatable, Sendable {
    case guardrailViolation
    case contextOverflow
    case rateLimited
    case concurrentRequest
    case unsupportedLanguage(String)
    case unknown(String)

    /// Classify any thrown error into a typed ApfelError.
    /// Matches on FoundationModels.GenerationError first, falls back to string matching.
    public static func classify(_ error: Error) -> ApfelError {
        // Try typed match first (FoundationModels errors)
        let typeName = String(describing: type(of: error))
        let mirror = String(reflecting: error)
        if typeName.contains("GenerationError") || mirror.contains("GenerationError") {
            if mirror.contains("guardrailViolation") || mirror.contains("refusal") {
                return .guardrailViolation
            }
            if mirror.contains("exceededContextWindowSize") {
                return .contextOverflow
            }
            if mirror.contains("rateLimited") {
                return .rateLimited
            }
            if mirror.contains("concurrentRequests") {
                return .concurrentRequest
            }
            if mirror.contains("unsupportedLanguageOrLocale") {
                return .unsupportedLanguage(error.localizedDescription)
            }
        }

        // Fallback: string matching for unknown error types
        let desc = error.localizedDescription.lowercased()
        if desc.contains("guardrail") || desc.contains("content policy") || desc.contains("unsafe") {
            return .guardrailViolation
        }
        if desc.contains("context window") || desc.contains("exceeded") {
            return .contextOverflow
        }
        if desc.contains("rate limit") || desc.contains("ratelimited") || desc.contains("rate_limit") {
            return .rateLimited
        }
        if desc.contains("concurrent") {
            return .concurrentRequest
        }
        if desc.contains("unsupported language") {
            return .unsupportedLanguage(error.localizedDescription)
        }
        return .unknown(error.localizedDescription)
    }

    public var cliLabel: String {
        switch self {
        case .guardrailViolation:  return "[guardrail]"
        case .contextOverflow:     return "[context overflow]"
        case .rateLimited:         return "[rate limited]"
        case .concurrentRequest:   return "[busy]"
        case .unsupportedLanguage: return "[unsupported language]"
        case .unknown:             return "[error]"
        }
    }

    public var openAIType: String {
        switch self {
        case .guardrailViolation:  return "content_policy_violation"
        case .contextOverflow:     return "context_length_exceeded"
        case .rateLimited:         return "rate_limit_error"
        case .concurrentRequest:   return "rate_limit_error"
        case .unsupportedLanguage: return "invalid_request_error"
        case .unknown:             return "server_error"
        }
    }

    /// HTTP status code for this error type.
    public var httpStatusCode: Int {
        switch self {
        case .guardrailViolation:  return 400
        case .contextOverflow:     return 400
        case .rateLimited:         return 429
        case .concurrentRequest:   return 429
        case .unsupportedLanguage: return 400
        case .unknown:             return 500
        }
    }

    public var openAIMessage: String {
        switch self {
        case .guardrailViolation:
            return "The request was blocked by Apple's safety guardrails. Try rephrasing."
        case .contextOverflow:
            return "Input exceeds the 4096-token context window. Shorten the conversation history."
        case .rateLimited:
            return "Apple Intelligence is rate limited. Retry after a few seconds."
        case .concurrentRequest:
            return "Apple Intelligence is busy with another request. Retry shortly."
        case .unsupportedLanguage(let msg):
            return "Unsupported language: \(msg)"
        case .unknown(let msg):
            return msg
        }
    }
}
