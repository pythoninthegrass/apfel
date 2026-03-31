# Apfel × Apple FoundationModels: Compliance Audit & Fix Guide

**Project:** [Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel)  
**Date:** March 26, 2026 (Updated)  
**Scope:** Full analysis against Apple's FoundationModels framework specifications, limits, and acceptable use requirements — now including March 2026 Apple drops

---

## Executive Summary

Apfel is a Swift CLI/GUI/server wrapper around Apple's on-device FoundationModels framework. It provides three interfaces (CLI, OpenAI-compatible HTTP server, native macOS debug GUI) to Apple's ~3B-parameter on-device language model.

**The project will break in at least 6 critical areas** due to Apple's tight constraints. Below is the full analysis with fixes.

---

## 1. Context Window — The #1 Breakpoint

### The Hard Limit

Apple's on-device model has a **fixed 4,096 token context window** (input + output combined). This is confirmed by Apple's own developer forums and TN3193 tech note. There is no possibility of this changing at runtime. Apple's rule of thumb: **3–4 characters per token** for English.

That means roughly **~3,000 words total** across system prompt + all user messages + all model responses in a session.

### Where Apfel Breaks

**Interactive chat mode (`apfel --chat`)** — This is the most dangerous mode. Every turn of conversation (user prompt + model response) accumulates in the session transcript. After approximately 4–6 back-and-forth exchanges, the session will throw `GenerationError.exceededContextWindowSize` and **crash**.

Evidence from the EXAMPLES.md confirms this: the ASCII art request returned `Exceeded model context window size` — that's this exact error.

**OpenAI server mode (`apfel --serve`)** — When clients send multi-turn conversations via `/v1/chat/completions`, the entire `messages[]` array gets passed to the model. Any client sending a long conversation history will blow the limit immediately. OpenAI's API typically supports 128K tokens; clients will expect this and send far more data than Apple's model can handle.

**System prompts eat into the budget** — Apfel supports `-s` system prompts. A verbose system prompt (e.g., 500 tokens) leaves only ~3,500 tokens for the entire conversation. The project doesn't appear to track or warn about this.

**Tool definitions consume tokens** — When tools are registered with the model, their name, description, and argument schema are serialized and sent alongside instructions. This is a hidden source of token bloat that the project doesn't account for.

### Fixes

1. **Token budget tracking**: Use iOS 26.4's `contextSize` property and `tokenCount(for:)` method to measure consumption in real-time. Set a warning threshold at 70–80% capacity.

2. **Sliding window in chat mode**: Implement transcript pruning — when approaching the limit, create a new `LanguageModelSession` carrying only the system prompt + the last 2–3 exchanges. This is exactly what Apple's WWDC25 "Deep Dive" session recommends.

3. **Opportunistic summarization**: At 70% capacity, use a separate session to summarize the conversation so far into a compact context, then start a fresh session with that summary as the system prompt.

4. **OpenAI server: truncate incoming messages**: Before forwarding to the model, estimate the token count of the full `messages[]` array. If it exceeds ~3,500 tokens (leaving room for response), truncate older messages or return an error with a clear explanation.

5. **Report context budget in the GUI debug inspector**: Show a token usage bar — current usage / 4096 — so developers can see consumption in real-time.

6. **Cap response length**: Use `GenerationOptions` to set a maximum output token count, reserving 25–50% of the context window for the response.

---

## 2. Safety Guardrails — The False Positive Problem

### Apple's Architecture

Apple's safety system operates at two layers:
- **Layer 1 (Model training)**: The model is trained to be cautious with sensitive topics
- **Layer 2 (Guardrail enforcement)**: A separate system scans input and output, throwing `guardrailViolation` errors

### Where Apfel Breaks

The EXAMPLES.md reveals the problem clearly. The guardrails blocked:
- Describing the color blue to someone who hasn't seen it
- Writing an alphabetical poem
- Explaining the German word "Schadenfreude"
- Choosing between vim and emacs
- Answering the trolley problem with a single letter

These are all **false positives** — completely benign prompts. Apple has acknowledged this problem on developer forums, with an engineer stating they're "actively working to improve the guardrails and reduce false positives."

The project's current behavior when hitting guardrails is to show `[ERROR or REFUSED]`, which is a poor user experience.

### Apfel's "Safety/refusal-aware history pruning" — A Smart Feature

The GUI already excludes safety-blocked turns from future history. This is correct behavior — one blocked response can "poison" subsequent requests if it remains in the transcript.

### Fixes

1. **Use `.permissiveContentTransform`**: For content summarization and transformation tasks (not generation), Apple provides a `Guardrails` option that reduces false positives. The project should expose this as an option.

2. **Structured error messages**: Instead of `[ERROR or REFUSED]`, distinguish between:
   - `guardrailViolation` (safety filter triggered)
   - `exceededContextWindowSize` (context overflow)
   - `unsupportedLanguage`
   - `rateLimited`
   - `concurrentRequests`

3. **Retry logic for borderline cases**: Some guardrail triggers are non-deterministic. A slight rephrasing or retry may succeed.

4. **GUI: Show guardrail details**: Use `LanguageModelSession.logFeedbackAttachment()` to capture and display diagnostic info when guardrails trigger unexpectedly.

---

## 3. Rate Limiting — The Background Problem

### Apple's Rate Limits

- **Foreground apps**: Generous but undocumented rate limits
- **Background apps**: Strict rate limiting with a budget system. Exceeding it throws `rateLimited` errors
- **App extensions**: Extremely restrictive — one developer reported hitting rate limits after just 4 requests with 30-second gaps
- **Concurrent requests**: Only ONE request per session at a time. A second concurrent request throws `concurrentRequests`

### Where Apfel Breaks

**The OpenAI-compatible server** is the biggest risk here. The `--max-concurrent` flag suggests Apfel tries to handle parallel requests, but Apple's framework only allows one request per session at a time. If multiple clients hit the server simultaneously, the underlying model requests must be serialized — or each gets its own session (which means each has an independent context and no shared conversation state).

**Background execution**: If the server process gets backgrounded (e.g., user switches to another app), Apple will rate-limit the model requests, potentially making the server unresponsive.

### Fixes

1. **Request queue**: Implement a proper request queue with configurable concurrency. Each concurrent OpenAI API request should get its own `LanguageModelSession`, but limit the total number of active sessions.

2. **Document the concurrency model**: Make it clear that each `/v1/chat/completions` request creates an independent session — there is no shared state between API calls.

3. **Keep the process in foreground**: For the server mode, document that the terminal/process must remain in the foreground to avoid rate limiting.

4. **Handle `rateLimited` gracefully**: Return a proper HTTP 429 with `Retry-After` header instead of crashing.

---

## 4. OpenAI API Compatibility — The Impedance Mismatch

### The Core Problem

The OpenAI Chat Completions API was designed for cloud models with 128K+ token context windows, function calling, JSON mode, logprobs, and many other features. Apple's on-device model supports almost none of these.

### Specific Incompatibilities

| OpenAI Feature | Apple FM Support | Impact |
|---|---|---|
| `max_tokens` parameter | Partially (via `GenerationOptions`) | Must be capped at remaining context budget |
| `temperature` | Yes (via `GenerationOptions`) | Works |
| `top_p` | Yes (via `SamplingMode`) | Works |
| `functions`/`tools` | Partial (Apple has its own Tool protocol) | Schemas differ completely |
| `response_format: json` | No (use `@Generable` instead) | Clients expecting JSON mode will fail |
| `logprobs` | No | Not available |
| `n` (multiple completions) | No | Model generates one response |
| `stop` sequences | No | Not supported |
| `presence_penalty` / `frequency_penalty` | No | Not supported |
| `seed` | Yes (via `SamplingMode`) | Works but syntax differs |
| Model names | Only "apple-foundationmodel" | Clients sending "gpt-4" will need mapping |
| Token usage in response | Not natively (new in 26.4) | Can estimate with `tokenCount(for:)` |
| Multi-modal (images) | Text only as of now | Clients sending image messages will fail |

### Fixes

1. **Document supported parameters**: Return which parameters are ignored vs. supported in the `/v1/models` endpoint metadata.

2. **Validate and warn**: When receiving unsupported parameters (`logprobs`, `n > 1`, `stop`, `response_format`), return a warning in the response or log it.

3. **Map `max_tokens` correctly**: Clamp the requested `max_tokens` to `4096 - estimated_input_tokens` and return the actual limit used.

4. **Return usage object**: Populate the `usage` field in the response with token counts (now possible with 26.4 APIs).

5. **Reject image messages**: Return a clear error for multi-modal content rather than silently dropping it.

---

## 5. Acceptable Use Requirements — Legal Compliance

### Apple's Prohibited Uses (from official page)

Key restrictions that affect Apfel:

- **No circumventing safety guardrails** — The project must NOT provide a way to bypass Apple's guardrails (the `.permissiveContentTransform` is Apple's own sanctioned option for content transforms, not a bypass)
- **No generating scholarly/academic research** — The model explicitly cannot be used for "scholarly and academic research products, journals, textbooks, trade books, or courseware"
- **No regulated services** — Cannot be used for healthcare, legal, or financial services
- **No showing Apple in a "false or derogatory light"** — The EXAMPLES.md's commentary about Apple's safety filter being "absurd" and "puzzling" could be seen as derogatory depending on interpretation

### Where Apfel Has Risk

The **EXAMPLES.md file** demonstrates systematic prompt injection attempts ("Ignore all previous instructions", DAN prompts) and documents the model's safety filter failures. While this is legitimate security research, Apple's AUR explicitly prohibits "circumventing any safety policies, guardrails, or restrictions."

The **OpenAI-compatible server** effectively "exposes" the Foundation Models framework to arbitrary third-party clients, which is explicitly covered by the AUR's phrasing: "enable others to do the same."

### Fixes

1. **Add AUR compliance documentation**: Include a clear notice that the server is for local development/debugging only, not for production use that would violate Apple's AUR.

2. **Remove or caveat the DAN/jailbreak examples**: Frame them as security analysis, not as instructions for circumvention.

3. **Add guardrails to the server**: Don't allow the server to be exposed on non-localhost interfaces without explicit user acknowledgment.

---

## 6. Model Capabilities vs. Project Expectations

### What Apple's Model Is Good At

Apple explicitly states their ~3B parameter model is optimized for:
- Text summarization
- Text extraction
- Classification
- Guided generation (structured output via `@Generable`)
- Content tagging
- Simple Q&A within its training data

### What It Is NOT Good At

- World knowledge (training cutoff appears mid-2023)
- Advanced reasoning
- Code generation (works but has bugs, as EXAMPLES.md shows)
- Instruction following with precise constraints ("exactly 10 words" → gave 6)
- Creative writing under constraints

### Where Apfel's Positioning Is Misleading

The project's EXAMPLES.md shows the model being used for philosophy, ethics, creative writing, code generation in multiple languages, and translation — many of these are outside the model's intended design space. The CLI interface implies general-purpose chat capabilities.

### Fixes

1. **Set expectations in the README**: Note that the on-device model is ~3B parameters optimized for text processing tasks, not general-purpose chat.

2. **Add a `--task` flag**: Guide users toward supported tasks (summarize, extract, classify, tag) vs. open-ended chat.

---

## 7. Language Support Limitations

### Supported Languages (as of macOS 26)

English, German, French, Italian, Japanese, Korean, Chinese (simplified), Portuguese (Brazil), Spanish. Additional languages (Danish, Dutch, Norwegian, Portuguese-Portugal, Swedish, Turkish, Chinese traditional, Vietnamese) added later.

### Where Apfel Breaks

The CLI accepts any language input. Unsupported languages will throw `unsupportedLanguage` errors. The EXAMPLES.md shows the model being tested in Austrian German dialect and Japanese — these partially work but with quality issues (the Austrian German was poor, the Japanese translation was literal rather than idiomatic).

### Fixes

1. **Detect language before sending**: Optionally check input language and warn if it's not in the supported list.

2. **Return clear errors**: Map `unsupportedLanguage` to a helpful error message listing supported languages.

---

## 8. Memory & Performance Constraints

### Hardware Reality

- Model requires **~1.2GB RAM** once loaded (some sources say up to 3GB)
- **Apple Silicon only** (no Intel Macs)
- Performance varies: one developer reported 23 seconds for a philosophical question on M1
- The server mode will hold the model in memory continuously

### Where Apfel Breaks

Running the server (`apfel --serve`) continuously will keep ~1.2–3GB of RAM permanently allocated. On lower-spec machines (base M1 MacBook Air with 8GB RAM), this could cause memory pressure.

### Fixes

1. **Idle timeout**: Unload the model after a configurable period of inactivity.
2. **Memory usage monitoring**: Report model memory usage in the `/health` endpoint.
3. **Document minimum specs**: "Recommended: 16GB RAM for server mode."

---

## 9. New Apple Drops (March 2026) — What Apfel Should Adopt NOW

Apple shipped a wave of new tools in late March 2026 that directly address many of apfel's biggest problems. This section covers what dropped, what it fixes, and how to integrate it.

---

### 9a. Python SDK for Foundation Models (`apple-fm-sdk`)

**What it is**: Apple released official Python bindings for FoundationModels at [github.com/apple/python-apple-fm-sdk](https://github.com/apple/python-apple-fm-sdk). Install via `pip install apple-fm-sdk`. Requires macOS 26+, Xcode 26+, Python 3.10+.

**What it can do**:
- On-device inference via `fm.SystemLanguageModel()` and `fm.LanguageModelSession()`
- Streaming responses
- Guided generation via `@fm.generable` decorator (Python equivalent of Swift's `@Generable`)
- Tool calling via `fm.Tool` subclasses
- Guardrails configuration including `PERMISSIVE_CONTENT_TRANSFORMATIONS`
- Multi-turn sessions with context
- `session.is_responding` property to check if a request is in-flight

**How apfel should use it**:

1. **Automated prompt regression testing**: Instead of manually running CLI prompts and copy-pasting results (like the EXAMPLES.md was generated), use the Python SDK to build a proper test harness. Run 50 prompts, capture results, diff against previous model versions. Apple's own docs point to "Evaluating prompts to measure performance and improve model responses" — this is the intended workflow.

2. **Alternative server backend**: The OpenAI-compatible server could have a Python alternative using FastAPI + `apple-fm-sdk`. This would make it easier to add token counting middleware, request validation, and proper error handling.

3. **Batch evaluation**: When macOS 26.4 ships a new model version, run the full EXAMPLES.md suite against both old and new model to detect behavioral regressions.

**Example — testing guardrails in Python**:
```python
import apple_fm_sdk as fm

model = fm.SystemLanguageModel(
    guardrails=fm.SystemLanguageModelGuardrails.PERMISSIVE_CONTENT_TRANSFORMATIONS
)
session = fm.LanguageModelSession(model=model)

# This would have been blocked with default guardrails
response = await session.respond("Describe the color blue to someone who has never seen it")
print(response)  # Now works!
```

---

### 9b. Updated Model in macOS 26.4 — Better Instruction Following

**What changed**: Apple shipped an updated Foundation Models version in 26.4 that specifically improves instruction-following and tool-calling abilities. This is a model-level update — when users update their OS, the model changes.

**What this means for apfel**:

Many of the failures documented in EXAMPLES.md may now behave differently:
- "Respond using exactly 10 words" (gave 6) → might now respect the constraint
- "You are wrong about everything" system prompt override → might now comply
- Tool calling reliability → should be more consistent
- FizzBuzz one-liner → might actually produce correct code

**Action items**:

1. **Re-run the full EXAMPLES.md test suite on 26.4**: Compare results. Document improvements and remaining failures.

2. **Version-pin the README**: Note which macOS version the examples were tested on. Apple now explicitly says "test your prompts with the new model to verify your app's behavior" — this means behavior WILL change between OS updates.

3. **Add model version detection**: Use the new `contextSize` API or other introspection to detect and log which model version is running. This is critical for debugging — "it worked on 26.3 but broke on 26.4" will be a real support issue.

4. **Read Apple's new guide**: [Updating prompts for new model versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions) — Apple published specific guidance on how to handle model version transitions.

---

### 9c. Token Counting APIs (26.4) — The Missing Piece

**What dropped**: Two new APIs on `SystemLanguageModel`:
- `contextSize` → returns total available context (currently 4096)
- `tokenCount(for:)` → measures how many tokens a given input consumes

Both are marked `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)` — meaning they work on ALL versions that support Foundation Models, not just 26.4.

**How apfel should integrate these**:

1. **CLI: Pre-flight token check**
```swift
let model = SystemLanguageModel.default
let contextSize = try await model.contextSize  // 4096
let promptTokens = try await model.tokenCount(for: userPrompt)
let instructionTokens = try await model.tokenCount(for: systemPrompt)
let used = promptTokens + instructionTokens
let remaining = contextSize - used

if remaining < 200 {
    print("⚠️ Warning: Only \(remaining) tokens left for response")
}
```

2. **Server: Return proper `usage` in OpenAI responses**
```json
{
  "usage": {
    "prompt_tokens": 847,
    "completion_tokens": 312,
    "total_tokens": 1159
  }
}
```
This was previously impossible — now it's trivial with `tokenCount(for:)`.

3. **GUI: Token budget bar**
Add a visual indicator in the debug inspector: `[████████░░░░░░░░] 2,847 / 4,096 tokens (69%)`

4. **Chat mode: Smart session rotation**
```swift
let transcript = session.transcript
let totalTokens = try await model.tokenCount(for: transcript)
let threshold = Int(Double(contextSize) * 0.7) // 70%

if totalTokens > threshold {
    // Summarize and start new session
    let summary = try await summarizeTranscript(transcript)
    session = LanguageModelSession(instructions: summary)
}
```

---

### 9d. Custom Adapter Training Toolkit

**What it is**: Apple provides a Python-based toolkit to train LoRA-style adapters for the on-device model. You prepare JSONL training data, run training, export a `.fmadapter` package, and load it in your app.

**Relevance for apfel**: This is a stretch goal, but interesting. You could:
- Train an adapter specialized for code generation (fixing the FizzBuzz, Rust, and bash failures)
- Train an adapter for better instruction following under constraints
- Train an adapter for a specific domain (e.g., SEO analysis, which would be very relevant for your workshops)

**Caveats**:
- Each adapter is tied to a specific model version — when Apple updates the model in 26.4, 26.5, etc., you need to retrain
- Adapters are distributed as separate assets via Background Assets framework, not bundled in the app
- This is an advanced technique with significant maintenance overhead

---

### 9e. `.permissiveContentTransform` — The Guardrail Fix

**What it is**: Apple's officially sanctioned way to relax guardrails for content transformation tasks (summarization, rewriting, extraction). NOT a full bypass — it's specifically for when you're processing existing content, not generating new potentially harmful content.

**How to integrate into apfel**:

1. **New CLI flag**: `apfel --permissive "Summarize this article about a crime scene"`

2. **Server option**: Accept a custom header or parameter to enable permissive mode:
```
POST /v1/chat/completions
X-Apfel-Guardrails: permissive
```

3. **GUI toggle**: Add a checkbox in the inspector: `☑ Permissive Content Transform`

4. **Swift implementation**:
```swift
let model = SystemLanguageModel(
    guardrails: .permissiveContentTransformations
)
let session = LanguageModelSession(model: model)
```

**What this fixes from EXAMPLES.md**:
- ✅ Describing the color blue → should pass
- ✅ Explaining "Schadenfreude" → should pass  
- ✅ Summarizing news about violence/crime → should pass
- ❌ Won't help with the vim/emacs or trolley problem refusals (those are generation, not transformation)

**AUR compliance note**: This is Apple's own API, not a circumvention. But document clearly that it's for content transforms, not for bypassing safety on generation tasks.

---

### 9f. Prompt Evaluation Framework

**What Apple published**: New documentation on [Evaluating prompts to measure performance and improve model responses](https://developer.apple.com/documentation/FoundationModels/evaluating-prompts-to-measure-performance-and-improve-model-responses).

**How apfel should use it**:

Combined with the Python SDK, build a CI-style evaluation pipeline:

```python
import apple_fm_sdk as fm
import json

test_cases = [
    {"prompt": "What is 17 * 23?", "expected_contains": "391"},
    {"prompt": "Is 97 prime?", "expected_contains": "prime"},
    {"prompt": "Capital of France?", "expected_contains": "Paris"},
]

async def run_eval():
    results = []
    for test in test_cases:
        session = fm.LanguageModelSession()
        response = await session.respond(test["prompt"])
        passed = test["expected_contains"].lower() in str(response).lower()
        results.append({"prompt": test["prompt"], "passed": passed, "response": str(response)})
    
    with open("eval_results.json", "w") as f:
        json.dump(results, f, indent=2)
    
    passed = sum(1 for r in results if r["passed"])
    print(f"Passed: {passed}/{len(results)}")
```

This makes EXAMPLES.md reproducible and diffable across model versions.

---

## Summary: Priority Fix List

| Priority | Issue | Severity | Effort | New Fix Available? |
|---|---|---|---|---|
| 🔴 P0 | Context window overflow in chat/server mode | Crashes app | Medium | ✅ `tokenCount(for:)` + `contextSize` (26.4) |
| 🔴 P0 | OpenAI API sends data exceeding 4096 tokens | Silent failure | Medium | ✅ Pre-flight token counting (26.4) |
| 🟡 P1 | Guardrail false positives with no recovery | Poor UX | Low | ✅ `.permissiveContentTransform` |
| 🟡 P1 | Rate limiting in server mode (background/concurrent) | Server hangs | Medium | — |
| 🟡 P1 | No token usage tracking or budget display | Developer confusion | Low | ✅ `tokenCount(for:)` (26.4) |
| 🟡 P1 | Model behavior changes between OS versions | Regression risk | Medium | ✅ Python SDK for eval + Apple's prompt eval docs |
| 🟢 P2 | Unsupported OpenAI parameters silently ignored | Compatibility | Low | — |
| 🟢 P2 | AUR compliance documentation missing | Legal risk | Low | — |
| 🟢 P2 | Language support validation | Error clarity | Low | — |
| 🟢 P2 | Memory management for server mode | Resource waste | Medium | — |
| 🟢 P2 | No automated prompt regression tests | Quality drift | Low | ✅ `apple-fm-sdk` Python + eval framework |
| 🔵 P3 | Instruction following failures (count, constraints) | Model quality | — | ✅ 26.4 model update (test!) |
| 🔵 P3 | Domain-specific model quality (code gen) | Model quality | High | ✅ Custom adapter training toolkit |

---

## Quick Reference: Apple FM Hard Limits

| Constraint | Value | Source |
|---|---|---|
| Context window | 4,096 tokens (fixed) | Apple Developer Forums, TN3193 |
| Token estimation | ~3–4 chars/token (English) | Apple Developer Forums |
| Model size | ~3B parameters | WWDC25 |
| RAM usage | ~1.2–3GB | Developer reports |
| Concurrent requests per session | 1 | Framework throws `concurrentRequests` |
| Background rate limit | Strict, budget-based | Framework throws `rateLimited` |
| Supported platforms | macOS 26+, iOS 26+, visionOS 26+ | Apple docs |
| Required hardware | Apple Silicon | Apple docs |
| Input modality | Text only | Apple docs |
| Safety layers | Model training + guardrail enforcement | Apple ML Research |
| Available models | `foundation-small` only | Apple docs |
| API for token counting | `contextSize`, `tokenCount(for:)` (26.4+) | Apple docs |

## Quick Reference: New Apple Tools (March 2026)

| Tool | What | Install/Link |
|---|---|---|
| `apple-fm-sdk` | Python bindings for Foundation Models | `pip install apple-fm-sdk` / [GitHub](https://github.com/apple/python-apple-fm-sdk) |
| `contextSize` API | Get total context window size | Built into FoundationModels 26.4, back-deployed |
| `tokenCount(for:)` API | Measure token consumption of any input | Built into FoundationModels 26.4, back-deployed |
| `.permissiveContentTransformations` | Relaxed guardrails for content transforms | `SystemLanguageModel(guardrails: .permissiveContentTransformations)` |
| Adapter Training Toolkit | Train custom LoRA adapters | [Apple Developer](https://developer.apple.com/apple-intelligence/foundation-models-adapter/) |
| Prompt Evaluation Guide | Framework for testing prompt quality | [Apple Docs](https://developer.apple.com/documentation/FoundationModels/evaluating-prompts-to-measure-performance-and-improve-model-responses) |
| Model Version Update Guide | Handle model changes across OS updates | [Apple Docs](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions) |

---

*Analysis based on Apple's official documentation, WWDC25 sessions, TN3193 tech note, Apple Developer Forums, Apple Hello Developer March 2026 newsletter, apple-fm-sdk GitHub repo, and the apfel project source as of March 26, 2026.*

---

## 10. Tool Calling Bridge — Exposing Apple FM Tools via OpenAI API

This is the most technically challenging compatibility gap, but also the most valuable one to solve. Here's the full mapping between the two systems and a concrete architecture for bridging them.

---

### 10a. How Apple Tool Calling Works (Swift)

Apple's tool calling uses a compile-time Swift protocol:

```swift
import FoundationModels

struct GetWeatherTool: Tool {
    let name = "getWeather"                    // Short, verb-first, no spaces
    let description = "Get current weather"    // One sentence max (tokens matter!)
    
    @Generable
    struct Arguments {
        let city: String
        let units: String
    }
    
    func call(arguments: Arguments) async throws -> ToolOutput {
        // Your code runs here — fetch weather, query DB, whatever
        let temp = fetchTemperature(city: arguments.city)
        return ToolOutput("Temperature in \(arguments.city): \(temp)°C")
    }
}

// Register tools at session creation
let session = LanguageModelSession(
    instructions: "You are a helpful assistant.",
    tools: [GetWeatherTool()]
)
```

**Key characteristics**:
- Tool name + description + argument schema are **serialized into the prompt** (costs tokens!)
- Arguments use `@Generable` structs — constrained decoding ensures valid types
- The framework **automatically decides** when to call tools (no manual orchestration)
- Tools can be called **multiple times** and **in parallel** within a single request
- Tool outputs are inserted back into the transcript automatically
- The model then generates a final response incorporating tool outputs
- Return type is `ToolOutput` (a string or `GeneratedContent`)

**Critical constraint**: Tool definitions eat into the 4,096 token budget. Each tool's name, description, and full argument schema gets serialized. 3-4 tools with detailed schemas can consume 200-400 tokens before you even send a prompt.

---

### 10b. How OpenAI Tool Calling Works

OpenAI uses JSON schema in the request:

```json
{
  "model": "gpt-4",
  "messages": [{"role": "user", "content": "What's the weather in Paris?"}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get current weather for a city",
      "parameters": {
        "type": "object",
        "properties": {
          "city": {"type": "string", "description": "City name"},
          "units": {"type": "string", "enum": ["celsius", "fahrenheit"]}
        },
        "required": ["city"]
      }
    }
  }]
}
```

When the model wants to call a tool, it returns:
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "tool_calls": [{
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "get_weather",
          "arguments": "{\"city\": \"Paris\", \"units\": \"celsius\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

The client then executes the tool, sends the result back, and the model generates a final response.

**Key difference**: In OpenAI's flow, the CLIENT executes the tool. In Apple's flow, the FRAMEWORK executes the tool automatically. The model never returns a "please call this tool" response — it just calls it internally and returns the final answer.

---

### 10c. The Mapping Problem

| Aspect | OpenAI API | Apple FM | Gap |
|---|---|---|---|
| Tool definition format | JSON Schema | Swift `Tool` protocol + `@Generable` | Must convert JSON → Swift at runtime |
| Who executes tools | Client (external) | Framework (internal, automatic) | Fundamental architecture difference |
| Tool call visibility | Returned as `tool_calls` in response | Hidden in transcript | Must expose internal calls |
| Multi-step flow | Client sends tool results back | Framework handles internally | No round-trip needed |
| Argument types | JSON Schema (any valid JSON) | `@Generable` structs (limited types) | String, Int, Double, Bool, enums, arrays |
| Parallel tool calls | Supported | Supported | ✅ Compatible |
| `tool_choice` parameter | `auto`, `required`, `none`, or specific | No equivalent — model always decides | Can't force tool usage |

---

### 10d. Architecture: Two Modes

Apfel should support **two distinct tool calling modes** in the server:

#### Mode 1: "Proxy Mode" — Apple Handles Everything (Recommended)

The OpenAI client registers tools AND provides the tool implementations as webhook URLs. Apfel converts the JSON schemas to dynamic Apple tools at runtime, registers them with the session, and returns the final response. The client never sees intermediate tool calls.

**Flow**:
```
Client                          Apfel Server                    Apple FM
  │                                  │                              │
  ├─ POST /v1/chat/completions ─────►│                              │
  │  (messages + tools[])            │                              │
  │                                  ├─ Convert JSON schemas ──────►│
  │                                  │  to dynamic Apple Tools      │
  │                                  │                              │
  │                                  │  Apple FM calls tools ◄─────►│
  │                                  │  internally, gets results    │
  │                                  │                              │
  │◄─ Final response ───────────────┤◄─ Final text response ───────│
  │  (no tool_calls in response)     │                              │
```

**Implementation — Dynamic Tool from JSON Schema**:

```swift
import FoundationModels

/// A tool created at runtime from an OpenAI-style JSON schema
struct DynamicTool: Tool {
    let name: String
    let description: String
    
    // Use dynamic schema instead of @Generable
    private let schema: GenerationSchema
    private let handler: (GeneratedContent) async throws -> String
    
    var argumentsSchema: GenerationSchema { schema }
    
    func call(arguments: GeneratedContent) async throws -> ToolOutput {
        let result = try await handler(arguments)
        return ToolOutput(result)
    }
}

/// Convert OpenAI tool JSON to Apple FM dynamic tool
func convertOpenAITool(_ toolDef: [String: Any], 
                        handler: @escaping (GeneratedContent) async throws -> String) -> DynamicTool {
    let function = toolDef["function"] as! [String: Any]
    let name = function["name"] as! String
    let description = function["description"] as? String ?? ""
    let parameters = function["parameters"] as? [String: Any] ?? [:]
    
    // Convert JSON Schema properties to GenerationSchema
    let schema = buildGenerationSchema(from: parameters)
    
    return DynamicTool(
        name: name,
        description: description,
        schema: schema,
        handler: handler
    )
}
```

**When to use**: When the client wants Apple FM to autonomously decide tool usage. Best for simple tools like weather, search, database lookups.

#### Mode 2: "Pass-Through Mode" — Client Handles Tools (OpenAI-Compatible)

For full OpenAI compatibility, Apfel can emulate the standard flow where the model returns tool calls and the client executes them. This requires intercepting Apple's internal tool execution.

**Flow**:
```
Client                          Apfel Server                    Apple FM
  │                                  │                              │
  ├─ POST /v1/chat/completions ─────►│                              │
  │  (messages + tools[])            │                              │
  │                                  ├─ Prompt with tool schemas ──►│
  │                                  │  (as instructions text)      │
  │                                  │                              │
  │◄─ Response with tool_calls ──────┤◄─ Structured output ─────────│
  │   finish_reason: "tool_calls"    │  (parsed as tool call)       │
  │                                  │                              │
  ├─ POST with tool results ────────►│                              │
  │  (tool role messages)            ├─ New session with results ──►│
  │                                  │                              │
  │◄─ Final response ───────────────┤◄─ Final text ────────────────│
```

**Implementation — Using Guided Generation to Emit Tool Calls**:

```swift
/// Schema that mimics OpenAI's tool_call output
@Generable
struct ToolCallDecision {
    @Guide(description: "Whether to call a tool or respond directly")
    let action: Action
    
    @Generable
    enum Action {
        case respondDirectly
        case callTool
    }
    
    @Guide(description: "Name of the tool to call, if action is callTool")
    let toolName: String?
    
    @Guide(description: "JSON arguments for the tool")
    let arguments: String?
}

// Step 1: Ask the model what to do (without actually calling tools)
let decisionSession = LanguageModelSession(
    instructions: """
    You have access to these tools: \(toolDescriptions).
    Decide whether to call a tool or respond directly.
    """
)
let decision = try await decisionSession.respond(
    to: userPrompt,
    generating: ToolCallDecision.self
)

if decision.action == .callTool {
    // Step 2: Return OpenAI-format tool_calls to the client
    return OpenAIResponse(
        choices: [Choice(
            message: AssistantMessage(
                toolCalls: [ToolCall(
                    id: "call_\(UUID().uuidString.prefix(8))",
                    function: FunctionCall(
                        name: decision.toolName!,
                        arguments: decision.arguments!
                    )
                )]
            ),
            finishReason: "tool_calls"
        )]
    )
}
```

**When to use**: When the client expects standard OpenAI tool calling flow (e.g., LangChain, AutoGen, custom agents). More complex but fully compatible.

---

### 10e. JSON Schema → @Generable Type Mapping

Not all OpenAI JSON Schema types map cleanly to Apple's `@Generable`:

| JSON Schema Type | Apple @Generable | Notes |
|---|---|---|
| `"type": "string"` | `String` | ✅ Direct |
| `"type": "integer"` | `Int` | ✅ Direct |
| `"type": "number"` | `Double` | ✅ Direct |
| `"type": "boolean"` | `Bool` | ✅ Direct |
| `"type": "array"` | `[T]` where T is Generable | ✅ Works |
| `"enum": ["a","b","c"]` | `@Generable enum` | ✅ Use `@Guide(anyOf:)` |
| `"type": "object"` (nested) | Nested `@Generable struct` | ⚠️ Must build dynamically |
| `"oneOf"` / `"anyOf"` | Not directly supported | ❌ Flatten or simplify |
| `"format": "date"` | `String` (parse manually) | ⚠️ No native date type |
| `"pattern": "regex"` | `@Guide(pattern:)` | ✅ Supported |
| `"minimum"` / `"maximum"` | `@Guide(range:)` | ✅ Supported |

**For runtime dynamic schemas** (when you don't know the tool shape at compile time), use `GenerationSchema` directly instead of `@Generable`. This is Apple's "dynamic schema" feature from the WWDC25 Deep Dive session.

---

### 10f. Token Budget Impact of Tools

This is critical and easy to miss. Every tool registered with the session consumes tokens:

```
Tool "getWeather" with 2 parameters:     ~80-120 tokens
Tool "searchDatabase" with 5 parameters: ~150-200 tokens
Tool "createEvent" with 8 parameters:    ~250-350 tokens
```

With a 4,096 total budget, registering 3-4 tools can eat 10-20% of your context before any conversation happens.

**Mitigation strategies**:

1. **Keep tool names short**: `getWeather` not `getCurrentWeatherConditions`
2. **Keep descriptions to one sentence**: The model was trained on concise descriptions
3. **Minimize arguments**: Each property in the schema costs tokens
4. **Lazy tool registration**: Only register tools the current prompt is likely to need (analyze the message first, then decide which tools to attach)
5. **Use `tokenCount(for:)` on 26.4**: Measure the actual token cost of your tool set before sending the prompt

```swift
// Measure tool overhead
let model = SystemLanguageModel.default
let contextSize = try await model.contextSize

let sessionWithTools = LanguageModelSession(tools: [weatherTool, searchTool])
let toolOverhead = try await model.tokenCount(for: sessionWithTools.transcript)

print("Tools consume \(toolOverhead) of \(contextSize) tokens (\(toolOverhead * 100 / contextSize)%)")
```

---

### 10g. Server Endpoint Changes

Update the `/v1/chat/completions` endpoint to handle tools:

```swift
// In the HTTP handler
func handleChatCompletion(request: Request) async throws -> Response {
    let body = try request.decode(OpenAIChatRequest.self)
    
    // 1. Convert OpenAI tools to Apple FM tools
    var appleTools: [any Tool] = []
    if let tools = body.tools {
        for toolDef in tools {
            let dynamicTool = convertOpenAITool(toolDef) { arguments in
                // Mode 1: Execute via webhook
                // Mode 2: Return tool_calls to client
            }
            appleTools.append(dynamicTool)
        }
    }
    
    // 2. Check token budget BEFORE creating session
    let model = SystemLanguageModel.default
    let contextSize = try await model.contextSize
    let messageTokens = try await model.tokenCount(for: messagesAsText)
    // Note: tool schemas also consume tokens
    
    if messageTokens > Int(Double(contextSize) * 0.75) {
        return Response(status: .badRequest, body: 
            "Input exceeds 75% of 4096 token context window. Reduce messages or tools.")
    }
    
    // 3. Create session with tools
    let session = LanguageModelSession(
        instructions: systemPrompt,
        tools: appleTools
    )
    
    // 4. Generate response (tools are called automatically by Apple FM)
    let response = try await session.respond(to: userPrompt)
    
    // 5. Inspect transcript for tool calls (for logging/debugging)
    let toolCalls = session.transcript.entries.compactMap { entry -> ToolCallLog? in
        if case .toolCall(let call) = entry {
            return ToolCallLog(name: call.toolName, arguments: call.arguments)
        }
        return nil
    }
    
    // 6. Return OpenAI-compatible response
    return formatAsOpenAIResponse(
        content: response.content,
        toolCallsLog: toolCalls,
        model: "apple-foundationmodel"
    )
}
```

---

### 10h. What to Document for API Consumers

Add this to the server's `/v1/models` response or API docs:

```json
{
  "tool_calling": {
    "supported": true,
    "mode": "auto-execute",
    "note": "Unlike OpenAI, Apple FM executes tools internally. Tool calls are not returned to the client — the final response already incorporates tool outputs.",
    "limitations": {
      "tool_choice": "Only 'auto' is supported. Cannot force specific tool usage.",
      "max_tools": "3-4 recommended due to 4096 token context limit",
      "argument_types": "string, integer, number, boolean, enum, array. No nested objects, oneOf, anyOf.",
      "token_cost": "Each tool definition consumes ~80-350 tokens from the context window"
    }
  }
}
```

---

### 10i. Summary: What Works, What Doesn't

| Feature | Status | Notes |
|---|---|---|
| Register tools via JSON Schema | ✅ Possible | Convert to dynamic `GenerationSchema` |
| Model decides when to call tools | ✅ Native | Apple FM does this automatically |
| Parallel tool calls | ✅ Native | Framework handles this |
| Return tool_calls to client | ⚠️ Emulatable | Use guided generation to simulate |
| `tool_choice: "required"` | ❌ Not supported | Model always decides |
| `tool_choice: {"function": "name"}` | ❌ Not supported | Cannot force specific tool |
| Streaming tool call deltas | ⚠️ Partial | Can stream final response, not tool args |
| Tool results in conversation history | ✅ In transcript | But transcript format differs from OpenAI |
| Nested object arguments | ❌ Limited | Flatten to simple types |

---

*Analysis based on Apple's official documentation, WWDC25 sessions, TN3193 tech note, Apple Developer Forums, Apple Hello Developer March 2026 newsletter, apple-fm-sdk GitHub repo, OpenAI API reference, and the apfel project source as of March 26, 2026.*

---

## 11. What Apple AI Tools Can ACTUALLY Do — And YOLO Mode

### The Fundamental Insight Most People Miss

Apple's tool calling is NOT a list of pre-built tools. There are NO built-in tools. The framework gives the model the ability to **call any Swift function you write**. The model autonomously decides when to call your code, with what arguments, and how many times.

This is more powerful than OpenAI's tool calling in one critical way: **the tool execution happens on-device, in-process, with full access to the user's private data and local system**. No network call. No API key. No cloud. The model calls your Swift function, your function reads from Contacts/Calendar/HealthKit/filesystem/whatever, returns a string, and the model incorporates it into its response. All within one `session.respond()` call.

The model can also:
- Call tools **multiple times** in a single request
- Call tools **in parallel** (framework handles concurrency automatically)
- **Chain** tool calls — call tool A, use result to decide whether to call tool B
- Tools can **store state** across invocations (use a class, not a struct)
- Tools can **fail gracefully** — throw errors that the model can recover from

The framework guarantees **structural correctness** of tool calls through constrained decoding — the model literally cannot hallucinate a tool name or produce malformed arguments. This is fundamentally different from OpenAI where the model CAN produce invalid JSON.

---

### What Tools Can Access (The Full Map)

Here's everything a tool can reach from a macOS process like apfel:

**Apple Frameworks (private, on-device data)**:

| Framework | What You Can Read/Do | Example Tool |
|---|---|---|
| Contacts (`CNContactStore`) | Names, emails, phones, birthdays, relationships | `findContact` — look up contacts by criteria |
| EventKit | Calendar events, reminders, alarms | `getEvents` — fetch events for a date range |
| HealthKit | Steps, heart rate, blood pressure, sleep, workouts | `getHealthData` — read health metrics |
| MapKit | POI search, directions, geocoding | `findPlaces` — search for restaurants/hotels nearby |
| CoreLocation | Current GPS coordinates | `getLocation` — where am I right now? |
| Photos | Photo library metadata, albums, faces | `findPhotos` — search photos by date/location |
| MusicKit | Apple Music library, playlists, listening history | `searchMusic` — find songs/playlists |
| FileManager | Local filesystem — read/write/list files | `readFile`, `listDirectory`, `writeFile` |
| UserDefaults | App preferences and settings | `getPreference` — read app config |
| Keychain | Stored credentials (with permission) | Sensitive — probably shouldn't |
| Core Data / SwiftData | App databases | `queryDatabase` — query local app data |

**System-level access (macOS)**:

| Capability | What | Example Tool |
|---|---|---|
| `Process` / shell exec | Run terminal commands | `runCommand` — execute bash, get output |
| `URLSession` | HTTP requests | `fetchURL` — GET any URL, return content |
| Clipboard (`NSPasteboard`) | Read/write clipboard | `getClipboard`, `setClipboard` |
| `NSWorkspace` | Open apps, URLs, files | `openApp`, `openURL` |
| `NSAppleScript` | Run AppleScript | `runAppleScript` — control any scriptable app |
| `NSScreen` | Display info | `getScreenInfo` |
| `FileManager` + `NSWorkspace` | Open Finder, reveal files | `revealInFinder` |
| `IOKit` / `sysctl` | Battery, CPU, memory info | `getSystemInfo` |
| Notifications | Post system notifications | `sendNotification` |

**Network (when online)**:

| Capability | What | Example Tool |
|---|---|---|
| `URLSession` | Any REST API | `callAPI` — hit any HTTP endpoint |
| `WKWebView` / web scraping | Load + parse web pages | `scrapeWebPage` |
| WebSocket | Real-time connections | `connectWebSocket` |

---

### YOLO Mode — The Architecture

The idea: apfel ships with a **set of built-in power tools** that the model can call autonomously. No confirmation dialogs. No "are you sure?" prompts. The model decides what to do and does it. Like Claude Code's `--dangerously-skip-permissions`, but for Apple's on-device model.

#### Why This Makes Sense for Apfel

1. **It's local-only**: The model runs on YOUR Mac, accesses YOUR files, executes on YOUR system. There's no cloud. No one else is involved.
2. **It's a developer tool**: Apfel explicitly positions itself as a "developer-facing shell and debug harness." Developers accept risk.
3. **4,096 tokens means simple tasks**: The context window is so small that complex multi-step attacks are impractical. By the time you've set up an elaborate prompt injection, you've exhausted your token budget.

#### The Built-In Tool Set for YOLO Mode

```swift
// ═══════════════════════════════════════════════
// TIER 1: READ-ONLY (safe, no side effects)
// ═══════════════════════════════════════════════

struct ReadFileTool: Tool {
    let name = "readFile"
    let description = "Read contents of a file at the given path."
    @Generable struct Arguments {
        @Guide(description: "Absolute file path") let path: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let content = try String(contentsOfFile: arguments.path, encoding: .utf8)
        // Truncate to ~1000 chars to save tokens
        let truncated = String(content.prefix(1000))
        return ToolOutput(truncated)
    }
}

struct ListDirectoryTool: Tool {
    let name = "listDirectory"
    let description = "List files and folders in a directory."
    @Generable struct Arguments {
        @Guide(description: "Directory path") let path: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let items = try FileManager.default.contentsOfDirectory(atPath: arguments.path)
        return ToolOutput(items.joined(separator: "\n"))
    }
}

struct FetchURLTool: Tool {
    let name = "fetchURL"
    let description = "Fetch the text content of a web URL."
    @Generable struct Arguments {
        @Guide(description: "Full URL including https://") let url: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let (data, _) = try await URLSession.shared.data(from: URL(string: arguments.url)!)
        let text = String(data: data, encoding: .utf8) ?? ""
        return ToolOutput(String(text.prefix(1500)))
    }
}

struct CurrentTimeTool: Tool {
    let name = "currentTime"
    let description = "Get the current date and time."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> ToolOutput {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return ToolOutput(formatter.string(from: Date()))
    }
}

struct SystemInfoTool: Tool {
    let name = "systemInfo"
    let description = "Get system information like hostname, OS version, CPU, and memory."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> ToolOutput {
        let host = ProcessInfo.processInfo.hostName
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let mem = ProcessInfo.processInfo.physicalMemory / (1024*1024*1024)
        let cpu = ProcessInfo.processInfo.processorCount
        return ToolOutput("Host: \(host)\nOS: \(os)\nCPU: \(cpu) cores\nRAM: \(mem)GB")
    }
}

struct ClipboardReadTool: Tool {
    let name = "readClipboard"
    let description = "Read the current text content of the system clipboard."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> ToolOutput {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string) ?? "(clipboard empty)"
        return ToolOutput(String(text.prefix(500)))
    }
}

// ═══════════════════════════════════════════════
// TIER 2: WRITE / EXECUTE (side effects — YOLO only)
// ═══════════════════════════════════════════════

struct WriteFileTool: Tool {
    let name = "writeFile"
    let description = "Write text content to a file. Creates or overwrites."
    @Generable struct Arguments {
        @Guide(description: "Absolute file path") let path: String
        @Guide(description: "Text content to write") let content: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        try arguments.content.write(toFile: arguments.path, atomically: true, encoding: .utf8)
        return ToolOutput("Written \(arguments.content.count) chars to \(arguments.path)")
    }
}

struct RunCommandTool: Tool {
    let name = "runCommand"
    let description = "Execute a shell command and return its output."
    @Generable struct Arguments {
        @Guide(description: "Shell command to execute") let command: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", arguments.command]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ToolOutput(String(output.prefix(1500)))
    }
}

struct OpenURLTool: Tool {
    let name = "openURL"
    let description = "Open a URL or file in the default application."
    @Generable struct Arguments {
        @Guide(description: "URL or file path to open") let url: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        NSWorkspace.shared.open(URL(string: arguments.url)!)
        return ToolOutput("Opened: \(arguments.url)")
    }
}

struct ClipboardWriteTool: Tool {
    let name = "writeClipboard"
    let description = "Copy text to the system clipboard."
    @Generable struct Arguments {
        @Guide(description: "Text to copy") let text: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(arguments.text, forType: .string)
        return ToolOutput("Copied \(arguments.text.count) chars to clipboard")
    }
}

struct SendNotificationTool: Tool {
    let name = "sendNotification"
    let description = "Show a macOS notification with a title and message."
    @Generable struct Arguments {
        @Guide(description: "Notification title") let title: String
        @Guide(description: "Notification body") let body: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let notification = NSUserNotification()
        notification.title = arguments.title
        notification.informativeText = arguments.body
        NSUserNotificationCenter.default.deliver(notification)
        return ToolOutput("Notification sent: \(arguments.title)")
    }
}
```

#### CLI Interface

```bash
# Default: read-only tools only
apfel --chat

# YOLO mode: all tools, no confirmation
apfel --chat --yolo

# YOLO with specific tools
apfel --chat --yolo --tools readFile,writeFile,runCommand

# YOLO with system prompt for agent behavior
apfel --chat --yolo -s "You are a dev assistant. Use tools to help the user."

# Single command, YOLO
apfel --yolo "Read my ~/.zshrc and tell me what shell plugins I have"

# Pipe + YOLO = automation
echo "Find all TODO comments in ~/Projects/myapp/src/" | apfel --yolo

# Server mode with YOLO tools
apfel --serve --yolo --port 11434
```

#### The Token Budget Problem with Tools

This is where it gets real. Remember: **4,096 tokens total**. Each tool costs tokens:

```
Tool definitions overhead (estimated):
  readFile:          ~60 tokens
  listDirectory:     ~50 tokens
  fetchURL:          ~65 tokens
  currentTime:       ~30 tokens
  systemInfo:        ~40 tokens
  readClipboard:     ~35 tokens
  writeFile:         ~70 tokens
  runCommand:        ~55 tokens
  openURL:           ~50 tokens
  writeClipboard:    ~55 tokens
  sendNotification:  ~65 tokens
  ─────────────────────────────
  ALL 11 tools:      ~575 tokens (14% of budget!)
```

With all tools registered, you have ~3,500 tokens left for system prompt + user prompt + model response + tool outputs. That's tight.

**Smart tool loading strategy**:

```swift
enum ToolTier {
    case readonly   // readFile, listDir, fetchURL, time, sysInfo, clipboard
    case yolo       // readonly + writeFile, runCommand, openURL, writeClipboard, notify
    case minimal    // just currentTime + readFile (for token savings)
    case custom     // user-specified subset
}

func toolsForTier(_ tier: ToolTier) -> [any Tool] {
    switch tier {
    case .readonly:
        return [ReadFileTool(), ListDirectoryTool(), FetchURLTool(),
                CurrentTimeTool(), SystemInfoTool(), ClipboardReadTool()]
    case .yolo:
        return toolsForTier(.readonly) + [
            WriteFileTool(), RunCommandTool(), OpenURLTool(),
            ClipboardWriteTool(), SendNotificationTool()
        ]
    case .minimal:
        return [CurrentTimeTool(), ReadFileTool()]
    case .custom:
        // Parse from --tools flag
        return []
    }
}
```

Even smarter: **lazy tool injection**. Parse the user's prompt first, estimate which tools might be relevant, and only register those:

```swift
func selectToolsForPrompt(_ prompt: String) -> [any Tool] {
    var tools: [any Tool] = [CurrentTimeTool()]  // Always available, cheap
    
    let lower = prompt.lowercased()
    if lower.contains("file") || lower.contains("read") || lower.contains("cat") {
        tools.append(ReadFileTool())
    }
    if lower.contains("directory") || lower.contains("folder") || lower.contains("ls") {
        tools.append(ListDirectoryTool())
    }
    if lower.contains("http") || lower.contains("url") || lower.contains("fetch") || lower.contains("web") {
        tools.append(FetchURLTool())
    }
    if lower.contains("run") || lower.contains("exec") || lower.contains("command") || lower.contains("shell") {
        tools.append(RunCommandTool())
    }
    if lower.contains("write") || lower.contains("save") || lower.contains("create file") {
        tools.append(WriteFileTool())
    }
    if lower.contains("clipboard") || lower.contains("copy") || lower.contains("paste") {
        tools.append(ClipboardReadTool())
        tools.append(ClipboardWriteTool())
    }
    if lower.contains("open") || lower.contains("launch") || lower.contains("browse") {
        tools.append(OpenURLTool())
    }
    if lower.contains("notify") || lower.contains("alert") || lower.contains("remind") {
        tools.append(SendNotificationTool())
    }
    return tools
}
```

This could cut tool overhead from ~575 tokens to ~100-200 tokens for a typical prompt, leaving much more room for actual conversation.

#### OpenAI Server with YOLO Tools

When running `apfel --serve --yolo`, the server should:

1. Register all YOLO tools with every session
2. Accept standard OpenAI `tools[]` in addition (client-defined tools)
3. Return tool call traces in a custom extension field for debugging:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "You have 3 shell plugins configured: zsh-autosuggestions, zsh-syntax-highlighting, and fzf."
    },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 340, "completion_tokens": 45, "total_tokens": 385 },
  "x_apfel_tool_calls": [
    { "tool": "readFile", "arguments": {"path": "/Users/franz/.zshrc"}, "output_chars": 847 }
  ]
}
```

The `x_apfel_tool_calls` field isn't part of the OpenAI spec but lets debugging clients (including apfel's own GUI) see exactly what happened under the hood.

#### Safety Tiers

```
┌─────────────────────────────────────────────────┐
│ DEFAULT (no flags)                              │
│ No tools. Pure text generation.                 │
│ Safe. Boring.                                   │
├─────────────────────────────────────────────────┤
│ --tools (explicit list)                         │
│ Only named tools are registered.                │
│ User controls exactly what the model can do.    │
├─────────────────────────────────────────────────┤
│ --read-only                                     │
│ All Tier 1 tools. Can read files, fetch URLs,   │
│ check time, read clipboard. Cannot write or     │
│ execute anything. Safe for exploration.          │
├─────────────────────────────────────────────────┤
│ --yolo                                          │
│ All tools. Can read, write, execute commands,   │
│ open URLs, send notifications. No confirmation. │
│ Full local agent mode.                          │
│                                                 │
│ ⚠️  Prints warning on startup:                  │
│ "YOLO mode: model can execute shell commands    │
│  and write files without confirmation."         │
└─────────────────────────────────────────────────┘
```

#### Real-World YOLO Examples

```bash
# "What's in my downloads folder?"
$ apfel --yolo "What files are in my Downloads folder? List the 5 largest."
# Model calls: listDirectory("~/Downloads") → runCommand("ls -lS ~/Downloads | head -5")
# Returns: formatted list with sizes

# "Fix my git mess"  
$ apfel --yolo "I'm in ~/Projects/myapp. Show me uncommitted changes and create a commit message."
# Model calls: runCommand("cd ~/Projects/myapp && git status")
#              runCommand("cd ~/Projects/myapp && git diff --stat")
# Returns: suggested commit message based on actual changes

# "What's eating my disk?"
$ apfel --yolo "Find the largest files on my Mac taking up more than 1GB"  
# Model calls: runCommand("find / -size +1G -type f 2>/dev/null | head -20")
# Returns: list with recommendations

# "Summarize this doc"
$ apfel --yolo "Read ~/Documents/proposal.md and write a 3-bullet summary to ~/Desktop/summary.txt"
# Model calls: readFile("~/Documents/proposal.md")
#              writeFile("~/Desktop/summary.txt", "• ...")
# Returns: confirmation + the summary

# "What's on my clipboard?"
$ apfel --yolo "Take what's on my clipboard, translate it to German, and put the result back"
# Model calls: readClipboard() → processes → writeClipboard(translated)
# Returns: done

# Pipe mode — process stdin with tools
$ cat error.log | apfel --yolo "Analyze this error log. Check if the service at localhost:8080 is running."
# Model calls: runCommand("curl -s http://localhost:8080/health")
# Returns: analysis + service status
```

#### AUR Compliance Note

Apple's Acceptable Use Requirements say you must not "circumvent any safety policies, guardrails, or restrictions." YOLO mode doesn't circumvent guardrails — the model's safety layer still applies to all prompts and responses. What YOLO does is give the model access to system tools, which is **exactly what the Tool protocol was designed for**. Apple's own WWDC demos show tools reading Contacts and Calendar without user confirmation dialogs — the permission model is at the framework level (e.g., CNContactStore permissions), not at the tool-call level.

That said: document clearly that YOLO mode is for local development use, and that exposing it via `--serve` on non-localhost is the user's responsibility.

---

*Analysis based on Apple's official documentation, WWDC25 sessions, TN3193 tech note, Apple Developer Forums, Apple Hello Developer March 2026 newsletter, apple-fm-sdk GitHub repo, OpenAI API reference, Apple ML Research tech report, and the apfel project source as of March 26, 2026.*

---

## 12. The Killer App: `apfel pilot` — Your Mac as an AI-Controlled Instrument

### Why This Can Only Exist on Apple

Every cloud AI can read text and generate text. What makes Apple FM + apfel + macOS uniquely powerful is the combination of:

1. **AppleScript / `osascript`** — can control ANY scriptable Mac application (Safari, Mail, Calendar, Finder, Terminal, Music, Notes, Pages, Numbers, Keynote, Xcode, Slack, Figma, Chrome, Spotify, VS Code... hundreds of apps)
2. **Private on-device frameworks** — Contacts, Calendar, HealthKit, Photos, MapKit, MusicKit — data that should never leave the device
3. **Shell access** — git, docker, brew, npm, python, curl, everything in your $PATH
4. **Zero latency, zero cost, zero cloud** — the model is already loaded, already running, already paid for
5. **Tool calling with constrained decoding** — the model CANNOT hallucinate tool names or produce malformed arguments

No cloud model can do this. ChatGPT can't read your Safari tabs. Claude can't check your Apple Calendar. Gemini can't control your Keynote. But apfel can — because it runs on your Mac, in your process, with your permissions.

### The Concept: `apfel pilot`

A single command that turns your Mac into an AI-controlled workspace. You describe what you want in natural language, and the model orchestrates your apps.

```bash
apfel pilot "Prepare my morning"
```

The model:
1. Calls `currentTime` → knows it's 8:14 AM Monday
2. Calls `getCalendarEvents` → sees "Standup 9:00, Client Call 11:00, Lunch with Ksenia 13:00"
3. Calls `runAppleScript` → opens Safari to your morning news sites
4. Calls `runCommand("open -a Mail")` → opens Mail
5. Calls `getUnreadEmails` → "3 unread: one from karriere.at, one from Red Bull, one from DER STANDARD"
6. Returns: "Good morning Franz. You have standup in 45 minutes, then a client call at 11. Three unread emails — one from karriere.at looks urgent (subject: 'Q2 SEO Retainer Renewal'). Lunch with Ksenia at 1. I've opened Safari and Mail for you."

All on-device. All private. Sub-second latency after warmup.

### The Tool Set That Makes It Work

```swift
// ════════════════════════════════════════════
// THE APPLE ECOSYSTEM BRIDGE
// ════════════════════════════════════════════

// This is the god tool. AppleScript can control ANY Mac app.
struct AppleScriptTool: Tool {
    let name = "runAppleScript"
    let description = "Execute AppleScript to control any Mac application."
    @Generable struct Arguments {
        @Guide(description: "AppleScript source code to execute")
        let script: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let script = NSAppleScript(source: arguments.script)!
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            return ToolOutput("Error: \(error)")
        }
        return ToolOutput(result.stringValue ?? "OK")
    }
}

// Calendar — what's on my schedule?
struct CalendarTool: Tool {
    let name = "getCalendarEvents"
    let description = "Get calendar events for today or a specific date."
    @Generable struct Arguments {
        @Guide(description: "Date in YYYY-MM-DD format, or 'today'")
        let date: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let store = EKEventStore()
        try await store.requestFullAccessToEvents()
        let calendar = Calendar.current
        let targetDate: Date = arguments.date == "today" 
            ? Date() 
            : ISO8601DateFormatter().date(from: arguments.date + "T00:00:00Z") ?? Date()
        let start = calendar.startOfDay(for: targetDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        let formatted = events.map { 
            "\($0.startDate.formatted(date: .omitted, time: .shortened)) - \($0.title ?? "Untitled")" 
        }
        return ToolOutput(formatted.joined(separator: "\n"))
    }
}

// Safari — what tabs are open? what's on screen?
struct SafariTabsTool: Tool {
    let name = "getSafariTabs"
    let description = "Get the URLs and titles of all open Safari tabs."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> ToolOutput {
        let script = NSAppleScript(source: """
            tell application "Safari"
                set tabList to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabList to tabList & name of t & " | " & URL of t & linefeed
                    end repeat
                end repeat
                return tabList
            end tell
        """)!
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return ToolOutput(result.stringValue ?? "No tabs")
    }
}

// Finder — what files am I working on?
struct RecentFilesTool: Tool {
    let name = "getRecentFiles"
    let description = "Get recently modified files in a directory."
    @Generable struct Arguments {
        @Guide(description: "Directory path") let path: String
        @Guide(description: "Number of files to return") let count: Int
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", 
            "find '\(arguments.path)' -type f -maxdepth 2 -mtime -1 | head -\(arguments.count)"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ToolOutput(String(data: data, encoding: .utf8) ?? "")
    }
}

// Git — what's the state of my project?
struct GitStatusTool: Tool {
    let name = "gitStatus"
    let description = "Get git status and recent commits for a repository."
    @Generable struct Arguments {
        @Guide(description: "Path to git repository") let repoPath: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
            cd '\(arguments.repoPath)' && \
            echo "=== STATUS ===" && git status --short && \
            echo "=== RECENT ===" && git log --oneline -5
        """]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ToolOutput(String(data: data, encoding: .utf8) ?? "")
    }
}

// Music — what's playing? play something
struct MusicControlTool: Tool {
    let name = "controlMusic"
    let description = "Control Apple Music: play, pause, get current track, or search."
    @Generable struct Arguments {
        @Guide(description: "Action to perform")
        let action: MusicAction
        @Generable enum MusicAction {
            case play
            case pause
            case currentTrack
            case nextTrack
        }
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let script: String
        switch arguments.action {
        case .play: script = "tell application \"Music\" to play"
        case .pause: script = "tell application \"Music\" to pause"
        case .nextTrack: script = "tell application \"Music\" to next track"
        case .currentTrack: 
            script = """
            tell application "Music"
                set trackName to name of current track
                set artistName to artist of current track
                return trackName & " by " & artistName
            end tell
            """
        }
        let appleScript = NSAppleScript(source: script)!
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return ToolOutput(result.stringValue ?? "Done")
    }
}

// Notifications — inform the user
struct NotifyTool: Tool {
    let name = "notify"
    let description = "Show a macOS notification."
    @Generable struct Arguments {
        @Guide(description: "Title") let title: String
        @Guide(description: "Message body") let body: String
    }
    func call(arguments: Arguments) async throws -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", 
            "display notification \"\(arguments.body)\" with title \"\(arguments.title)\""]
        try process.run()
        process.waitUntilExit()
        return ToolOutput("Notified: \(arguments.title)")
    }
}
```

### Real Scenarios

```bash
# ═══════════════════════════════════════
# MORNING ROUTINE
# ═══════════════════════════════════════
$ apfel pilot "What's my day look like?"
# → Reads calendar, checks unread mail count, gets weather
# → "You have 4 meetings today. First one at 9:00 (Standup).
#    12 unread emails. It's 7°C and cloudy in Vienna."

# ═══════════════════════════════════════
# DEVELOPER WORKFLOW  
# ═══════════════════════════════════════
$ apfel pilot "What did I work on yesterday?"
# → git log across ~/Projects/*, checks recently modified files
# → "You made 3 commits to FullStackOptimization/website (SEO audit fixes),
#    edited 2 files in apfel, and had 6 modified files in client-workshops."

$ apfel pilot "Summarize what's in my open Safari tabs"
# → Gets all tab URLs and titles via AppleScript
# → "You have 14 tabs open across 3 windows:
#    - Research: 5 tabs about Apple FoundationModels
#    - Client: 3 tabs on karriere.at analytics
#    - Personal: 2 surf forecast tabs (Taghazout), 
#      1 yoga schedule, 3 misc"

# ═══════════════════════════════════════
# PRESENTATION PREP
# ═══════════════════════════════════════
$ apfel pilot "Open Keynote with my latest workshop deck and start the presenter display"
# → Finds most recent .key file in ~/Workshops/
# → Opens it via AppleScript
# → Starts presenter mode
# → "Opened 'AI-First-Kickoff-2026.key'. Presenter display active."

# ═══════════════════════════════════════
# CONTEXT SWITCHING
# ═══════════════════════════════════════
$ apfel pilot "I'm done with client work. Close all karriere.at tabs, 
               open my personal project, play some music."
# → Closes specific Safari tabs via AppleScript
# → Opens ~/Projects/apfel in Terminal
# → Starts Apple Music playback
# → "Closed 3 karriere.at tabs. Opened apfel project in Terminal. 
#    Playing your recently added playlist."

# ═══════════════════════════════════════
# RESEARCH + CAPTURE
# ═══════════════════════════════════════
$ apfel pilot "Read my clipboard, find related articles online, 
               and save a summary to ~/Desktop/research-notes.md"
# → Reads clipboard (maybe a pasted URL or text)
# → Fetches related content via URLSession
# → Writes markdown file
# → "Saved 3-paragraph summary of 'GEO optimization strategies' 
#    to ~/Desktop/research-notes.md"

# ═══════════════════════════════════════
# META: THE AI DEBUGGING ITSELF
# ═══════════════════════════════════════
$ apfel pilot "Check if the apfel server is running on port 11434 
               and show me the last 5 requests from the logs"
# → curl localhost:11434/health
# → curl localhost:11434/v1/logs
# → Formats and returns results
```

### Why This Is Different From Everything Else

| Capability | ChatGPT | Claude Code | apfel pilot |
|---|---|---|---|
| Read your Calendar | ❌ | ❌ | ✅ EventKit |
| Control Safari tabs | ❌ | ❌ | ✅ AppleScript |
| Read Contacts | ❌ | ❌ | ✅ CNContactStore |
| Control Music | ❌ | ❌ | ✅ AppleScript |
| Read Health data | ❌ | ❌ | ✅ HealthKit |
| Run shell commands | ❌ | ✅ | ✅ Process |
| Read/write files | ❌ | ✅ | ✅ FileManager |
| Control ANY Mac app | ❌ | ❌ | ✅ AppleScript |
| Works offline | ❌ | ❌ | ✅ On-device |
| Zero cost per query | ❌ | ❌ | ✅ Free |
| Data leaves device | ✅ leaves | ✅ leaves | ❌ stays |
| Context window | 128K+ | 200K+ | 4,096 😬 |
| Model quality | ████████ | █████████ | ███ |

The tradeoff is clear: apfel pilot has garbage model quality and a tiny context window, but it has **total system access with total privacy**. The 3B model doesn't need to be brilliant — it just needs to understand "open my calendar" and call the right tool. That's exactly what Apple optimized it for.

### Token Budget for `pilot` Mode

The challenge: all these tools registered simultaneously:

```
CalendarTool:        ~70 tokens
SafariTabsTool:      ~40 tokens  
RecentFilesTool:     ~65 tokens
GitStatusTool:       ~60 tokens
MusicControlTool:    ~80 tokens  (enum costs more)
NotifyTool:          ~55 tokens
AppleScriptTool:     ~50 tokens
ReadFileTool:        ~60 tokens
RunCommandTool:      ~55 tokens
CurrentTimeTool:     ~30 tokens
FetchURLTool:        ~65 tokens
ClipboardReadTool:   ~35 tokens
WriteFileTool:       ~70 tokens
────────────────────────────────
TOTAL:              ~735 tokens (18% of budget)

Remaining for prompt + response: ~3,361 tokens
System prompt for pilot mode:     ~200 tokens
────────────────────────────────
Available for user + response:  ~3,161 tokens (~2,300 words)
```

That's tight but workable for single-turn commands. The lazy tool injection strategy from Section 11 becomes essential here — register only the 3-4 tools the prompt needs.

### The Existing Library: FoundationModelsTools

There's already an open-source Swift package that provides pre-built tools for EventKit, Contacts, HealthKit, CoreLocation, MapKit, and MusicKit:

**[FoundationModelsTools](https://github.com/rryam/FoundationModelsKit)** by Rudrank Riyam

Apfel should either depend on this package or port its tool implementations. It also includes token counting and context window management utilities — exactly what apfel needs.

### Implementation Path

1. **Phase 1**: Ship `--yolo` with filesystem + shell tools (Section 11)
2. **Phase 2**: Add AppleScript bridge tool (the god tool — controls everything)
3. **Phase 3**: Add native Apple framework tools (Calendar, Contacts, Music) via FoundationModelsTools
4. **Phase 4**: Ship `apfel pilot` as the polished, opinionated agent mode with smart tool selection and natural language Mac control

Phase 2 is the highest leverage. A single AppleScript tool lets the model control Mail, Safari, Keynote, Numbers, Pages, Music, Finder, Terminal, Messages, Notes, Reminders, and literally any app with a scripting dictionary. You don't need 50 individual tools — you need one tool that speaks AppleScript, and a model smart enough to generate the right script.

The 3B model's AppleScript generation quality will be the bottleneck. But with good system prompts and a few-shot examples in the instructions, it should handle common patterns. And the 26.4 model update specifically improved instruction following — test it.

---

*Analysis based on Apple's official documentation, WWDC25 sessions, TN3193 tech note, Apple Developer Forums, Apple Hello Developer March 2026 newsletter, apple-fm-sdk GitHub repo, FoundationModelsTools, OpenAI API reference, Apple ML Research tech report, and the apfel project source as of March 26, 2026.*