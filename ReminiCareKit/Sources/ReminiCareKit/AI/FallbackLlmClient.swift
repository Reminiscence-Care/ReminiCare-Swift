import Foundation

/// Tries each language model in turn: the one chosen in settings first, then
/// every other preset that has a key. A free model that is rate limited, out of
/// quota, slow or down no longer stops the conversation.
public struct FallbackLlmClient: LlmClient {
    public struct Entry: Sendable {
        public let providerId: String
        public let client: LlmClient
        public init(providerId: String, client: LlmClient) {
            self.providerId = providerId
            self.client = client
        }
    }

    public let entries: [Entry]

    public init(_ entries: [Entry]) { self.entries = entries }

    /// Backup order after the chosen provider.
    public static let backupOrder = ["groq", "nvidia", "gemini", "openai"]

    /// Errors another provider might not have. Only a cancel stops the chain.
    static func shouldFallBack(_ error: Error) -> Bool {
        guard let error = error as? AIServiceError else { return false }
        return error.kind != .cancelled
    }

    public func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
        var firstError: Error?
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                try Task.checkCancellation()
                AppLog.shared.record(.llm, .warning, detail: "llmFallback_\(entry.providerId)")
            }
            do {
                return try await entry.client.complete(
                    messages: messages, temperature: temperature, maxTokens: maxTokens, jsonObject: jsonObject
                )
            } catch {
                guard Self.shouldFallBack(error) else { throw error }
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? AIServiceError(.configuration, "尚未設定語言模型。")
    }
}
