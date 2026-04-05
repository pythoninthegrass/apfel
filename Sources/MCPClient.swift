// ============================================================================
// MCPClient.swift - MCP server connection and tool execution
// Part of apfel - spawns MCP servers and manages tool calling
// ============================================================================

import Foundation
import Darwin
import ApfelCore

/// A connection to a single MCP server process (stdio transport).
final class MCPConnection: @unchecked Sendable {
    private static let startupTimeoutMilliseconds = 5_000
    private static let toolCallTimeoutMilliseconds = 5_000

    let path: String
    private(set) var tools: [OpenAITool]

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let lock = NSLock()
    private var nextId = 1

    init(path: String) async throws {
        self.path = path

        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.processError("MCP server not found: \(path)")
        }

        let proc = Process()
        let stdinP = Pipe()
        let stdoutP = Pipe()

        if path.hasSuffix(".py") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", path]
        } else {
            proc.executableURL = URL(fileURLWithPath: path)
        }
        proc.standardInput = stdinP
        proc.standardOutput = stdoutP
        proc.standardError = FileHandle.nullDevice

        self.process = proc
        self.stdinPipe = stdinP
        self.stdoutPipe = stdoutP
        self.tools = [] // placeholder, filled below

        try proc.run()

        do {
            // Initialize handshake
            let initResp = try sendAndReceive(
                MCPProtocol.initializeRequest(id: allocId()),
                timeoutMilliseconds: Self.startupTimeoutMilliseconds,
                operationDescription: "initialize"
            )
            let _ = try MCPProtocol.parseInitializeResponse(initResp)
            send(MCPProtocol.initializedNotification())

            // Discover tools
            let toolsResp = try sendAndReceive(
                MCPProtocol.toolsListRequest(id: allocId()),
                timeoutMilliseconds: Self.startupTimeoutMilliseconds,
                operationDescription: "tools/list"
            )
            self.tools = try MCPProtocol.parseToolsListResponse(toolsResp)
        } catch {
            if proc.isRunning {
                proc.terminate()
            }
            throw error
        }
    }

    func callTool(name: String, arguments: String) throws -> String {
        let resp: String
        do {
            resp = try sendAndReceive(
                MCPProtocol.toolsCallRequest(id: allocId(), name: name, arguments: arguments),
                timeoutMilliseconds: Self.toolCallTimeoutMilliseconds,
                operationDescription: "tool '\(name)'"
            )
        } catch {
            if case .timedOut = error as? MCPError {
                shutdown()
            }
            throw error
        }
        let result = try MCPProtocol.parseToolCallResponse(resp)
        if result.isError {
            throw MCPError.serverError("Tool '\(name)' failed: \(result.text)")
        }
        return result.text
    }

    func shutdown() {
        process.terminate()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Private

    private func allocId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func send(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func sendAndReceive(
        _ message: String,
        timeoutMilliseconds: Int,
        operationDescription: String
    ) throws -> String {
        send(message)
        var buffer = Data()
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().timeIntervalSinceReferenceDate + (Double(timeoutMilliseconds) / 1000.0)

        while true {
            let remainingMilliseconds = Int((deadline - Date().timeIntervalSinceReferenceDate) * 1000.0)
            if remainingMilliseconds <= 0 {
                throw MCPError.timedOut("\(operationDescription.capitalized) timed out after \(timeoutMilliseconds / 1000)s")
            }

            var pollDescriptor = pollfd(fd: Int32(fd), events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remainingMilliseconds))
            if ready == 0 {
                throw MCPError.timedOut("\(operationDescription.capitalized) timed out after \(timeoutMilliseconds / 1000)s")
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw MCPError.processError("Failed waiting for MCP response: \(String(cString: strerror(errno)))")
            }
            if (pollDescriptor.revents & Int16(POLLNVAL)) != 0 {
                throw MCPError.processError("MCP stdout became invalid")
            }
            if (pollDescriptor.revents & Int16(POLLERR)) != 0 {
                throw MCPError.processError("MCP stdout reported an I/O error")
            }
            if (pollDescriptor.revents & Int16(POLLHUP)) != 0 && (pollDescriptor.revents & Int16(POLLIN)) == 0 {
                throw MCPError.processError("MCP server closed unexpectedly")
            }
            if (pollDescriptor.revents & Int16(POLLIN)) == 0 {
                continue
            }

            var byte: UInt8 = 0
            let readCount = Darwin.read(fd, &byte, 1)
            if readCount == 0 {
                throw MCPError.processError("MCP server closed unexpectedly")
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw MCPError.processError("Failed reading MCP response: \(String(cString: strerror(errno)))")
            }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(&byte, count: 1)
        }
        guard let line = String(data: buffer, encoding: .utf8), !line.isEmpty else {
            throw MCPError.processError("Empty response from MCP server")
        }
        return line
    }
}

/// Manages multiple MCP server connections and routes tool calls.
actor MCPManager {
    private var connections: [MCPConnection] = []
    private var toolMap: [String: MCPConnection] = [:]

    init(paths: [String]) async throws {
        for path in paths {
            let absPath: String
            if path.hasPrefix("/") {
                absPath = path
            } else {
                absPath = FileManager.default.currentDirectoryPath + "/" + path
            }
            let conn = try await MCPConnection(path: absPath)
            connections.append(conn)
            for tool in conn.tools {
                toolMap[tool.function.name] = conn
            }
            printStderr("\(styled("mcp:", .cyan)) \(conn.path) - \(conn.tools.map(\.function.name).joined(separator: ", "))")
        }
    }

    func allTools() -> [OpenAITool] {
        connections.flatMap(\.tools)
    }

    func execute(name: String, arguments: String) throws -> String {
        guard let conn = toolMap[name] else {
            throw MCPError.toolNotFound("No MCP server provides tool '\(name)'")
        }
        return try conn.callTool(name: name, arguments: arguments)
    }

    func shutdown() {
        for conn in connections {
            conn.shutdown()
        }
    }
}
