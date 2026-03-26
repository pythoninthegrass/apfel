import Foundation
import ApfelCore

func runToolCallHandlerTests() {

    // MARK: - Detection

    test("detects clean JSON tool call") {
        let response = #"{"tool_calls": [{"id": "call_abc", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\":\"Vienna\"}"}}]}"#
        let result = ToolCallHandler.detectToolCall(in: response)
        try assertNotNil(result)
        try assertEqual(result!.first?.name, "get_weather")
        try assertEqual(result!.first?.id, "call_abc")
    }
    test("detects tool call inside markdown code block") {
        let response = "```json\n{\"tool_calls\": [{\"id\": \"c1\", \"type\": \"function\", \"function\": {\"name\": \"search\", \"arguments\": \"{}\"}}]}\n```"
        let result = ToolCallHandler.detectToolCall(in: response)
        try assertNotNil(result)
        try assertEqual(result!.first?.name, "search")
    }
    test("detects tool call after preamble text") {
        let response = "Let me look that up.\n{\"tool_calls\": [{\"id\": \"c2\", \"type\": \"function\", \"function\": {\"name\": \"calc\", \"arguments\": \"{}\"}}]}"
        let result = ToolCallHandler.detectToolCall(in: response)
        try assertNotNil(result)
        try assertEqual(result!.first?.name, "calc")
    }
    test("returns nil for plain text response") {
        let response = "Vienna is the capital of Austria."
        try assertNil(ToolCallHandler.detectToolCall(in: response))
    }
    test("returns nil for partial/malformed JSON") {
        try assertNil(ToolCallHandler.detectToolCall(in: "{tool_calls: broken}"))
        try assertNil(ToolCallHandler.detectToolCall(in: "{}"))
        try assertNil(ToolCallHandler.detectToolCall(in: "{\"tool_calls\": []}"))
    }
    test("parses arguments JSON string correctly") {
        let response = #"{"tool_calls": [{"id": "c3", "type": "function", "function": {"name": "fn", "arguments": "{\"key\":\"val\"}"}}]}"#
        let result = ToolCallHandler.detectToolCall(in: response)
        try assertNotNil(result)
        try assertEqual(result!.first?.argumentsString, "{\"key\":\"val\"}")
    }
    test("detects multiple tool calls") {
        let response = #"{"tool_calls": [{"id": "c1", "type": "function", "function": {"name": "fn1", "arguments": "{}"}}, {"id": "c2", "type": "function", "function": {"name": "fn2", "arguments": "{}"}}]}"#
        let result = ToolCallHandler.detectToolCall(in: response)
        try assertNotNil(result)
        try assertEqual(result!.count, 2)
    }

    // MARK: - System prompt building

    test("buildSystemPrompt contains function names") {
        let tools = [
            ToolDef(name: "get_weather", description: "Get weather", parametersJSON: #"{"type":"object"}"#),
            ToolDef(name: "search_web", description: "Search the web", parametersJSON: nil),
        ]
        let prompt = ToolCallHandler.buildSystemPrompt(tools: tools)
        try assertTrue(prompt.contains("get_weather"), "missing get_weather")
        try assertTrue(prompt.contains("search_web"), "missing search_web")
        try assertTrue(prompt.contains("tool_calls"), "missing tool_calls keyword")
        try assertTrue(prompt.contains("JSON"), "missing JSON instruction")
    }
    test("buildSystemPrompt with description") {
        let tools = [ToolDef(name: "fn", description: "Does a thing", parametersJSON: nil)]
        let prompt = ToolCallHandler.buildSystemPrompt(tools: tools)
        try assertTrue(prompt.contains("Does a thing"))
    }
    test("buildSystemPrompt without description still works") {
        let tools = [ToolDef(name: "fn", description: nil, parametersJSON: nil)]
        let prompt = ToolCallHandler.buildSystemPrompt(tools: tools)
        try assertTrue(prompt.contains("fn"))
    }

    // MARK: - Edge cases (bug fixes)

    test("handles trailing backticks without crash") {
        try assertNil(ToolCallHandler.detectToolCall(in: "```"))
    }
    test("handles empty code block without crash") {
        try assertNil(ToolCallHandler.detectToolCall(in: "``````"))
    }

    // MARK: - JSON escaping in buildSystemPrompt

    test("buildSystemPrompt escapes special characters in descriptions") {
        let tools = [ToolDef(name: "fn", description: #"Get the "current" weather\today"#, parametersJSON: nil)]
        let prompt = ToolCallHandler.buildSystemPrompt(tools: tools)
        try assertTrue(prompt.contains("current"), "missing description content")
        // Find the JSON array in the output and validate it parses
        if let startRange = prompt.range(of: "\n["),
           let _ = prompt.range(of: "\n]", range: startRange.upperBound..<prompt.endIndex) {
            let jsonSlice = String(prompt[startRange.upperBound...]) // includes [ to end
            let arrayEnd = jsonSlice.range(of: "\n]")!
            let jsonStr = "[" + String(jsonSlice[..<arrayEnd.upperBound])
            let data = jsonStr.data(using: .utf8)!
            let parsed = try? JSONSerialization.jsonObject(with: data)
            if parsed == nil {
                throw TestFailure("Generated JSON is not valid — special characters broke escaping")
            }
        }
    }

    // MARK: - Tool result formatting

    test("formatToolResult contains name and content") {
        let result = ToolCallHandler.formatToolResult(callId: "c1", name: "get_weather", content: "Sunny, 22°C")
        try assertTrue(result.contains("get_weather"), "missing name")
        try assertTrue(result.contains("Sunny, 22°C"), "missing content")
    }
    test("formatToolResult contains call ID") {
        let result = ToolCallHandler.formatToolResult(callId: "call_xyz", name: "fn", content: "ok")
        try assertTrue(result.contains("call_xyz"))
    }
}
