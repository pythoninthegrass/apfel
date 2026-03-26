import Foundation
import ApfelCore

func runApfelErrorTests() {
    test("guardrail keyword → .guardrailViolation") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "guardrail violation occurred"])
        try assertEqual(ApfelError.classify(err), .guardrailViolation)
    }
    test("content policy keyword → .guardrailViolation") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "content policy blocked this request"])
        try assertEqual(ApfelError.classify(err), .guardrailViolation)
    }
    test("context window keyword → .contextOverflow") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "exceeded context window size"])
        try assertEqual(ApfelError.classify(err), .contextOverflow)
    }
    test("rate limit keyword → .rateLimited") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "rate limited, try later"])
        try assertEqual(ApfelError.classify(err), .rateLimited)
    }
    test("concurrent keyword → .concurrentRequest") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "concurrent requests not allowed"])
        try assertEqual(ApfelError.classify(err), .concurrentRequest)
    }
    test("unknown error → .unknown") {
        let err = NSError(domain: "FM", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "something went wrong"])
        if case .unknown = ApfelError.classify(err) { } else {
            throw TestFailure("expected .unknown")
        }
    }
    test("CLI labels") {
        try assertEqual(ApfelError.guardrailViolation.cliLabel, "[guardrail]")
        try assertEqual(ApfelError.contextOverflow.cliLabel, "[context overflow]")
        try assertEqual(ApfelError.rateLimited.cliLabel, "[rate limited]")
        try assertEqual(ApfelError.concurrentRequest.cliLabel, "[busy]")
        try assertEqual(ApfelError.unknown("x").cliLabel, "[error]")
    }
    test("OpenAI error types") {
        try assertEqual(ApfelError.guardrailViolation.openAIType, "content_policy_violation")
        try assertEqual(ApfelError.contextOverflow.openAIType, "context_length_exceeded")
        try assertEqual(ApfelError.rateLimited.openAIType, "rate_limit_error")
        try assertEqual(ApfelError.concurrentRequest.openAIType, "rate_limit_error")
    }
    test("HTTP status codes") {
        try assertEqual(ApfelError.guardrailViolation.httpStatusCode, 400)
        try assertEqual(ApfelError.contextOverflow.httpStatusCode, 400)
        try assertEqual(ApfelError.rateLimited.httpStatusCode, 429)
        try assertEqual(ApfelError.concurrentRequest.httpStatusCode, 429)
        try assertEqual(ApfelError.unknown("x").httpStatusCode, 500)
    }
    test("openAIMessage is non-empty for all cases") {
        let cases: [ApfelError] = [.guardrailViolation, .contextOverflow, .rateLimited,
                                    .concurrentRequest, .unknown("oops")]
        for c in cases {
            try assertTrue(!c.openAIMessage.isEmpty, "\(c)")
        }
    }
}
