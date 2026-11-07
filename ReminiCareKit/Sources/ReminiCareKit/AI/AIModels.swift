import Foundation

public enum AIErrorKind: String, Sendable {
    case authentication, billing, rateLimit, timeout, network, invalidResponse, unsupportedCapability, configuration, cancelled
}

public struct AIServiceError: Error, Sendable, LocalizedError {
    public let kind: AIErrorKind
    public let message: String
    public var statusCode: Int?
    public init(_ kind: AIErrorKind, _ message: String, statusCode: Int? = nil) {
        self.kind = kind
        self.message = message
        self.statusCode = statusCode
    }
    public var errorDescription: String? { message }
}

/// Whitelisted App Log code for any error.
public func logDetail(_ error: Error) -> String {
    switch error {
    case let error as AIServiceError: error.kind.rawValue
    case let error as SttError: error.kind.rawValue
    case is TimeoutError: "timeout"
    case is CancellationError: "cancelled"
    case is KeychainError: "keychain"
    case let error as URLError: error.code == .cancelled ? "cancelled" : error.code == .timedOut ? "timeout" : "network"
    default: "unexpected"
    }
}

public enum ProviderCapability: Sendable { case textGeneration, imageGeneration, imageEditing }

public struct LlmProviderConfig: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var model: String
    public var apiKeyReference: String
    public var timeout: Duration = .seconds(60)
    public var isCustom = false
}

public struct ImageProviderConfig: Sendable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var generationModel: String
    public var editModel: String?
    public var apiKeyReference: String
    public var capabilities: Set<ProviderCapability>
    public var timeout: Duration = .seconds(180)
    public var isCustom = false
    public func supports(_ capability: ProviderCapability) -> Bool { capabilities.contains(capability) }
}

public struct LlmMessage: Sendable, Hashable {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }
}

public enum ProviderRegistry {
    public static let llmPresets: [String: LlmProviderConfig] = [
        "nvidia": LlmProviderConfig(id: "nvidia", displayName: "NVIDIA", baseURL: "https://integrate.api.nvidia.com/v1", model: "deepseek-ai/deepseek-v4.1-flash", apiKeyReference: "NVIDIA_API_KEY"),
        "openai": LlmProviderConfig(id: "openai", displayName: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKeyReference: "OPENAI_API_KEY"),
        "gemini": LlmProviderConfig(id: "gemini", displayName: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash", apiKeyReference: "GEMINI_API_KEY"),
    ]

    public static let imagePresets: [String: ImageProviderConfig] = [
        "cloudflare": ImageProviderConfig(id: "cloudflare", displayName: "Cloudflare Workers AI", baseURL: "https://reminicare-image-api.hding49.workers.dev", generationModel: "@cf/black-forest-labs/flux-2-klein-4b", editModel: "@cf/black-forest-labs/flux-2-klein-4b", apiKeyReference: "CLOUDFLARE_IMAGE_APP_TOKEN", capabilities: [.imageGeneration, .imageEditing]),
        "siliconflow": ImageProviderConfig(id: "siliconflow", displayName: "SiliconFlow", baseURL: "https://api.siliconflow.com/v1", generationModel: "Qwen/Qwen-Image", editModel: "Qwen/Qwen-Image-Edit", apiKeyReference: "SILICONFLOW_API_KEY", capabilities: [.imageGeneration, .imageEditing]),
        "openai": ImageProviderConfig(id: "openai", displayName: "OpenAI", baseURL: "https://api.openai.com/v1", generationModel: "gpt-image-2", apiKeyReference: "OPENAI_API_KEY", capabilities: [.imageGeneration]),
    ]
}

// MARK: - Response parsing

public enum ProviderResponseParser {
    /// Final answer text from an OpenAI-compatible chat response; reasoning is ignored.
    public static func messageText(_ decoded: Any) -> String? {
        guard let object = decoded as? [String: Any] else { return nil }
        if let choices = object["choices"] as? [Any], let first = choices.first as? [String: Any] {
            if let message = first["message"] as? [String: Any], let content = contentText(message["content"]) {
                return content
            }
            if let text = contentText(first["text"]) { return text }
        }
        return contentText(object["output_text"])
    }

    /// The last complete JSON object in `text` that contains `requiredKey`.
    public static func decodeJSONObject(_ text: String, requiredKey: String? = nil) throws -> [String: Any] {
        for candidate in balancedObjects(text).reversed() {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if requiredKey == nil || object[requiredKey!] != nil { return object }
        }
        throw AIServiceError(.invalidResponse, "找不到完整的 JSON object")
    }

    private static func contentText(_ value: Any?) -> String? {
        if let string = value as? String {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let list = value as? [Any] {
            let parts = list.compactMap { part -> String? in
                if let string = part as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let map = part as? [String: Any], let text = (map["text"] ?? map["content"]) as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    private static func balancedObjects(_ text: String) -> [String] {
        var result: [String] = []
        let scalars = Array(text.unicodeScalars)
        var start = -1, depth = 0
        var inString = false, escaped = false
        for (index, scalar) in scalars.enumerated() {
            if inString {
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            if scalar == "\"" && depth > 0 {
                inString = true
            } else if scalar == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if scalar == "}" && depth > 0 {
                depth -= 1
                if depth == 0 && start >= 0 {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[start...index])
                    result.append(String(view))
                    start = -1
                }
            }
        }
        return result
    }

    /// Short provider error message from a JSON error body, prefixed with a space.
    static func errorDetail(_ data: Data) -> String {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let message: String?
        if let error = decoded["error"] as? [String: Any] {
            message = error["message"] as? String
        } else if let error = decoded["error"] {
            message = "\(error)"
        } else {
            message = decoded["message"] as? String
        }
        guard let message else { return "" }
        let compact = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? "" : " " + String(compact.prefix(240))
    }
}
