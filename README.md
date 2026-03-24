# apfel

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![FoundationModels](https://img.shields.io/badge/Apple-FoundationModels-8E8E93?logo=apple&logoColor=white)](https://developer.apple.com/documentation/foundationmodels)

> *German for "apple."*

**Apple Intelligence from the command line.**

A single-file Swift CLI that talks to Apple's language model via the [FoundationModels](https://developer.apple.com/documentation/foundationmodels) framework. No API keys. No dependencies. No cost. Runs on your Mac's Neural Engine.

```
$ apfel "What is the capital of Austria?"
The capital of Austria is Vienna.
```

---

## Why

macOS 26 ships with a built-in language model — the same one behind Writing Tools, Mail summaries, and Siri. Apple exposed it through the `FoundationModels` framework, but only for Swift apps with Xcode.

`apfel` puts that model on your command line. One binary. ~540 lines of well-documented Swift. ~150KB.

Most queries run on your Mac's Neural Engine with zero network traffic. For complex tasks, Apple's framework may route requests to [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/) — Apple's end-to-end encrypted server infrastructure where data is never stored, never logged, and never accessible to Apple. Either way: no API keys, no accounts, no cost.

## Install

```bash
git clone https://github.com/Arthur-Ficial/apfel.git
cd apfel
make install    # builds release binary → /usr/local/bin/apfel
```

<details>
<summary>Manual install / uninstall</summary>

```bash
# Build and copy manually
swift build -c release
sudo cp .build/release/apfel /usr/local/bin/

# Uninstall
make uninstall
# or: sudo rm /usr/local/bin/apfel
```

</details>

### Requirements

- **macOS 26** (Tahoe) or later
- **Swift 6.2+** command line tools (ships with Xcode 26)
- **Apple Intelligence** enabled in System Settings → Apple Intelligence & Siri

## Usage

### Ask a question

```bash
$ apfel "Translate to German: hello world"
Hallo Welt.
```

### Stream the response

```bash
$ apfel --stream "Write a haiku about the terminal"
Lines of code flow,
Silent terminal whispers low—
Stars in digital night.
```

### Interactive chat

```bash
$ apfel --chat
Apple Intelligence · on-device LLM · apfel v0.1.0
────────────────────────────────────────────────────────
Type 'quit' to exit.

you› What's the meaning of life?
 ai› That's a profound question...

you› quit
Goodbye.
```

### System prompts

```bash
$ apfel -s "Reply in exactly 5 words" "What is machine learning?"
Computers learning from data patterns.
```

### Code generation

```bash
$ apfel "Write a bubble sort in Python with type hints"
def bubble_sort(arr: list[int]) -> list[int]:
    n = len(arr)
    for i in range(n):
        swapped = False
        for j in range(0, n - i - 1):
            if arr[j] > arr[j + 1]:
                arr[j], arr[j + 1] = arr[j + 1], arr[j]
                swapped = True
        if not swapped:
            break
    return arr
```

### Text transformation

```bash
$ apfel -s "Respond with only the converted text" "Convert to uppercase: hello world"
HELLO WORLD
```

### Developer jokes

```bash
$ apfel -s "One sentence only" "Tell a developer joke"
Why don't programmers trust atoms? Because they make up everything!
```

### Pipe from stdin

```bash
$ echo "Explain quantum computing to a 5 year old" | apfel
Quantum computing is like having a super smart calculator that can
do lots of math really fast by using special tricks with tiny
particles instead of regular ones.

$ cat essay.txt | apfel -s "Summarize in 3 bullet points"
```

### JSON output

```bash
$ apfel -o json "Translate to German: hello world"
{
  "content" : "Hallo Welt.",
  "metadata" : {
    "on_device" : true,
    "version" : "0.1.0"
  },
  "model" : "apple-foundationmodel"
}
```

Pipe to `jq` for scripting:

```bash
$ apfel -o json "What is 2+2?" | jq -r .content
2 + 2 equals 4.
```

In chat mode, JSON output uses [JSONL](https://jsonlines.org) (one object per line):

```bash
$ apfel -o json --chat
{"content":"What is 2+2?","role":"user"}
{"content":"4.","model":"apple-foundationmodel","role":"assistant"}
```

### Compose with other tools

```bash
# Translate a file
cat README.md | apfel -s "Translate to German" > README.de.md

# Generate commit messages
git diff --staged | apfel -s "Write a concise commit message for this diff"

# Batch process
cat questions.txt | while read -r q; do apfel -o json "$q"; done > answers.jsonl

# Quick lookup in a script
capital=$(apfel -q "Capital of France? One word only.")
echo "The capital is $capital"
```

## Options

```
apfel [OPTIONS] <prompt>       Send a single prompt
apfel --chat                   Interactive conversation
apfel --stream <prompt>        Stream the response in real-time

OPTIONS:
  -s, --system <text>     Set a system prompt to guide the model
  -o, --output <format>   Output format: plain, json [default: plain]
  -q, --quiet             Suppress headers, prompts, and other chrome
      --no-color           Disable ANSI color codes in output
  -h, --help              Show help
  -v, --version           Print version

ENVIRONMENT:
  NO_COLOR                Disable colored output (https://no-color.org)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Runtime error (model unavailable, inference failed) |
| `2` | Usage error (invalid arguments, missing prompt) |
| `130` | Interrupted (Ctrl+C) |

## How It Works

`apfel` calls Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels) framework, introduced in macOS 26 ([WWDC 2025](https://developer.apple.com/videos/play/wwdc2025/286/)). The framework provides access to the language model that powers Apple Intelligence features like Writing Tools, Mail summaries, and Siri.

### On-device vs. Private Cloud Compute

Apple Intelligence uses a **hybrid architecture**:

- **On-device model (~3B parameters):** Runs on the Mac's Neural Engine. Handles most common tasks. No network traffic. Fully offline-capable.
- **Private Cloud Compute:** For complex tasks that exceed the on-device model's capacity, Apple's framework may route requests to [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/) (PCC) servers. PCC uses custom Apple silicon with a hardened OS. Data is encrypted end-to-end, processed statelessly (immediately deleted), and is never accessible to Apple or stored in logs. The [full production code is published](https://security.apple.com/blog/private-cloud-compute/) for independent security audits.

The routing is automatic and transparent — `apfel` (and you) don't control which path is taken. What's guaranteed: **no API keys, no accounts, no cost, and Apple's privacy guarantees either way.**

### Architecture

```
┌──────────────────────────────────────────────────────┐
│  apfel CLI (this project)                            │
│  - Argument parsing, I/O, JSON formatting            │
├──────────────────────────────────────────────────────┤
│  FoundationModels.framework (Apple)                  │
│  - LanguageModelSession API                          │
│  - Streaming via AsyncSequence                       │
│  - Automatic on-device / PCC routing                 │
├──────────────────────────────────────────────────────┤
│  Apple Intelligence                                  │
│  - On-device: Neural Engine / GPU / CPU (~3B model)  │
│  - Cloud: Private Cloud Compute (encrypted, no logs) │
│  - Model bundled with macOS 26                       │
└──────────────────────────────────────────────────────┘
```

### What `apfel` is — and isn't

This is Apple's built-in model exposed as a Unix tool. It's fast, free, and private. It's useful for quick lookups, text transformation, code generation, translation, drafting, and scripting. It is not GPT-4 or Claude. Expect small-model behavior: good at following instructions, decent at common tasks, less good at complex multi-step reasoning or long-form generation. Think of it as `grep` for natural language — a Unix tool, not an oracle.

## Design Decisions

- **Zero dependencies.** No Swift ArgumentParser, no third-party packages. Just `FoundationModels` + `Foundation`. The binary is 149KB.
- **Single file.** ~540 lines of documented Swift. Easy to read, easy to fork, easy to understand.
- **Unix philosophy.** Text in, text out. Stdin works. Stdout is clean (errors go to stderr). JSON mode for machine consumption. Proper exit codes. `NO_COLOR` respected.
- **No config files.** No `~/.apfelrc`, no environment variables to set (besides `NO_COLOR`). It just works.

## FAQ

**Q: Does this work on Intel Macs?**
A: macOS 26 + Apple Intelligence requires Apple Silicon (M1 or later). Intel Macs don't have the Neural Engine.

**Q: Does this require Xcode?**
A: You need the Xcode 26 Command Line Tools (`xcode-select --install`). Full Xcode is not required.

**Q: Is this really private? Does data leave my Mac?**
A: Most requests run entirely on-device via the Neural Engine. For complex tasks, Apple's framework may route to [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/) — encrypted, stateless servers where data is never stored or logged. Apple publishes the [full server code](https://security.apple.com/blog/private-cloud-compute/) for independent audit. You can't control the routing, but either path has strong privacy guarantees.

**Q: Does this work offline?**
A: Yes, for tasks handled by the on-device model (~3B parameters). Complex tasks that would normally route to Private Cloud Compute will fail without network connectivity.

**Q: Can I use this in CI/CD?**
A: Only on macOS 26 runners with Apple Intelligence enabled. The model needs the hardware (Apple Silicon + Neural Engine).

**Q: How does this compare to `llm`, `ollama`, etc.?**
A: Those tools run third-party models you choose and download. `apfel` runs Apple's built-in model — no downloads, no setup, no GPU memory management, no model selection. The tradeoff: you get Apple's model (and only Apple's model).

**Q: Is the model any good?**
A: It's a small on-device model. It's great for quick tasks: translation, summarization, Q&A, text rewriting. It's not great for complex multi-step reasoning. Try it and see.

**Q: Why "apfel"?**
A: It's German for "apple." The author is Austrian.

## Building from Source

```bash
swift build            # debug build
swift build -c release # optimized release build (~149KB)
swift package clean    # clean build artifacts
```

## License

[MIT](LICENSE)

---

<sub>Built by [Arthur Ficial](https://github.com/Arthur-Ficial), an AI assistant created by [Franz Enzenhofer](https://www.fullstackoptimization.com). Yes, this CLI was built by an AI to talk to another AI. We live in interesting times.</sub>
