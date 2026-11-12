import Foundation
import Testing
@testable import ReminiCareKit

@Suite struct KeyWorkerTests {
    @Test func keepsOnlyDistributedNonEmptyKeys() async throws {
        let http = FakeHTTP { request in
            #expect(request.url?.absoluteString == "https://keys.example/v1/keys")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            return (200, #"{"keys":{"NCKU_STT_TOKEN":" stt ","OPENAI_API_KEY":"sk-x","NCKU_TTS_TOKEN":""}}"#)
        }
        let keys = try await KeyWorker.fetch(baseURL: "https://keys.example", token: "token", http: http)
        #expect(keys == ["NCKU_STT_TOKEN": "stt"])
    }

    @Test func distributedKeysAreStoredAsSecrets() {
        #expect(KeyWorker.distributed.isSubset(of: ConfigStore.secretKeys))
        #expect(ConfigStore.secretKeys.contains(ConfigKey.keyWorkerToken))
    }

    @Test func mapsFailures() async {
        for (status, expected) in [(401, KeyWorker.Failure.unauthorized), (429, .rateLimited), (500, .server(500))] {
            await #expect(throws: expected) {
                try await KeyWorker.fetch(baseURL: "https://keys.example", token: "t", http: FakeHTTP { _ in (status, "{}") })
            }
        }
        await #expect(throws: KeyWorker.Failure.invalidResponse) {
            try await KeyWorker.fetch(baseURL: "https://keys.example", token: "t", http: FakeHTTP { _ in (200, "nope") })
        }
        await #expect(throws: KeyWorker.Failure.notConfigured) {
            try await KeyWorker.fetch(baseURL: "https://keys.example", token: " ", http: FakeHTTP { _ in (200, "{}") })
        }
    }

    @Test func refreshOverwritesSavedKeysOnlyWhenEnabled() async {
        let config = ConfigStore(values: [
            ConfigKey.keyWorkerEnabled: "false", ConfigKey.keyWorkerURL: "https://keys.example",
            ConfigKey.keyWorkerToken: "t", "NCKU_STT_TOKEN": "typed",
        ])
        let http = FakeHTTP { _ in (200, #"{"keys":{"NCKU_STT_TOKEN":"from-worker"}}"#) }
        #expect(await KeyWorker.refresh(config: config, http: http) == nil)
        #expect(config.value("NCKU_STT_TOKEN") == "typed")

        try? config.save([ConfigKey.keyWorkerEnabled: "true"])
        #expect(await KeyWorker.refresh(config: config, http: http) == 1)
        #expect(config.value("NCKU_STT_TOKEN") == "from-worker")

        // Worker down: the saved key stays.
        #expect(await KeyWorker.refresh(config: config, http: FakeHTTP { _ in (503, "") }) == nil)
        #expect(config.value("NCKU_STT_TOKEN") == "from-worker")
    }
}

@Suite struct LlmModelListTests {
    @Test func listsSortedUniqueIdsWithoutGeminiPrefix() async throws {
        let http = FakeHTTP { request in
            #expect(request.url?.absoluteString == "https://api.example/v1/models")
            return (200, #"{"data":[{"id":"models/gemini-2.5-flash"},{"id":"b"},{"id":"a"},{"id":"b"}]}"#)
        }
        let ids = try await LlmModelList.fetch(baseURL: "https://api.example/v1", apiKey: "k", http: http)
        #expect(ids == ["a", "b", "gemini-2.5-flash"])
    }

    @Test func mapsFailures() async {
        await #expect(throws: LlmModelList.Failure.invalidKey) {
            try await LlmModelList.fetch(baseURL: "https://api.example/v1", apiKey: "k", http: FakeHTTP { _ in (401, "") })
        }
        await #expect(throws: LlmModelList.Failure.notConfigured) {
            try await LlmModelList.fetch(baseURL: "https://api.example/v1", apiKey: "", http: FakeHTTP { _ in (200, "") })
        }
    }
}
