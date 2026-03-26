import Foundation

/// A tool definition for system-prompt injection (no FoundationModels dependency).
public struct ToolDef: Sendable {
    public let name: String
    public let description: String?
    public let parametersJSON: String?

    public init(name: String, description: String?, parametersJSON: String?) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// A parsed tool call extracted from model output.
public struct ParsedToolCall: Sendable {
    public let id: String
    public let name: String
    public let argumentsString: String
}

public enum ToolCallHandler {

    // MARK: - System Prompt Building

    /// Build the tool-calling instruction block to inject into session instructions.
    /// Uses JSONSerialization for proper escaping of tool names/descriptions.
    public static func buildSystemPrompt(tools: [ToolDef]) -> String {
        var schemaObjects: [[String: Any]] = []
        for tool in tools {
            var obj: [String: Any] = ["name": tool.name]
            if let desc = tool.description { obj["description"] = desc }
            if let params = tool.parametersJSON,
               let data = params.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                obj["parameters"] = parsed
            }
            schemaObjects.append(obj)
        }
        let schemasJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: schemaObjects, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            schemasJSON = str
        } else {
            schemasJSON = "[]"
        }

        return """
        ## Available Functions
        When you need to call a function, respond ONLY with this exact JSON (no other text before or after):
        {"tool_calls": [{"id": "call_<unique>", "type": "function", "function": {"name": "<name>", "arguments": "<escaped_json_string>"}}]}

        Replace <unique> with a short unique string, <name> with the function name, and <escaped_json_string> with the arguments as a JSON-encoded string.

        Available functions:
        \(schemasJSON)
        """
    }

    // MARK: - Tool Call Detection

    /// Detect and parse tool calls from model output.
    /// Handles: clean JSON, JSON in markdown code blocks, JSON after preamble text.
    /// Returns nil if the response is a normal text reply.
    public static func detectToolCall(in response: String) -> [ParsedToolCall]? {
        for candidate in extractCandidates(from: response) {
            if let calls = parseToolCallJSON(candidate), !calls.isEmpty {
                return calls
            }
        }
        return nil
    }

    // MARK: - Tool Result Formatting

    /// Format a tool result for injection into conversation history.
    public static func formatToolResult(callId: String, name: String, content: String) -> String {
        "[Function result for \(name) (id: \(callId))]: \(content)"
    }

    // MARK: - Private Helpers

    private static func extractCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Whole response as-is
        candidates.append(trimmed)

        // 2. Strip markdown code blocks ```json ... ``` or ``` ... ```
        var remaining = text
        while let start = remaining.range(of: "```"),
              let nextIdx = remaining.index(start.upperBound, offsetBy: 1, limitedBy: remaining.endIndex),
              let end = remaining.range(of: "```", range: nextIdx..<remaining.endIndex) {
            let block = String(remaining[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip optional "json" language tag
            let stripped = block.hasPrefix("json\n") ? String(block.dropFirst(5)) : block
            candidates.append(stripped)
            remaining = String(remaining[end.upperBound...])
        }

        // 3. Find JSON object starting at {"tool_calls"
        if let range = text.range(of: "{\"tool_calls\"") {
            candidates.append(String(text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return candidates
    }

    private static func parseToolCallJSON(_ json: String) -> [ParsedToolCall]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCalls = obj["tool_calls"] as? [[String: Any]],
              !rawCalls.isEmpty else { return nil }

        var result: [ParsedToolCall] = []
        for call in rawCalls {
            guard let id = call["id"] as? String,
                  let fn = call["function"] as? [String: Any],
                  let name = fn["name"] as? String else { continue }
            let args: String
            if let s = fn["arguments"] as? String {
                args = s
            } else if let obj = fn["arguments"],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let s = String(data: data, encoding: .utf8) {
                args = s
            } else {
                args = "{}"
            }
            result.append(ParsedToolCall(id: id, name: name, argumentsString: args))
        }
        return result.isEmpty ? nil : result
    }
}
