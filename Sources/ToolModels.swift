// ============================================================================
// ToolModels.swift — OpenAI tool calling types
// ============================================================================

import Foundation

struct OpenAITool: Decodable, Sendable {
    let type: String          // "function"
    let function: OpenAIFunction
}

struct OpenAIFunction: Decodable, Sendable {
    let name: String
    let description: String?
    let parameters: RawJSON?  // JSON schema stored as raw string
}

/// Stores arbitrary JSON as a raw string — used for tool parameter schemas.
struct RawJSON: Decodable, Sendable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(AnyCodable.self)
        let data = try JSONEncoder().encode(raw)
        value = String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String            // "function"
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String       // JSON-encoded string, as OpenAI specifies
}

enum ToolChoice: Decodable, Sendable {
    case auto, none, required
    case specific(name: String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            switch s {
            case "none":     self = .none
            case "required": self = .required
            default:         self = .auto
            }
            return
        }
        struct Specific: Decodable { struct Fn: Decodable { let name: String }; let function: Fn }
        if let obj = try? c.decode(Specific.self) { self = .specific(name: obj.function.name); return }
        self = .auto
    }
}

struct ResponseFormat: Decodable, Sendable {
    let type: String    // "text" or "json_object"
}

// MARK: - Type-erased Codable for raw JSON schemas

struct AnyCodable: Codable, Sendable {
    let value: (any Sendable)?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                       { value = nil; return }
        if let v = try? c.decode(Bool.self)                    { value = v; return }
        if let v = try? c.decode(Int.self)                     { value = v; return }
        if let v = try? c.decode(Double.self)                  { value = v; return }
        if let v = try? c.decode(String.self)                  { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self)    { value = v; return }
        if let v = try? c.decode([AnyCodable].self)            { value = v; return }
        value = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        guard let value else { try c.encodeNil(); return }
        switch value {
        case let v as Bool:                 try c.encode(v)
        case let v as Int:                  try c.encode(v)
        case let v as Double:              try c.encode(v)
        case let v as String:              try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]:        try c.encode(v)
        default:                            try c.encodeNil()
        }
    }
}
