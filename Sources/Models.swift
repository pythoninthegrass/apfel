// ============================================================================
// Models.swift — Data types for CLI, server, and OpenAI API responses
// ============================================================================

import Foundation
import ApfelCore

// MARK: - CLI Response Types

struct ApfelResponse: Encodable {
    let model: String
    let content: String
    let metadata: Metadata
    struct Metadata: Encodable {
        let onDevice: Bool
        let version: String
        enum CodingKeys: String, CodingKey { case onDevice = "on_device"; case version }
    }
}

struct ChatMessage: Encodable {
    let role: String
    let content: String
    let model: String?
}

// MARK: - OpenAI Response

struct ChatCompletionResponse: Encodable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Encodable, Sendable {
        let index: Int
        let message: OpenAIMessage
        let finish_reason: String    // "stop" | "tool_calls" | "length" | "content_filter"
    }
    struct Usage: Encodable, Sendable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

// MARK: - OpenAI Streaming Chunk

struct ChatCompletionChunk: Encodable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChunkChoice]
    let usage: ChunkUsage?

    struct ChunkChoice: Encodable, Sendable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }
    struct Delta: Encodable, Sendable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCallDelta]?
    }
    struct ToolCallDelta: Encodable, Sendable {
        let index: Int
        let id: String?
        let type: String?
        let function: ToolCallFunction?
    }
    struct ChunkUsage: Encodable, Sendable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

// MARK: - OpenAI Error

struct OpenAIErrorResponse: Encodable, Sendable {
    let error: ErrorDetail
    struct ErrorDetail: Encodable, Sendable {
        let message: String
        let type: String
        let param: String?
        let code: String?
    }
}

// MARK: - Models List

struct ModelsListResponse: Encodable, Sendable {
    let object: String
    let data: [ModelObject]

    struct ModelObject: Encodable, Sendable {
        let id: String
        let object: String
        let created: Int
        let owned_by: String
        let context_window: Int
        let supported_parameters: [String]
        let unsupported_parameters: [String]
        let notes: String
    }
}

// Token counting is handled by TokenCounter.swift (real API: see open-tickets/TICKET-001).
