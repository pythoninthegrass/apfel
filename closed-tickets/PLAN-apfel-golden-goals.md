# Apfel Golden Goals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform apfel into a perfect Unix CLI tool AND a fully OpenAI-API-compatible local server backed by Apple's FoundationModels.

**Architecture:** Every `/v1/chat/completions` request creates a fresh `LanguageModelSession`; conversation history is packed into the session instructions as formatted text (stateless→stateful bridge). Tool calling is implemented via system-prompt injection + JSON detection since Apple's `Tool` protocol is compile-time only and cannot bridge the OpenAI client-side execution loop. Real token counting uses Apple's `tokenCount(for:)` / `contextSize` APIs (26.4, back-deployed) to enforce the 4096-token hard limit.

**Tech Stack:** Swift 6.2, FoundationModels.framework (macOS 26+), Hummingbird 2.x HTTP, Apple Silicon only.

---

## Critical Bugs Being Fixed

| Bug | Location | Impact |
|---|---|---|
| History replay calls `session.respond()` on old messages | `Handlers.swift:127-138` | Re-runs model on history → wrong answers, token waste, context overflow |
| Token counting is `chars / 4` estimate | `Models.swift:122` | `/v1/chat/completions` `usage` field is fiction |
| `--chat` has zero context window protection | `CLI.swift:73` | Crashes after ~5-6 turns with `exceededContextWindowSize` |
| Errors are all "error:" with no type info | `Output.swift` | Can't distinguish guardrail vs overflow vs rate limit |

---

## File Map

### New Files

| File | Lines | Responsibility |
|---|---|---|
| `Sources/TokenCounter.swift` | ~55 | Apple `tokenCount(for:)` + `contextSize` wrapper; char/4 fallback |
| `Sources/ApfelError.swift` | ~70 | Map `LanguageModelError` → typed enum → OpenAI error JSON + CLI label |
| `Sources/ContextManager.swift` | ~110 | Pack OpenAI `messages[]` into session instructions; truncate oldest to fit 4096 |
| `Sources/ToolCallHandler.swift` | ~110 | Build tools system-prompt; detect/parse JSON tool calls from model output |
| `Sources/ToolModels.swift` | ~80 | OpenAI tool types (`OpenAITool`, `ToolCall`, `ToolCallFunction`, `ToolChoice`) |
| `Sources/Handlers+Streaming.swift` | ~80 | Extracted streaming response (moved from Handlers.swift) |
| `Tests/apfelTests/ToolCallHandlerTests.swift` | ~80 | Unit tests for tool detection/parsing (no FoundationModels dep) |
| `Tests/apfelTests/ApfelErrorTests.swift` | ~50 | Unit tests for error classification |

### Modified Files

| File | Current Lines | Change |
|---|---|---|
| `Sources/Models.swift` | 125 | Add `temperature`/`seed`/`tools`/`response_format` to request; fix `OpenAIMessage` for content array + `tool_calls` field; delete `estimateTokens` |
| `Sources/Session.swift` | 51 | Add `SessionOptions` struct; `makeSession(_ options:)` with `GenerationOptions` + permissive mode |
| `Sources/Handlers.swift` | 353 | Rewrite: use ContextManager + ToolCallHandler; move streaming code out; ~130 lines |
| `Sources/SSE.swift` | 62 | Add `sseToolCallChunk`, `sseContentFilterChunk`, `sseLengthChunk` |
| `Sources/CLI.swift` | 192 | Add `--tokens` display, `--permissive` flow, typed error output, chat context management |
| `Sources/main.swift` | 196 | Add `--temperature`, `--max-tokens`, `--seed`, `--permissive`, `--tokens`, `--model-info`; read env vars |
| `Sources/Server.swift` | 189 | Add `/v1/completions` 501, `/v1/embeddings` 501, OPTIONS CORS preflight; enhance `/health` and `/v1/models` |
| `Sources/Retry.swift` | 125 | Add Apple `rateLimited`/`concurrentRequests` to retryable list |
| `Package.swift` | 28 | Add test target |

---

## Phase 1 — Token Counting (Foundation)

### Task 1: Add test target to Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Tests/apfelTests/ToolCallHandlerTests.swift` (placeholder)

- [ ] **Step 1.1: Add test target**

```swift
// Package.swift — add after existing targets:
.testTarget(
    name: "apfelTests",
    dependencies: [],
    path: "Tests/apfelTests"
)
```

- [ ] **Step 1.2: Create placeholder test file**

```swift
// Tests/apfelTests/ToolCallHandlerTests.swift
import Testing

@Suite struct ToolCallHandlerTests {}
```

- [ ] **Step 1.3: Verify build**

```bash
cd ~/dev/apfel && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 1.4: Commit**

```bash
git add Package.swift Tests/
git commit -m "test: add test target scaffold"
```

---

### Task 2: TokenCounter

**Files:**
- Create: `Sources/TokenCounter.swift`

Token counting uses `SystemLanguageModel.default.tokenCount(for:)` from macOS 26.4 (back-deployed). The actor serialises access to avoid concurrent calls on the model object.

- [ ] **Step 2.1: Create TokenCounter**

```swift
// Sources/TokenCounter.swift
import FoundationModels

actor TokenCounter {
    static let shared = TokenCounter()
    private let model = SystemLanguageModel.default

    /// Count tokens in text. Falls back to chars/4 if API throws.
    func count(_ text: String) async -> Int {
        guard !text.isEmpty else { return 0 }
        do {
            return try await model.tokenCount(for: text)
        } catch {
            return max(1, text.count / 4)
        }
    }

    /// Total context window size (currently 4096).
    func contextSize() async -> Int {
        do {
            return try await model.contextSize
        } catch {
            return 4096
        }
    }

    /// Tokens available for model input given a reserved output budget.
    func inputBudget(reservedForOutput: Int = 512) async -> Int {
        return await contextSize() - reservedForOutput
    }
}
```

- [ ] **Step 2.2: Delete `estimateTokens` from Models.swift**

In `Sources/Models.swift`, remove lines 119-124:
```swift
// DELETE this entire block:
/// Rough token estimate: characters / 4 (standard approximation).
/// FoundationModels doesn't expose actual token counts.
func estimateTokens(_ text: String) -> Int {
    max(1, text.count / 4)
}
```

- [ ] **Step 2.3: Fix callers of `estimateTokens`**

In `Sources/Handlers.swift`, replace all `estimateTokens(...)` calls with `await TokenCounter.shared.count(...)`.

In `Sources/Logging.swift`, replace `estimateTokens(prev)` (line 287) with `await TokenCounter.shared.count(prev)`.

- [ ] **Step 2.4: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```
Expected: `Build complete!`

- [ ] **Step 2.5: Commit**

```bash
git add Sources/TokenCounter.swift Sources/Models.swift Sources/Handlers.swift Sources/Logging.swift
git commit -m "feat: replace char/4 estimate with Apple tokenCount(for:) API"
```

---

## Phase 2 — Error Typing

### Task 3: ApfelError enum

**Files:**
- Create: `Sources/ApfelError.swift`
- Create: `Tests/apfelTests/ApfelErrorTests.swift`

Apple throws `LanguageModelError` with cases like `guardrailViolation`, `exceededContextWindowSize`, `rateLimited`, `concurrentRequests`. We need to map these to a typed enum that knows its OpenAI format AND its CLI label.

- [ ] **Step 3.1: Write failing test**

```swift
// Tests/apfelTests/ApfelErrorTests.swift
import Testing
@testable import apfelTests

// NOTE: ApfelError is pure logic — no FoundationModels import needed in this file.
// We match on error description strings since LanguageModelError is not importable in tests.

@Suite struct ApfelErrorTests {
    @Test func guardrailClassification() {
        let err = NSError(domain: "com.apple.FoundationModels", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "guardrail violation occurred"])
        let mapped = ApfelError.classify(err)
        #expect(mapped == .guardrailViolation)
    }

    @Test func contextOverflowClassification() {
        let err = NSError(domain: "com.apple.FoundationModels", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "exceeded context window size"])
        let mapped = ApfelError.classify(err)
        #expect(mapped == .contextOverflow)
    }

    @Test func rateLimitClassification() {
        let err = NSError(domain: "com.apple.FoundationModels", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "rate limited"])
        let mapped = ApfelError.classify(err)
        #expect(mapped == .rateLimited)
    }

    @Test func cliLabels() {
        #expect(ApfelError.guardrailViolation.cliLabel == "[guardrail]")
        #expect(ApfelError.contextOverflow.cliLabel == "[context overflow]")
        #expect(ApfelError.rateLimited.cliLabel == "[rate limited]")
        #expect(ApfelError.concurrentRequest.cliLabel == "[busy]")
        #expect(ApfelError.unknown("x").cliLabel == "[error]")
    }

    @Test func openAIErrorType() {
        #expect(ApfelError.guardrailViolation.openAIType == "content_policy_violation")
        #expect(ApfelError.contextOverflow.openAIType == "context_length_exceeded")
        #expect(ApfelError.rateLimited.openAIType == "rate_limit_error")
    }
}
```

- [ ] **Step 3.2: Run test — expect compile failure**

```bash
swift test --filter ApfelErrorTests 2>&1 | tail -10
```
Expected: compile error (ApfelError not defined)

- [ ] **Step 3.3: Implement ApfelError**

```swift
// Sources/ApfelError.swift
import Foundation

enum ApfelError: Equatable {
    case guardrailViolation
    case contextOverflow
    case rateLimited
    case concurrentRequest
    case unsupportedLanguage(String)
    case unknown(String)

    /// Classify any thrown error into a typed ApfelError.
    static func classify(_ error: Error) -> ApfelError {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("guardrail") || desc.contains("content policy") || desc.contains("unsafe") {
            return .guardrailViolation
        }
        if desc.contains("context window") || desc.contains("exceeded") {
            return .contextOverflow
        }
        if desc.contains("rate limit") || desc.contains("ratelimited") {
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

    var cliLabel: String {
        switch self {
        case .guardrailViolation: return "[guardrail]"
        case .contextOverflow:    return "[context overflow]"
        case .rateLimited:        return "[rate limited]"
        case .concurrentRequest:  return "[busy]"
        case .unsupportedLanguage: return "[unsupported language]"
        case .unknown:            return "[error]"
        }
    }

    var openAIType: String {
        switch self {
        case .guardrailViolation:  return "content_policy_violation"
        case .contextOverflow:     return "context_length_exceeded"
        case .rateLimited:         return "rate_limit_error"
        case .concurrentRequest:   return "rate_limit_error"
        case .unsupportedLanguage: return "invalid_request_error"
        case .unknown:             return "server_error"
        }
    }

    var openAIMessage: String {
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
```

Note: `ApfelError` lives in Sources but imports only `Foundation` — no FoundationModels. Tests can import it directly once the test target references the Sources module. The test target does NOT link FoundationModels, so ApfelError must stay framework-free.

**IMPORTANT:** To make `ApfelError` importable in tests, the test target needs access to Sources. Since this is an executable target (not a library), update `Package.swift` to add a library target for the testable logic:

```swift
// Package.swift — updated structure
let package = Package(
    name: "apfel",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "apfel",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                "ApfelCore",
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "./Info.plist"])
            ]
        ),
        .target(
            name: "ApfelCore",
            dependencies: [],
            path: "Sources/Core"       // pure-logic files go here
        ),
        .testTarget(
            name: "apfelTests",
            dependencies: ["ApfelCore"],
            path: "Tests/apfelTests"
        ),
    ]
)
```

Files that go into `Sources/Core/` (no FoundationModels dependency, testable):
- `ApfelError.swift`
- `ToolCallHandler.swift`

Files that stay in `Sources/` (FoundationModels dependent):
- Everything else

- [ ] **Step 3.4: Restructure Package.swift and move files**

```bash
mkdir -p ~/dev/apfel/Sources/Core
mv ~/dev/apfel/Sources/ApfelError.swift ~/dev/apfel/Sources/Core/
```

Update `Package.swift` as above.

- [ ] **Step 3.5: Run test — expect pass**

```bash
swift test --filter ApfelErrorTests 2>&1 | tail -5
```
Expected: `Test run with 5 tests passed`

- [ ] **Step 3.6: Wire ApfelError into Handlers.swift**

In `Sources/Handlers.swift`, replace the generic error catch:
```swift
// BEFORE:
} catch {
    let errMsg = "data: {\"error\":\"\(error.localizedDescription)\"}\n\n"
    ...
}

// AFTER:
} catch {
    let apfelErr = ApfelError.classify(error)
    let errMsg = "data: {\"error\":\"\(apfelErr.openAIMessage)\"}\n\n"
    ...
}
```

And wire into `openAIError()` calls:
```swift
// Use apfelErr.openAIType and apfelErr.openAIMessage
return openAIError(status: ..., message: apfelErr.openAIMessage, type: apfelErr.openAIType)
```

- [ ] **Step 3.7: Commit**

```bash
git add Sources/ Tests/ Package.swift
git commit -m "feat: typed error classification with OpenAI and CLI labels"
```

---

## Phase 3 — Context Management

### Task 4: ContextManager (history packing)

**Files:**
- Create: `Sources/ContextManager.swift`

This is the core fix for the broken history replay. Instead of calling `session.respond()` on old messages (which re-runs the model), we format all prior conversation as structured text inside the session instructions.

Apple's `LanguageModelSession(instructions:)` accepts a string. We pack the history there. The session only ever sees **one** `respond()` call — the final user message.

- [ ] **Step 4.1: Create ContextManager**

```swift
// Sources/ContextManager.swift
import FoundationModels

struct ContextPlan {
    let sessionInstructions: String   // system prompt + formatted history
    let finalUserMessage: String      // last user message to send to session
    let inputTokens: Int              // estimated input token count
    let messagesIncluded: Int         // how many history messages fit
    let wasTruncated: Bool            // true if history was truncated
}

struct ContextManager {
    private let tokenCounter = TokenCounter.shared
    private static let responseReserve = 512   // tokens reserved for model response
    private static let historyHeader = "\n\n## Prior Conversation\n"

    /// Build a ContextPlan from an OpenAI messages array.
    ///
    /// Strategy:
    /// 1. Extract system message → base instructions
    /// 2. Separate final user message from history
    /// 3. Pack history newest-first until token budget exhausted
    /// 4. Format packed history as structured text appended to instructions
    func buildPlan(
        messages: [OpenAIMessage],
        toolsPrompt: String? = nil
    ) async -> ContextPlan {
        let budget = await tokenCounter.inputBudget(reservedForOutput: Self.responseReserve)

        let systemText = messages.first(where: { $0.role == "system" })?.textContent ?? ""
        let toolsBlock = toolsPrompt.map { "\n\n" + $0 } ?? ""
        let baseInstructions = systemText + toolsBlock

        let baseTokens = await tokenCounter.count(baseInstructions)

        let conversationMessages = messages.filter { $0.role != "system" }
        guard !conversationMessages.isEmpty else {
            return ContextPlan(sessionInstructions: baseInstructions,
                               finalUserMessage: "", inputTokens: baseTokens,
                               messagesIncluded: 0, wasTruncated: false)
        }

        let finalMsg = conversationMessages.last!
        let historyMessages = conversationMessages.dropLast()

        guard !historyMessages.isEmpty else {
            return ContextPlan(sessionInstructions: baseInstructions,
                               finalUserMessage: finalMsg.textContent ?? "",
                               inputTokens: baseTokens + (await tokenCounter.count(finalMsg.textContent ?? "")),
                               messagesIncluded: 0, wasTruncated: false)
        }

        // Pack history newest-first; stop when budget exceeded
        var packed: [String] = []
        var usedTokens = baseTokens
        let headerTokens = await tokenCounter.count(Self.historyHeader)
        usedTokens += headerTokens

        var included = 0
        for msg in historyMessages.reversed() {
            let line = formatHistoryMessage(msg)
            let lineTokens = await tokenCounter.count(line)
            if usedTokens + lineTokens > budget { break }
            packed.insert(line, at: 0)
            usedTokens += lineTokens
            included += 1
        }

        let wasTruncated = included < historyMessages.count

        let historyBlock = packed.isEmpty ? ""
            : Self.historyHeader + packed.joined(separator: "\n") + "\n\n---"
        let finalInstructions = baseInstructions + historyBlock

        return ContextPlan(
            sessionInstructions: finalInstructions,
            finalUserMessage: finalMsg.textContent ?? "",
            inputTokens: usedTokens,
            messagesIncluded: included,
            wasTruncated: wasTruncated
        )
    }

    private func formatHistoryMessage(_ msg: OpenAIMessage) -> String {
        switch msg.role {
        case "user":
            return "User: \(msg.textContent ?? "")"
        case "assistant":
            if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                let calls = toolCalls.map { "[Called: \($0.function.name)(\($0.function.arguments))]" }
                return calls.joined(separator: "\n")
            }
            return "Assistant: \(msg.textContent ?? "")"
        case "tool":
            return "[Function result for \(msg.name ?? "function"): \(msg.textContent ?? "")]"
        default:
            return "\(msg.role.capitalized): \(msg.textContent ?? "")"
        }
    }
}
```

- [ ] **Step 4.2: Add `textContent` to OpenAIMessage in Models.swift**

The OpenAI API allows `content` to be either a `String` OR an array of `{type, text}` content parts. Update `OpenAIMessage`:

```swift
// Sources/Models.swift — replace OpenAIMessage
struct OpenAIMessage: Codable, Sendable {
    let role: String
    let content: MessageContent?          // null when role=assistant with tool_calls
    let tool_calls: [ToolCall]?            // present when role=assistant + tool call
    let tool_call_id: String?             // present when role=tool
    let name: String?                     // optional, used in role=tool messages

    /// Convenience: extract plain text from any content variant.
    /// Returns nil if content contains unsupported types (images).
    var textContent: String? {
        switch content {
        case .text(let s): return s
        case .parts(let parts):
            // Reject if any image part present
            if parts.contains(where: { $0.type == "image_url" }) { return nil }
            return parts.compactMap { $0.text }.joined()
        case .none: return nil
        }
    }
}

enum MessageContent: Codable, Sendable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s); return
        }
        self = .parts(try container.decode([ContentPart].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }
}

struct ContentPart: Codable, Sendable {
    let type: String     // "text" or "image_url"
    let text: String?
}
```

- [ ] **Step 4.3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4.4: Commit**

```bash
git add Sources/ContextManager.swift Sources/Models.swift
git commit -m "feat: ContextManager — history-as-instructions strategy, replaces broken session.respond() replay"
```

---

## Phase 4 — Tool Calling

### Task 5: ToolModels

**Files:**
- Create: `Sources/ToolModels.swift`
- Modify: `Sources/Models.swift` (add tools fields to request)

- [ ] **Step 5.1: Create ToolModels.swift**

```swift
// Sources/ToolModels.swift
import Foundation

struct OpenAITool: Decodable, Sendable {
    let type: String                  // "function"
    let function: OpenAIFunction
}

struct OpenAIFunction: Decodable, Sendable {
    let name: String
    let description: String?
    let parameters: RawJSON?          // JSON schema — keep as raw JSON
}

/// Raw JSON value — stores arbitrary JSON without a fixed schema.
struct RawJSON: Decodable, Sendable {
    let value: String                 // original JSON string

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode to get canonical string representation
        let raw = try container.decode(AnyCodable.self)
        let data = try JSONEncoder().encode(raw)
        value = String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String                  // "function"
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String             // JSON string (OpenAI sends string, not object)
}

enum ToolChoice: Decodable, Sendable {
    case auto
    case none
    case required
    case specific(name: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            switch s {
            case "none": self = .none
            case "required": self = .required
            default: self = .auto
            }
            return
        }
        struct Specific: Decodable { struct Fn: Decodable { let name: String }; let function: Fn }
        if let obj = try? container.decode(Specific.self) {
            self = .specific(name: obj.function.name); return
        }
        self = .auto
    }
}

struct ResponseFormat: Decodable, Sendable {
    let type: String    // "text" or "json_object"
}

/// Type-erased Codable for raw JSON values.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { value = v; return }
        if let v = try? c.decode(Int.self)    { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v; return }
        value = ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        default: try c.encode("")
        }
    }
}
```

- [ ] **Step 5.2: Add tools fields to ChatCompletionRequest in Models.swift**

```swift
// Sources/Models.swift — extend ChatCompletionRequest
struct ChatCompletionRequest: Decodable, Sendable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool?
    let temperature: Double?
    let max_tokens: Int?
    let seed: Int?
    // Tool calling
    let tools: [OpenAITool]?
    let tool_choice: ToolChoice?
    // Response format
    let response_format: ResponseFormat?
    // Accepted but ignored (no parse error, logged as warning)
    let logprobs: Bool?
    let n: Int?
    let user: String?
}
```

Also extend `ChatCompletionResponse.Choice` to include optional `tool_calls`:
```swift
struct Choice: Encodable, Sendable {
    let index: Int
    let message: OpenAIMessage
    let finish_reason: String    // "stop" | "tool_calls" | "length" | "content_filter"
}
```

And `ChatCompletionChunk.ChunkChoice`:
```swift
struct ChunkChoice: Encodable, Sendable {
    let index: Int
    let delta: Delta
    let finish_reason: String?
}
struct Delta: Encodable, Sendable {
    let role: String?
    let content: String?
    let tool_calls: [ToolCall]?  // present in tool call streaming chunks
}
```

- [ ] **Step 5.3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 5.4: Commit**

```bash
git add Sources/ToolModels.swift Sources/Models.swift
git commit -m "feat: OpenAI tool calling types (ToolModels + request extensions)"
```

---

### Task 6: ToolCallHandler

**Files:**
- Create: `Sources/Core/ToolCallHandler.swift`
- Modify: `Tests/apfelTests/ToolCallHandlerTests.swift`

Tool calling works via system-prompt injection + output parsing. Why not Apple's native `Tool` protocol? Because Apple's tool protocol requires **compile-time Swift type definitions** and **executes the tool automatically**. OpenAI's protocol requires **runtime JSON schema definitions** and **pauses for the client to execute**. These are architecturally incompatible. System-prompt injection is the only feasible bridge.

- [ ] **Step 6.1: Write failing tests**

```swift
// Tests/apfelTests/ToolCallHandlerTests.swift
import Testing
@testable import ApfelCore

@Suite struct ToolCallHandlerTests {

    // MARK: - Tool call detection

    @Test func detectsCleanJSON() {
        let response = #"{"tool_calls": [{"id": "call_abc", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\":\"Vienna\"}"}}]}"#
        let result = ToolCallHandler.detectToolCall(in: response)
        #expect(result != nil)
        #expect(result?.first?.name == "get_weather")
        #expect(result?.first?.id == "call_abc")
    }

    @Test func detectsJSONInMarkdownBlock() {
        let response = """
        ```json
        {"tool_calls": [{"id": "call_xyz", "type": "function", "function": {"name": "search", "arguments": "{}"}}]}
        ```
        """
        let result = ToolCallHandler.detectToolCall(in: response)
        #expect(result != nil)
        #expect(result?.first?.name == "search")
    }

    @Test func detectsJSONWithPreamble() {
        let response = "I'll look that up for you.\n{\"tool_calls\": [{\"id\": \"c1\", \"type\": \"function\", \"function\": {\"name\": \"calc\", \"arguments\": \"{}\"}}]}"
        let result = ToolCallHandler.detectToolCall(in: response)
        #expect(result != nil)
    }

    @Test func rejectsPlainResponse() {
        let response = "Vienna is the capital of Austria."
        let result = ToolCallHandler.detectToolCall(in: response)
        #expect(result == nil)
    }

    @Test func rejectsMalformedJSON() {
        let response = "{tool_calls: broken}"
        let result = ToolCallHandler.detectToolCall(in: response)
        #expect(result == nil)
    }

    // MARK: - System prompt building

    @Test func buildsToolsSystemPrompt() throws {
        let tools = [
            ToolDef(name: "get_weather", description: "Get weather", parametersJSON: #"{"type":"object","properties":{"location":{"type":"string"}}}"#)
        ]
        let prompt = ToolCallHandler.buildSystemPrompt(tools: tools)
        #expect(prompt.contains("get_weather"))
        #expect(prompt.contains("tool_calls"))
        #expect(prompt.contains("JSON"))
    }

    // MARK: - Tool result formatting

    @Test func formatsToolResult() {
        let result = ToolCallHandler.formatToolResult(callId: "call_1", name: "get_weather", content: "Sunny, 22°C")
        #expect(result.contains("get_weather"))
        #expect(result.contains("Sunny, 22°C"))
    }
}
```

- [ ] **Step 6.2: Run test — expect compile failure**

```bash
swift test --filter ToolCallHandlerTests 2>&1 | tail -5
```

- [ ] **Step 6.3: Implement ToolCallHandler in Sources/Core/**

```swift
// Sources/Core/ToolCallHandler.swift
import Foundation

/// A tool definition for system-prompt injection (framework-independent).
struct ToolDef {
    let name: String
    let description: String?
    let parametersJSON: String?   // raw JSON schema string
}

/// A parsed tool call from model output.
struct ParsedToolCall {
    let id: String
    let name: String
    let argumentsString: String   // JSON string, as OpenAI expects
}

enum ToolCallHandler {

    // MARK: - System Prompt Building

    /// Build the tool-calling instruction block to inject into session instructions.
    /// Uses a simple JSON format the on-device model can reliably follow.
    static func buildSystemPrompt(tools: [ToolDef]) -> String {
        let schemas = tools.map { tool -> String in
            var parts = ["  {", "    \"name\": \"\(tool.name)\""]
            if let desc = tool.description {
                parts.append("    \"description\": \"\(desc)\"")
            }
            if let params = tool.parametersJSON {
                parts.append("    \"parameters\": \(params)")
            }
            parts.append("  }")
            return parts.joined(separator: ",\n")
        }.joined(separator: ",\n")

        return """
        ## Available Functions
        When you need to call a function, respond ONLY with the following JSON (no other text before or after):
        {"tool_calls": [{"id": "call_<unique>", "type": "function", "function": {"name": "<name>", "arguments": "<escaped_json_string>"}}]}

        Replace <unique> with a short random string, <name> with the function name, and <escaped_json_string> with a JSON-encoded string of the arguments object.

        Available functions:
        [
        \(schemas)
        ]
        """
    }

    // MARK: - Tool Call Detection

    /// Detect and parse tool calls from model output.
    /// Returns nil if the response is a normal text reply.
    /// Handles: clean JSON, JSON in markdown code blocks, JSON after preamble text.
    static func detectToolCall(in response: String) -> [ParsedToolCall]? {
        let candidates = extractJSONCandidates(from: response)
        for candidate in candidates {
            if let calls = parseToolCallJSON(candidate) {
                return calls.isEmpty ? nil : calls
            }
        }
        return nil
    }

    // MARK: - Tool Result Formatting

    /// Format a tool result for injection into conversation history.
    static func formatToolResult(callId: String, name: String, content: String) -> String {
        return "[Function result for \(name) (id: \(callId))]: \(content)"
    }

    // MARK: - Helpers

    private static func extractJSONCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        // 1. Whole response as JSON
        candidates.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // 2. Strip markdown code blocks (```json ... ```)
        let blockPattern = #/```(?:json)?\s*([\s\S]*?)```/#
        for match in text.matches(of: blockPattern) {
            candidates.append(String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 3. Find JSON object starting with {"tool_calls"
        if let range = text.range(of: "{\"tool_calls\"") {
            candidates.append(String(text[range.lowerBound...]))
        }
        return candidates
    }

    private static func parseToolCallJSON(_ json: String) -> [ParsedToolCall]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCalls = obj["tool_calls"] as? [[String: Any]] else { return nil }

        var result: [ParsedToolCall] = []
        for call in rawCalls {
            guard let id = call["id"] as? String,
                  let fn = call["function"] as? [String: Any],
                  let name = fn["name"] as? String else { continue }
            let args: String
            if let s = fn["arguments"] as? String { args = s }
            else if let obj = fn["arguments"],
                    let data = try? JSONSerialization.data(withJSONObject: obj),
                    let s = String(data: data, encoding: .utf8) { args = s }
            else { args = "{}" }
            result.append(ParsedToolCall(id: id, name: name, argumentsString: args))
        }
        return result.isEmpty ? nil : result
    }
}
```

- [ ] **Step 6.4: Run tests — expect pass**

```bash
swift test --filter ToolCallHandlerTests 2>&1 | tail -10
```
Expected: all 7 tests pass

- [ ] **Step 6.5: Commit**

```bash
git add Sources/Core/ToolCallHandler.swift Tests/apfelTests/ToolCallHandlerTests.swift
git commit -m "feat: ToolCallHandler — system-prompt injection + JSON detection for OpenAI tool calling"
```

---

## Phase 5 — Session Options

### Task 7: SessionOptions + GenerationOptions wiring

**Files:**
- Modify: `Sources/Session.swift`

Apple's `GenerationOptions` lets us set `maximumResponseTokens` and sampling mode (temperature, seed). Currently apfel ignores all of these.

- [ ] **Step 7.1: Rewrite Session.swift**

```swift
// Sources/Session.swift
import FoundationModels

struct SessionOptions: Sendable {
    var instructions: String?
    var temperature: Double?
    var maxTokens: Int?
    var seed: Int?
    var permissive: Bool = false
}

/// Create a session with options.
/// - permissive: uses .permissiveContentTransformations guardrails (for summarization/extraction tasks).
func makeSession(_ options: SessionOptions = SessionOptions()) -> LanguageModelSession {
    let model: SystemLanguageModel = options.permissive
        ? SystemLanguageModel(guardrails: .permissiveContentTransformations)
        : .default

    if let instructions = options.instructions {
        return LanguageModelSession(model: model, instructions: instructions)
    }
    return LanguageModelSession(model: model)
}

/// Build GenerationOptions from session options.
func makeGenerationOptions(_ options: SessionOptions, contextBudgetRemaining: Int? = nil) -> GenerationOptions {
    let maxTokens = min(
        options.maxTokens ?? 1024,
        contextBudgetRemaining ?? 1024
    )

    let sampling: SamplingMode
    if let temp = options.temperature {
        if let seed = options.seed {
            sampling = .random(temperature: Float(temp), seed: seed)
        } else {
            sampling = .random(temperature: Float(temp))
        }
    } else if let seed = options.seed {
        sampling = .random(seed: seed)
    } else {
        sampling = .default
    }

    return GenerationOptions(sampling: sampling, maximumResponseTokens: maxTokens)
}

/// Stream a response, computing deltas from cumulative snapshots.
func collectStream(
    _ session: LanguageModelSession,
    prompt: String,
    options: GenerationOptions = GenerationOptions(),
    printDelta: Bool
) async throws -> String {
    let response = session.streamResponse(to: prompt, options: options)
    var prev = ""
    for try await snapshot in response {
        let content = snapshot.content
        if content.count > prev.count {
            let idx = content.index(content.startIndex, offsetBy: prev.count)
            let delta = String(content[idx...])
            if printDelta {
                print(delta, terminator: "")
                fflush(stdout)
            }
        }
        prev = content
    }
    return prev
}
```

- [ ] **Step 7.2: Update callers**

Update all `makeSession(systemPrompt:)` calls to use `makeSession(SessionOptions(instructions: systemPrompt))`.
Update `collectStream` calls to pass `options:`.

- [ ] **Step 7.3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 7.4: Commit**

```bash
git add Sources/Session.swift
git commit -m "feat: SessionOptions — wire temperature, seed, maxTokens, permissive mode to Apple GenerationOptions"
```

---

## Phase 6 — Handler Rewrite

### Task 8: Rewrite Handlers.swift (the core fix)

**Files:**
- Modify: `Sources/Handlers.swift` (full rewrite, ~130 lines)
- Create: `Sources/Handlers+Streaming.swift` (~80 lines, extracted from old Handlers.swift)

This is the most important task. The rewrite:
1. Fixes the broken history replay (replace with ContextManager)
2. Handles tool calling (ToolCallHandler)
3. Wires GenerationOptions (temperature, seed, max_tokens)
4. Returns real token counts
5. Handles `response_format: json_object`
6. Rejects image content with a clear error
7. Accepts any model name (normalizes to apple-foundationmodel)

- [ ] **Step 8.1: Create Handlers+Streaming.swift**

Move the streaming response logic from the existing Handlers.swift into this file. Extract the `streamingResponse` function as-is first, then update it in step 8.3.

```swift
// Sources/Handlers+Streaming.swift
// (Move existing streamingResponse function here verbatim, then update in next step)
```

- [ ] **Step 8.2: Rewrite Handlers.swift**

```swift
// Sources/Handlers.swift — full rewrite
import FoundationModels
import Foundation
import Hummingbird
import NIOCore

struct ChatRequestTrace: Sendable {
    let stream: Bool
    let promptTokens: Int
    let completionTokens: Int
    let error: String?
    let requestBody: String?
    let responseBody: String?
    let events: [String]
    let wasTruncated: Bool
}

// MARK: - /v1/chat/completions

func handleChatCompletion(
    _ request: Request,
    context: some RequestContext
) async throws -> (response: Response, trace: ChatRequestTrace) {

    // 1. Decode
    let body = try await request.body.collect(upTo: 1024 * 1024)
    let requestBodyString = body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""
    var events: [String] = ["request bytes=\(body.readableBytes)"]

    let chatRequest: ChatCompletionRequest
    do {
        chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)
    } catch {
        return errorTrace(ApfelError.unknown("Invalid JSON: \(error.localizedDescription)"),
                          stream: false, requestBody: requestBodyString, events: events)
    }

    // 2. Validate messages
    guard !chatRequest.messages.isEmpty else {
        return errorTrace(ApfelError.unknown("'messages' must not be empty"),
                          stream: false, requestBody: requestBodyString, events: events)
    }
    guard chatRequest.messages.last?.role == "user" || chatRequest.messages.last?.role == "tool" else {
        return errorTrace(ApfelError.unknown("Last message must have role 'user' or 'tool'"),
                          stream: false, requestBody: requestBodyString, events: events)
    }

    // 3. Reject image content
    for msg in chatRequest.messages where msg.textContent == nil && msg.role != "assistant" {
        if case .parts(let parts) = msg.content, parts.contains(where: { $0.type == "image_url" }) {
            return errorTrace(ApfelError.unknown("Image content is not supported. Apple FoundationModels accepts text only."),
                              stream: false, requestBody: requestBodyString, events: events)
        }
    }

    // 4. Log ignored/unsupported params
    if chatRequest.logprobs == true { events.append("warn: logprobs not supported, ignored") }
    if let n = chatRequest.n, n > 1 { events.append("warn: n=\(n) not supported, using n=1") }
    if chatRequest.model != modelName { events.append("info: model '\(chatRequest.model)' mapped to \(modelName)") }

    // 5. Build tools system prompt if tools provided
    let toolDefs: [ToolDef] = (chatRequest.tools ?? []).map {
        ToolDef(name: $0.function.name,
                description: $0.function.description,
                parametersJSON: $0.function.parameters?.value)
    }
    let toolsPrompt: String? = toolDefs.isEmpty ? nil : ToolCallHandler.buildSystemPrompt(tools: toolDefs)

    // 6. Handle response_format: json_object via prompt injection
    var extraInstructions = ""
    if chatRequest.response_format?.type == "json_object" {
        extraInstructions += "\n\nRespond ONLY with valid JSON. Do not include any text outside the JSON object."
        events.append("info: json_object mode via prompt injection")
    }

    // 7. Build context plan
    var messagesForContext = chatRequest.messages
    if !extraInstructions.isEmpty {
        // Inject as system message
        let sysIdx = messagesForContext.firstIndex(where: { $0.role == "system" })
        if let idx = sysIdx {
            let existing = messagesForContext[idx].textContent ?? ""
            messagesForContext[idx] = OpenAIMessage(
                role: "system",
                content: .text(existing + extraInstructions),
                tool_calls: nil, tool_call_id: nil, name: nil
            )
        } else {
            messagesForContext.insert(
                OpenAIMessage(role: "system", content: .text(String(extraInstructions.dropFirst(2))),
                              tool_calls: nil, tool_call_id: nil, name: nil),
                at: 0
            )
        }
    }

    let contextManager = ContextManager()
    let plan = await contextManager.buildPlan(messages: messagesForContext, toolsPrompt: toolsPrompt)
    events.append("context: included=\(plan.messagesIncluded) truncated=\(plan.wasTruncated) inputTokens≈\(plan.inputTokens)")

    // 8. Build session options
    let permissive = request.headers[HTTPField.Name("X-Apfel-Guardrails")!] == "permissive"
    var sessionOpts = SessionOptions(
        instructions: plan.sessionInstructions.isEmpty ? nil : plan.sessionInstructions,
        temperature: chatRequest.temperature,
        maxTokens: chatRequest.max_tokens,
        seed: chatRequest.seed,
        permissive: permissive
    )
    // Force non-streaming if tools are present (need to inspect full response)
    let forceNonStream = toolDefs.isNotEmpty && chatRequest.stream == true

    // 9. Dispatch
    let id = "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())"
    let created = Int(Date().timeIntervalSince1970)

    if chatRequest.stream == true && !forceNonStream {
        let result = streamingResponse(
            sessionOpts: sessionOpts, prompt: plan.finalUserMessage,
            id: id, created: created, requestBody: requestBodyString,
            events: events, wasTruncated: plan.wasTruncated
        )
        return (result.response, result.trace)
    } else {
        return try await nonStreamingResponse(
            sessionOpts: sessionOpts, prompt: plan.finalUserMessage,
            id: id, created: created, requestBody: requestBodyString,
            events: events, wasTruncated: plan.wasTruncated,
            toolDefs: toolDefs, isStreamFallback: forceNonStream
        )
    }
}
```

- [ ] **Step 8.3: Update Handlers+Streaming.swift**

Update the extracted streaming function to use `SessionOptions` and return proper `finish_reason` including `"content_filter"` and `"length"`:

```swift
// Sources/Handlers+Streaming.swift — key changes to streamingResponse:
// - Accept SessionOptions instead of LanguageModelSession
// - Create session inside the async stream task
// - Use makeGenerationOptions to pass to streamResponse(to:options:)
// - Catch ApfelError.guardrailViolation → sseContentFilterChunk
// - Track if max tokens hit → sseLengthChunk

func streamingResponse(
    sessionOpts: SessionOptions,
    prompt: String,
    id: String,
    created: Int,
    requestBody: String,
    events: [String],
    wasTruncated: Bool
) -> (response: Response, trace: ChatRequestTrace) { ... }
```

Also add to `SSE.swift`:
```swift
func sseContentFilterChunk(id: String, created: Int) -> ChatCompletionChunk {
    ChatCompletionChunk(id: id, object: "chat.completion.chunk", created: created, model: modelName,
        choices: [.init(index: 0, delta: .init(role: nil, content: nil, tool_calls: nil), finish_reason: "content_filter")])
}
```

- [ ] **Step 8.4: Implement nonStreamingResponse with tool call support**

```swift
// In Handlers.swift (continuation)
private func nonStreamingResponse(
    sessionOpts: SessionOptions,
    prompt: String,
    id: String,
    created: Int,
    requestBody: String,
    events: [String],
    wasTruncated: Bool,
    toolDefs: [ToolDef],
    isStreamFallback: Bool
) async throws -> (response: Response, trace: ChatRequestTrace) {

    var events = events
    let session = makeSession(sessionOpts)
    let genOpts = makeGenerationOptions(sessionOpts)

    let rawContent: String
    let apfelErr: ApfelError?

    do {
        let result = try await session.respond(to: prompt, options: genOpts)
        rawContent = result.content
        apfelErr = nil
        events.append("non-stream response chars=\(rawContent.count)")
    } catch {
        let err = ApfelError.classify(error)
        apfelErr = err
        return errorTrace(err, stream: isStreamFallback, requestBody: requestBody, events: events)
    }

    let promptTokens = await TokenCounter.shared.count(sessionOpts.instructions ?? "" + prompt)
    let completionTokens = await TokenCounter.shared.count(rawContent)

    // Detect tool calls
    if !toolDefs.isEmpty, let parsedCalls = ToolCallHandler.detectToolCall(in: rawContent) {
        events.append("tool_calls detected: \(parsedCalls.map(\.name).joined(separator: ","))")
        let toolCalls = parsedCalls.map {
            ToolCall(id: $0.id, type: "function", function: ToolCallFunction(name: $0.name, arguments: $0.argumentsString))
        }
        let assistantMsg = OpenAIMessage(role: "assistant", content: nil,
                                         tool_calls: toolCalls, tool_call_id: nil, name: nil)
        let payload = ChatCompletionResponse(
            id: id, object: "chat.completion", created: created, model: modelName,
            choices: [.init(index: 0, message: assistantMsg, finish_reason: "tool_calls")],
            usage: .init(prompt_tokens: promptTokens, completion_tokens: completionTokens,
                         total_tokens: promptTokens + completionTokens)
        )
        return (jsonResponse(jsonString(payload)),
                ChatRequestTrace(stream: isStreamFallback, promptTokens: promptTokens,
                                 completionTokens: completionTokens, error: nil,
                                 requestBody: truncateForLog(requestBody),
                                 responseBody: truncateForLog(jsonString(payload)),
                                 events: events, wasTruncated: wasTruncated))
    }

    // Normal response
    let assistantMsg = OpenAIMessage(role: "assistant", content: .text(rawContent),
                                      tool_calls: nil, tool_call_id: nil, name: nil)
    let payload = ChatCompletionResponse(
        id: id, object: "chat.completion", created: created, model: modelName,
        choices: [.init(index: 0, message: assistantMsg, finish_reason: "stop")],
        usage: .init(prompt_tokens: promptTokens, completion_tokens: completionTokens,
                     total_tokens: promptTokens + completionTokens)
    )
    return (jsonResponse(jsonString(payload)),
            ChatRequestTrace(stream: isStreamFallback, promptTokens: promptTokens,
                             completionTokens: completionTokens, error: nil,
                             requestBody: truncateForLog(requestBody),
                             responseBody: truncateForLog(jsonString(payload)),
                             events: events, wasTruncated: wasTruncated))
}
```

- [ ] **Step 8.5: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 8.6: Integration smoke test — single message**

```bash
# Build release binary first
swift build -c release
.build/release/apfel --serve --port 19999 &
sleep 2
curl -s -X POST http://127.0.0.1:19999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is 2+2?"}]}' | jq .
kill %1
```
Expected: JSON response with `choices[0].message.content` containing "4"

- [ ] **Step 8.7: Integration smoke test — tool call**

```bash
.build/release/apfel --serve --port 19999 &
sleep 2
curl -s -X POST http://127.0.0.1:19999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gpt-4",
    "messages":[{"role":"user","content":"What is the weather in Vienna?"}],
    "tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"location":{"type":"string"}}}}}]
  }' | jq '.choices[0].finish_reason, .choices[0].message.tool_calls'
kill %1
```
Expected: `"tool_calls"` and a tool call object with `name: "get_weather"`

- [ ] **Step 8.8: Integration smoke test — multi-turn history**

```bash
.build/release/apfel --serve --port 19999 &
sleep 2
curl -s -X POST http://127.0.0.1:19999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[
    {"role":"user","content":"My name is Franz."},
    {"role":"assistant","content":"Nice to meet you, Franz!"},
    {"role":"user","content":"What is my name?"}
  ]}' | jq '.choices[0].message.content'
kill %1
```
Expected: response containing "Franz"

- [ ] **Step 8.9: Commit**

```bash
git add Sources/Handlers.swift Sources/Handlers+Streaming.swift Sources/SSE.swift
git commit -m "feat: rewrite Handlers — fix history replay, add tool calling, wire GenerationOptions, real token counts"
```

---

## Phase 7 — CLI Polish (Perfect Unix Tool)

### Task 9: New CLI flags

**Files:**
- Modify: `Sources/main.swift`
- Modify: `Sources/CLI.swift`

- [ ] **Step 9.1: Add flags to main.swift**

New flags to parse:
```swift
// In main.swift argument parsing loop, add:
case "--temperature":
    i += 1
    guard i < args.count, let t = Double(args[i]), t >= 0, t <= 2 else {
        printError("--temperature requires a value between 0.0 and 2.0"); exit(exitUsageError)
    }
    cliTemperature = t

case "--max-tokens":
    i += 1
    guard i < args.count, let n = Int(args[i]), n > 0 else {
        printError("--max-tokens requires a positive integer"); exit(exitUsageError)
    }
    cliMaxTokens = n

case "--seed":
    i += 1
    guard i < args.count, let n = Int(args[i]) else {
        printError("--seed requires an integer"); exit(exitUsageError)
    }
    cliSeed = n

case "--permissive":
    cliPermissive = true

case "--tokens":
    cliShowTokens = true

case "--model-info":
    mode = "model-info"
```

Also read environment variables at startup:
```swift
// Read env vars (before arg parsing)
let envSystemPrompt = ProcessInfo.processInfo.environment["APFEL_SYSTEM_PROMPT"]
let envPort = ProcessInfo.processInfo.environment["APFEL_PORT"].flatMap(Int.init)
let envHost = ProcessInfo.processInfo.environment["APFEL_HOST"]
```

Global vars to add:
```swift
nonisolated(unsafe) var cliTemperature: Double? = nil
nonisolated(unsafe) var cliMaxTokens: Int? = nil
nonisolated(unsafe) var cliSeed: Int? = nil
nonisolated(unsafe) var cliPermissive: Bool = false
nonisolated(unsafe) var cliShowTokens: Bool = false
```

`--model-info` dispatch:
```swift
case "model-info":
    let size = await TokenCounter.shared.contextSize()
    print("model: \(modelName)")
    print("context_window: \(size) tokens")
    print("platform: Apple FoundationModels (on-device)")
    print("temperature: supported")
    print("max_tokens: supported")
    print("seed: supported")
    print("tools: supported (prompt injection)")
    print("streaming: supported")
    print("json_object: supported (prompt injection)")
```

- [ ] **Step 9.2: Wire CLI options into singlePrompt and chat**

In `CLI.swift`, update `singlePrompt` and `chat` to build `SessionOptions` from globals:

```swift
func cliSessionOptions(systemPrompt: String?) -> SessionOptions {
    SessionOptions(
        instructions: systemPrompt,
        temperature: cliTemperature,
        maxTokens: cliMaxTokens,
        seed: cliSeed,
        permissive: cliPermissive
    )
}
```

Show tokens on stderr after each response if `--tokens`:
```swift
if cliShowTokens {
    let tokens = await TokenCounter.shared.count(content)
    printStderr("  tokens: ~\(tokens) completion, budget: \(await TokenCounter.shared.contextSize())")
}
```

- [ ] **Step 9.3: Update --chat for context management**

Replace the plain `while true` loop with token-tracked loop:

```swift
func chat(systemPrompt: String?) async throws {
    var opts = cliSessionOptions(systemPrompt: systemPrompt)
    var session = makeSession(opts)
    var sessionTokensUsed = 0
    let contextSize = await TokenCounter.shared.contextSize()
    let warningThreshold = Int(Double(contextSize) * 0.7)

    // ... existing header printing ...

    while true {
        // Print prompt with optional token display
        if cliShowTokens {
            let pct = sessionTokensUsed * 100 / contextSize
            let label = sessionTokensUsed > warningThreshold
                ? styled("[\(sessionTokensUsed)/\(contextSize) ⚠]", .yellow)
                : "[\(sessionTokensUsed)/\(contextSize)]"
            print(styled("you", .green, .bold) + " \(label)› ", terminator: "")
        } else {
            print(styled("you› ", .green, .bold), terminator: "")
        }

        // ... read input ...

        do {
            let genOpts = makeGenerationOptions(opts)
            let content = try await collectStream(session, prompt: trimmed,
                                                   options: genOpts, printDelta: true)
            print("\n")
            sessionTokensUsed += await TokenCounter.shared.count(trimmed + content)

            // Session rotation at 70% to prevent overflow
            if sessionTokensUsed > warningThreshold {
                printStderr(styled("  [context at \(sessionTokensUsed)/\(contextSize) — summarizing…]", .yellow))
                let summary = try await summarizeSession(session: session, opts: opts)
                opts.instructions = summary
                session = makeSession(opts)
                sessionTokensUsed = await TokenCounter.shared.count(summary)
            }
        } catch {
            let apfelErr = ApfelError.classify(error)
            printStderr(styled("  \(apfelErr.cliLabel) \(apfelErr.openAIMessage)", .red))
        }
    }
}

/// Summarize the session transcript to carry forward as new instructions.
private func summarizeSession(session: LanguageModelSession, opts: SessionOptions) async throws -> String {
    let summaryOpts = SessionOptions(instructions: nil, permissive: opts.permissive)
    let summarySession = makeSession(summaryOpts)
    let transcript = session.transcript.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
    let result = try await summarySession.respond(
        to: "Summarize this conversation in 200 words, preserving all key facts and context:\n\(transcript)"
    )
    let base = opts.instructions.map { "\($0)\n\n## Conversation Summary\n" } ?? "## Conversation Summary\n"
    return base + result.content
}
```

- [ ] **Step 9.4: Update --help text**

Add new flags to the help output in `CLI.swift`.

- [ ] **Step 9.5: Test CLI flags manually**

```bash
swift build -c release
# Test temperature
.build/release/apfel --temperature 0.0 --seed 42 "What is 2+2?"
# Test permissive mode
.build/release/apfel --permissive "Summarize this text: violence occurred"
# Test tokens display
.build/release/apfel --tokens "What is the capital of Austria?"
# Test model info
.build/release/apfel --model-info
# Test env var
APFEL_SYSTEM_PROMPT="Reply in one word" .build/release/apfel "What is the capital of Austria?"
```

- [ ] **Step 9.6: Commit**

```bash
git add Sources/main.swift Sources/CLI.swift
git commit -m "feat: CLI — --temperature, --seed, --max-tokens, --permissive, --tokens, --model-info, env vars, context-aware chat"
```

---

## Phase 8 — Server Polish

### Task 10: Server completions + embeddings + CORS + enhanced endpoints

**Files:**
- Modify: `Sources/Server.swift`

- [ ] **Step 10.1: Add missing endpoints and improve existing ones**

```swift
// Add to router in startServer():

// Legacy: /v1/completions — 501 (not implemented, clear message)
router.post("/v1/completions") { _, _ -> Response in
    return openAIError(
        status: .notImplemented,
        message: "The legacy /v1/completions endpoint is not supported. Use /v1/chat/completions instead.",
        type: "not_supported_error"
    )
}

// Embeddings: /v1/embeddings — 501
router.post("/v1/embeddings") { _, _ -> Response in
    return openAIError(
        status: .notImplemented,
        message: "Embeddings are not supported by Apple FoundationModels. The on-device model is text generation only.",
        type: "not_supported_error"
    )
}

// OPTIONS preflight for CORS
router.on(.options, "/v1/chat/completions") { _, _ -> Response in
    var headers = HTTPFields()
    headers[.init("Access-Control-Allow-Origin")!] = "*"
    headers[.init("Access-Control-Allow-Methods")!] = "POST, GET, OPTIONS"
    headers[.init("Access-Control-Allow-Headers")!] = "Content-Type, Authorization, X-Apfel-Guardrails"
    return Response(status: .ok, headers: headers)
}
```

- [ ] **Step 10.2: Enhance /v1/models response**

```swift
// Replace existing /v1/models handler:
router.get("/v1/models") { _, _ -> Response in
    let model = ModelObject(
        id: modelName,
        object: "model",
        created: 1719792000,
        owned_by: "apple",
        context_window: 4096,
        supported_parameters: ["temperature", "max_tokens", "seed", "stream", "tools", "tool_choice", "response_format"],
        unsupported_parameters: ["logprobs", "n", "stop", "presence_penalty", "frequency_penalty"],
        notes: "Apple on-device FoundationModels (~3B parameters). Context window: 4096 tokens fixed. Tool calling via prompt injection."
    )
    return jsonResponse(jsonString(ModelsListResponse(object: "list", data: [model])))
}
```

Update `ModelsListResponse.ModelObject` in Models.swift to include these fields.

- [ ] **Step 10.3: Enhance /health endpoint**

```swift
router.get("/health") { _, _ -> Response in
    let active = await serverState.logStore.activeRequests
    let contextSize = await TokenCounter.shared.contextSize()
    let body = """
    {
      "status": "ok",
      "model": "\(modelName)",
      "version": "\(version)",
      "active_requests": \(active),
      "context_window_tokens": \(contextSize),
      "platform": "Apple FoundationModels",
      "apple_silicon_required": true
    }
    """
    return jsonResponse(body)
}
```

- [ ] **Step 10.4: Add Retry-After header on rate limit responses**

In `Handlers.swift` error path, when `ApfelError.rateLimited`:
```swift
// In openAIError helper or inline:
if apfelErr == .rateLimited {
    headers[.init("Retry-After")!] = "5"
}
```

- [ ] **Step 10.5: Integration test — all endpoints**

```bash
swift build -c release
.build/release/apfel --serve --port 19999 &
sleep 2

# Models
curl -s http://127.0.0.1:19999/v1/models | jq '.data[0].context_window'
# Expected: 4096

# Health
curl -s http://127.0.0.1:19999/health | jq '.context_window_tokens'
# Expected: 4096

# Legacy completions → 501
curl -s -X POST http://127.0.0.1:19999/v1/completions \
  -H "Content-Type: application/json" -d '{}' | jq '.error.type'
# Expected: "not_supported_error"

# Embeddings → 501
curl -s -X POST http://127.0.0.1:19999/v1/embeddings \
  -H "Content-Type: application/json" -d '{}' | jq '.error.type'
# Expected: "not_supported_error"

# Image content → 400
curl -s -X POST http://127.0.0.1:19999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"http://x.com/img.png"}}]}]}' | jq '.error.type'
# Expected: "invalid_request_error"

kill %1
```

- [ ] **Step 10.6: Commit**

```bash
git add Sources/Server.swift Sources/Models.swift
git commit -m "feat: server — /v1/completions 501, /v1/embeddings 501, CORS preflight, enhanced /health and /v1/models"
```

---

## Phase 9 — End-to-End Validation

### Task 11: Full OpenAI client compatibility test

**Files:**
- Create: `Tests/integration/openai_client_test.py` (manual, not automated)

This documents how to validate with a real OpenAI client library.

- [ ] **Step 11.1: Build release binary**

```bash
swift build -c release
cp .build/release/apfel /usr/local/bin/apfel
apfel --version
```

- [ ] **Step 11.2: Test with Python openai library**

```python
# Tests/integration/openai_client_test.py
# Run: python3 Tests/integration/openai_client_test.py
# Requires: pip install openai

from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11434/v1", api_key="unused")

# --- Test 1: Basic completion ---
r = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "What is 2+2? Answer in one word."}]
)
assert r.usage.prompt_tokens > 0, "Real token counts expected"
assert r.usage.completion_tokens > 0
assert r.choices[0].finish_reason == "stop"
print("✅ Test 1 passed: basic completion with real token counts")

# --- Test 2: Streaming ---
stream = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "Count to 3."}],
    stream=True
)
chunks = list(stream)
assert any(c.choices[0].delta.content for c in chunks if c.choices[0].delta.content)
print("✅ Test 2 passed: streaming")

# --- Test 3: Multi-turn history ---
r = client.chat.completions.create(
    model="gpt-4",
    messages=[
        {"role": "user", "content": "My favourite number is 42."},
        {"role": "assistant", "content": "Great choice!"},
        {"role": "user", "content": "What is my favourite number?"}
    ]
)
assert "42" in r.choices[0].message.content
print("✅ Test 3 passed: multi-turn history preserved")

# --- Test 4: Tool calling ---
r = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "What is the weather in Vienna?"}],
    tools=[{"type": "function", "function": {
        "name": "get_weather",
        "description": "Get current weather",
        "parameters": {"type": "object", "properties": {"location": {"type": "string"}}}
    }}]
)
assert r.choices[0].finish_reason == "tool_calls"
call = r.choices[0].message.tool_calls[0]
assert call.function.name == "get_weather"
import json
args = json.loads(call.function.arguments)
assert "vienna" in args.get("location", "").lower()
print("✅ Test 4 passed: tool calling")

# --- Test 5: Tool result continuation ---
r2 = client.chat.completions.create(
    model="gpt-4",
    messages=[
        {"role": "user", "content": "What is the weather in Vienna?"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": call.id, "type": "function", "function": {"name": "get_weather", "arguments": call.function.arguments}}
        ]},
        {"role": "tool", "tool_call_id": call.id, "content": "Sunny, 22°C"}
    ]
)
assert r2.choices[0].finish_reason == "stop"
assert "22" in r2.choices[0].message.content or "sunny" in r2.choices[0].message.content.lower()
print("✅ Test 5 passed: tool result continuation")

# --- Test 6: temperature + seed ---
r1 = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "Give me a random number between 1 and 100."}],
    temperature=0.0, seed=42
)
r2 = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "Give me a random number between 1 and 100."}],
    temperature=0.0, seed=42
)
assert r1.choices[0].message.content == r2.choices[0].message.content
print("✅ Test 6 passed: deterministic output with temperature=0 + seed")

print("\n🎉 All tests passed — apfel is OpenAI API compatible")
```

Run:
```bash
apfel --serve &
sleep 2
python3 Tests/integration/openai_client_test.py
kill %1
```

- [ ] **Step 11.3: Test CLI as Unix tool**

```bash
# Pipe test
echo "What is 2+2?" | apfel

# Scripting test
result=$(apfel -q "Capital of France? One word.")
echo "Got: $result"

# JSON output + jq
apfel -o json "What is the speed of light?" | jq .content

# Quiet + json pipe chain
apfel -q -o json --temperature 0 "List 3 fruits" | jq .content

# Permissive mode
apfel --permissive -s "You are a content summarizer" "Summarize: violence broke out"

# Model info
apfel --model-info

# Token display in single prompt
apfel --tokens "Explain quantum entanglement in one sentence"

# Chat with token display
# (manual: run apfel --chat --tokens, have 10+ turns, verify it doesn't crash)
apfel --chat --tokens
```

- [ ] **Step 11.4: Commit**

```bash
git add Tests/integration/openai_client_test.py
git commit -m "test: integration test suite for OpenAI API compatibility and Unix tool features"
```

---

## Phase 10 — Version Bump + Release

### Task 12: Update version, README, and release

**Files:**
- Modify: `Sources/main.swift` (version bump)
- Modify: `README.md`

- [ ] **Step 12.1: Bump version to 0.4.0**

In `Sources/main.swift`:
```swift
let version = "0.4.0"
```

- [ ] **Step 12.2: Update README capabilities table**

Add a "Compatibility" section to README.md:
```markdown
## OpenAI API Compatibility

| Feature | Status | Notes |
|---|---|---|
| `POST /v1/chat/completions` | ✅ Full | Streaming + non-streaming |
| Multi-turn history | ✅ | History packed into session instructions |
| `temperature` | ✅ | Wired to Apple SamplingMode |
| `max_tokens` | ✅ | Wired to GenerationOptions |
| `seed` | ✅ | Deterministic output |
| `tools` + `tool_choice` | ✅ | Via system-prompt injection |
| `role: "tool"` messages | ✅ | Tool results included in context |
| `finish_reason: "tool_calls"` | ✅ | |
| `response_format: json_object` | ✅ | Via prompt injection |
| Real `usage` token counts | ✅ | Apple `tokenCount(for:)` API |
| Content array messages | ✅ Text only | Images rejected with clear error |
| `GET /v1/models` | ✅ | With capabilities metadata |
| `GET /health` | ✅ | With context window info |
| `POST /v1/completions` | ❌ 501 | Legacy endpoint not supported |
| `POST /v1/embeddings` | ❌ 501 | Not available in Apple FM |
| `logprobs` | Ignored | Not available |
| `n > 1` | Clamped to 1 | Model generates one response |
| `stop` sequences | Ignored | Not available |
| Image content | ❌ 400 | Text only model |
```

Also add new CLI flags to README.

- [ ] **Step 12.3: Final build + install**

```bash
swift build -c release
make install
apfel --version  # should print: apfel v0.4.0
apfel --model-info
```

- [ ] **Step 12.4: Final commit + tag**

```bash
git add Sources/main.swift README.md
git commit -m "release: v0.4.0 — OpenAI API compatibility + perfect Unix tool"
git tag v0.4.0
```

---

## Tool Calling Architecture Note (for implementors)

### Why not Apple's native `Tool` protocol?

Apple's `Tool` protocol requires **compile-time Swift type definitions**:
```swift
// Apple's approach (compile-time, auto-executing):
@Tool struct WeatherTool {
    static let name = "get_weather"
    @Argument var location: String
    func call() async throws -> ToolOutput { /* executes HERE */ }
}
let session = LanguageModelSession(tools: [WeatherTool()])
// Framework runs tool call loop internally — client never sees the intermediate step
```

OpenAI's protocol requires **runtime JSON schema + client-side execution**:
```
Client → sends tools as JSON schemas
Model → responds "call get_weather({location: 'Vienna'})"
Client → executes the function themselves
Client → sends result back to model
Model → generates final response
```

These are architecturally incompatible. Apple's framework executes the tool; OpenAI's framework exposes the call to the client. We cannot intercept Apple's auto-execution to return the tool call to an OpenAI client.

**Our solution: System-prompt injection**

We inject tool definitions as JSON into the system instructions with explicit calling instructions. The Apple model generates a JSON response when it wants to call a function. We detect this JSON, format it as an OpenAI `tool_calls` response, and return it to the client. When the client returns a `role: "tool"` message, we include it in the context history.

This works because:
- Apple's 3B model CAN follow structured JSON instructions
- The new 26.4 model update specifically improves instruction following
- Detection is robust (handles code blocks, preamble text, etc.)

Reliability caveat: The on-device model doesn't always follow the JSON format perfectly. If tool call detection fails, the raw response text is returned as `finish_reason: "stop"`. Clients should handle this gracefully.

---

## Quick Reference: What Breaks Without This Plan

| Without Fix | Symptom | How This Plan Fixes It |
|---|---|---|
| `Handlers.swift:127` broken replay | Multi-turn history corrupted | ContextManager: history-as-instructions |
| Char/4 token counting | Wrong `usage` field, no overflow protection | `TokenCounter` with Apple API |
| No context overflow in `--chat` | Crash after ~5-6 turns | Session rotation at 70% |
| No tool calling | Incompatible with Claude Code, many clients | ToolCallHandler: prompt injection + JSON detection |
| No GenerationOptions | Temperature/seed/max_tokens silently ignored | `makeGenerationOptions` wired to model |
| Generic error messages | Can't debug guardrail vs overflow vs rate limit | `ApfelError` with typed labels |
| No `role: "tool"` support | Tool result loop broken | ContextManager formats tool messages |
| No image rejection | Silent failure or crash on multi-modal | Explicit 400 with clear message |
