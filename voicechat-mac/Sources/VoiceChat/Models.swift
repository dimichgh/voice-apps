import Foundation

enum Role: String, Codable {
    case system, user, assistant, tool
}

struct ToolCall: Codable, Identifiable, Hashable {
    let id: String
    let type: String           // "function"
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable, Hashable {
    let name: String
    let arguments: String      // JSON-encoded string per OpenAI spec
}

struct Message: Identifiable, Hashable {
    var localID = UUID()
    var role: Role
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var name: String?

    var id: UUID { localID }
}

// Wire-format encoding/decoding — manual so we can omit nil fields cleanly.
extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

struct Tool: Encodable {
    let type: String           // "function"
    let function: ToolFunction
}

struct ToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONSchema
}

struct JSONSchema: Encodable {
    let type: String           // typically "object"
    let properties: [String: JSONSchemaProperty]
    let required: [String]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(type, forKey: DynamicKey(stringValue: "type")!)
        // Always emit `properties: {}` even when empty — OpenAI / Qwen tool spec
        // expects this. JSONEncoder writes [:] as {}.
        try c.encode(properties, forKey: DynamicKey(stringValue: "properties")!)
        if !required.isEmpty {
            try c.encode(required, forKey: DynamicKey(stringValue: "required")!)
        }
    }
}

struct JSONSchemaProperty: Encodable {
    let type: String
    let description: String?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let tools: [Tool]?
    let stream: Bool
    let temperature: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(model, forKey: DynamicKey(stringValue: "model")!)
        try c.encode(messages, forKey: DynamicKey(stringValue: "messages")!)
        if let tools, !tools.isEmpty {
            try c.encode(tools, forKey: DynamicKey(stringValue: "tools")!)
        }
        try c.encode(stream, forKey: DynamicKey(stringValue: "stream")!)
        if let temperature {
            try c.encode(temperature, forKey: DynamicKey(stringValue: "temperature")!)
        }
    }
}

struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
    let usage: UsageInfo?
}

struct UsageInfo: Decodable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

struct AudioTranscriptionResponse: Decodable {
    let text: String
}
