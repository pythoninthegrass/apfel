// ============================================================================
// Session.swift — FoundationModels session management and streaming
// Part of apfel — Apple Intelligence from the command line
// SHARED by both CLI and server modes.
// ============================================================================

import FoundationModels
import Foundation
import ApfelCore

// MARK: - Session Options

/// Options forwarded from CLI flags or OpenAI request parameters.
struct SessionOptions: Sendable {
    let temperature: Double?
    let maxTokens: Int?
    let seed: UInt64?
    let permissive: Bool
    let contextConfig: ContextConfig

    static let defaults = SessionOptions(
        temperature: nil, maxTokens: nil, seed: nil, permissive: false,
        contextConfig: .defaults
    )
}

// MARK: - Generation Options

func makeGenerationOptions(_ opts: SessionOptions) -> GenerationOptions {
    let sampling: GenerationOptions.SamplingMode? = opts.seed.map {
        .random(top: 50, seed: $0)
    }
    return GenerationOptions(
        sampling: sampling,
        temperature: opts.temperature,
        maximumResponseTokens: opts.maxTokens
    )
}

// MARK: - Model Selection

func makeModel(permissive: Bool) -> SystemLanguageModel {
    SystemLanguageModel(
        guardrails: permissive ? .permissiveContentTransformations : .default
    )
}

// MARK: - Simple Session (CLI use)

/// Create a LanguageModelSession with optional system instructions for CLI use.
/// Uses Transcript.Instructions so streaming and non-streaming read the same source.
func makeSession(systemPrompt: String?, options: SessionOptions = .defaults) -> LanguageModelSession {
    let model = makeModel(permissive: options.permissive)
    guard let systemPrompt, !systemPrompt.isEmpty else {
        return LanguageModelSession(model: model)
    }
    let segment = Transcript.TextSegment(content: systemPrompt)
    let instructions = Transcript.Instructions(segments: [.text(segment)], toolDefinitions: [])
    return makeTranscriptSession(model: model, entries: [.instructions(instructions)])
}

func makePromptEntry(_ prompt: String, options: SessionOptions = .defaults) -> Transcript.Entry {
    let segment = Transcript.TextSegment(content: prompt)
    let prompt = Transcript.Prompt(
        segments: [.text(segment)],
        options: makeGenerationOptions(options)
    )
    return .prompt(prompt)
}

func makeTranscriptSession(model: SystemLanguageModel, entries: [Transcript.Entry]) -> LanguageModelSession {
    guard !entries.isEmpty else {
        return LanguageModelSession(model: model)
    }
    return LanguageModelSession(model: model, transcript: Transcript(entries: entries))
}

func transcriptEntries(_ transcript: Transcript) -> [Transcript.Entry] {
    Array(transcript)
}

func sessionInputEntries(
    _ session: LanguageModelSession,
    finalPrompt: String,
    options: SessionOptions = .defaults
) -> [Transcript.Entry] {
    var entries = transcriptEntries(session.transcript)
    entries.append(makePromptEntry(finalPrompt, options: options))
    return entries
}

func assembleTranscriptEntries<BaseEntries: Collection, HistoryEntries: Collection>(
    base: BaseEntries,
    history: HistoryEntries,
    final: Transcript.Entry? = nil
) -> [Transcript.Entry]
where BaseEntries.Element == Transcript.Entry, HistoryEntries.Element == Transcript.Entry {
    var entries: [Transcript.Entry] = []
    entries.reserveCapacity(base.count + history.count + (final == nil ? 0 : 1))
    entries.append(contentsOf: base)
    entries.append(contentsOf: history)
    if let final {
        entries.append(final)
    }
    return entries
}

func fitsTranscriptBudget(
    _ entries: [Transcript.Entry],
    budget: Int
) async -> Bool {
    await TokenCounter.shared.count(entries: entries) <= budget
}

func fitsTranscriptBudget(
    base: [Transcript.Entry],
    history: [Transcript.Entry],
    final: Transcript.Entry? = nil,
    budget: Int
) async -> Bool {
    await fitsTranscriptBudget(
        assembleTranscriptEntries(base: base, history: history, final: final),
        budget: budget
    )
}

func fitsTranscriptBudget<BaseEntries: Collection, HistoryEntries: Collection>(
    base: BaseEntries,
    history: HistoryEntries,
    final: Transcript.Entry? = nil,
    budget: Int
) async -> Bool
where BaseEntries.Element == Transcript.Entry, HistoryEntries.Element == Transcript.Entry {
    await fitsTranscriptBudget(
        assembleTranscriptEntries(base: base, history: history, final: final),
        budget: budget
    )
}

func trimHistoryEntriesToBudget(
    baseEntries: [Transcript.Entry],
    historyEntries: [Transcript.Entry],
    finalEntry: Transcript.Entry? = nil,
    budget: Int,
    config: ContextConfig = .defaults
) async -> [Transcript.Entry]? {
    let requiredEntries = assembleTranscriptEntries(base: baseEntries, history: [], final: finalEntry)
    guard await fitsTranscriptBudget(requiredEntries, budget: budget) else {
        return nil
    }

    switch config.strategy {
    case .newestFirst:
        return await trimNewestFirst(
            base: baseEntries, history: historyEntries, final: finalEntry, budget: budget)
    case .oldestFirst:
        return await trimOldestFirst(
            base: baseEntries, history: historyEntries, final: finalEntry, budget: budget)
    case .slidingWindow:
        return await trimSlidingWindow(
            base: baseEntries, history: historyEntries, final: finalEntry,
            budget: budget, maxTurns: config.maxTurns)
    case .summarize:
        return await trimWithSummary(
            base: baseEntries, history: historyEntries, final: finalEntry, budget: budget)
    case .strict:
        // No trimming — return all history or nil if it exceeds budget
        let all = assembleTranscriptEntries(base: baseEntries, history: historyEntries, final: finalEntry)
        return await fitsTranscriptBudget(all, budget: budget)
            ? all
            : nil
    }
}

// MARK: - Strategy: Newest First (default)

func trimNewestFirst(
    base: [Transcript.Entry], history: [Transcript.Entry],
    final: Transcript.Entry?, budget: Int
) async -> [Transcript.Entry] {
    let keepCount = await maxNewestHistoryCountThatFits(
        base: base,
        history: history,
        final: final,
        budget: budget
    )
    return assembleTranscriptEntries(base: base, history: history.suffix(keepCount))
}

// MARK: - Strategy: Oldest First

func trimOldestFirst(
    base: [Transcript.Entry], history: [Transcript.Entry],
    final: Transcript.Entry?, budget: Int
) async -> [Transcript.Entry] {
    let keepCount = await maxOldestHistoryCountThatFits(
        base: base,
        history: history,
        final: final,
        budget: budget
    )
    return assembleTranscriptEntries(base: base, history: history.prefix(keepCount))
}

// MARK: - Strategy: Sliding Window

func trimSlidingWindow(
    base: [Transcript.Entry], history: [Transcript.Entry],
    final: Transcript.Entry?, budget: Int, maxTurns: Int?
) async -> [Transcript.Entry] {
    let windowSize = min(maxTurns ?? Int.max, history.count)
    let windowed = Array(history.suffix(windowSize))
    // Apply token-budget safety net (drop from front if over budget)
    return await trimNewestFirst(
        base: base, history: windowed, final: final, budget: budget)
}

// MARK: - MCP Tool Execution (shared by CLI and server)

/// Execute MCP tool calls found in model output and re-prompt for a plain text answer.
/// Returns nil if no tool calls were detected or mcpManager is nil.
/// Both CLI and server call this to avoid duplicating the detect-execute-reprompt loop.
func executeMCPToolCalls(
    in content: String,
    mcpManager: MCPManager?,
    userPrompt: String,
    systemPrompt: String? = nil,
    messages: [OpenAIMessage]? = nil,
    sessionOptions: SessionOptions? = nil,
    options: GenerationOptions
) async throws -> (content: String, toolLog: [(name: String, args: String, result: String, isError: Bool)])? {
    guard let mcpManager,
          let toolCalls = ToolCallHandler.detectToolCall(in: content) else {
        return nil
    }

    var resultParts: [String] = []
    var toolLog: [(name: String, args: String, result: String, isError: Bool)] = []
    for call in toolCalls {
        do {
            let result = try await mcpManager.execute(name: call.name, arguments: call.argumentsString)
            resultParts.append("\(call.name): \(result)")
            toolLog.append((name: call.name, args: call.argumentsString, result: result, isError: false))
        } catch {
            if case .toolNotFound = error as? MCPError {
                // Model hallucinated a tool name that no MCP server provides.
                // Include the error as a result so the model can still respond.
                let msg = "\(error)"
                resultParts.append("\(call.name): error - \(msg)")
                toolLog.append((name: call.name, args: call.argumentsString, result: msg, isError: true))
            } else {
                throw error  // Timeouts, server errors, process errors are fatal.
            }
        }
    }

    let finalContent: String
    if let messages, let sessionOptions {
        let followUpMessages = appendExecutedToolResults(
            to: messages,
            toolCalls: toolCalls,
            toolResults: toolLog.map { ($0.name, $0.result) }
        )
        let (followUpSession, followUpPrompt) = try await ContextManager.makeSession(
            messages: followUpMessages,
            tools: nil,
            options: sessionOptions,
            jsonMode: false,
            toolChoice: nil
        )
        finalContent = try await followUpSession.respond(to: followUpPrompt, options: options).content
    } else {
        // CLI fallback: no prior transcript, so use a plain follow-up prompt.
        let plainSession = makeSession(systemPrompt: systemPrompt)
        let toolResult = resultParts.joined(separator: "\n")
        finalContent = try await plainSession.respond(
            to: "The user asked: \(userPrompt)\n\nThe tool returned: \(toolResult)\n\nAnswer the user's question using this result.",
            options: options
        ).content
    }
    return (content: finalContent, toolLog: toolLog)
}

private func appendExecutedToolResults(
    to messages: [OpenAIMessage],
    toolCalls: [ParsedToolCall],
    toolResults: [(name: String, result: String)]
) -> [OpenAIMessage] {
    let assistantToolCalls = toolCalls.map { call in
        ToolCall(
            id: call.id,
            type: "function",
            function: ToolCallFunction(name: call.name, arguments: call.argumentsString)
        )
    }

    var followUpMessages = messages
    followUpMessages.append(OpenAIMessage(role: "assistant", content: nil, tool_calls: assistantToolCalls))
    for (call, result) in zip(toolCalls, toolResults) {
        followUpMessages.append(
            OpenAIMessage(
                role: "tool",
                content: .text(result.result),
                tool_call_id: call.id,
                name: result.name
            )
        )
    }
    return followUpMessages
}

// MARK: - Streaming Helper

/// Stream a response, optionally printing deltas to stdout.
/// FoundationModels returns cumulative snapshots; we compute deltas by tracking prev length.
/// - Returns: The complete response text after all chunks have been received.
func collectStream(
    _ session: LanguageModelSession,
    prompt: String,
    printDelta: Bool,
    options: GenerationOptions = GenerationOptions()
) async throws -> String {
    let stream = session.streamResponse(to: prompt, options: options)
    var prev = ""
    for try await snapshot in stream {
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

func maxNewestHistoryCountThatFits(
    base: [Transcript.Entry],
    history: [Transcript.Entry],
    final: Transcript.Entry?,
    budget: Int
) async -> Int {
    guard !history.isEmpty else { return 0 }

    var low = 0
    var high = history.count
    while low < high {
        let mid = (low + high + 1) / 2
        let candidate = history.suffix(mid)
        if await fitsTranscriptBudget(base: base, history: candidate, final: final, budget: budget) {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return low
}

private func maxOldestHistoryCountThatFits(
    base: [Transcript.Entry],
    history: [Transcript.Entry],
    final: Transcript.Entry?,
    budget: Int
) async -> Int {
    guard !history.isEmpty else { return 0 }

    var low = 0
    var high = history.count
    while low < high {
        let mid = (low + high + 1) / 2
        let candidate = history.prefix(mid)
        if await fitsTranscriptBudget(base: base, history: candidate, final: final, budget: budget) {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return low
}
