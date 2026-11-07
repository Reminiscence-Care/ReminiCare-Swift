import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Logs a failed image operation with its reason, then rethrows.
func loggedImageWork(edit: Bool, _ work: () async throws -> URL) async throws -> URL {
    do {
        return try await work()
    } catch {
        let detail = error is CocoaError ? "imageSave" : logDetail(error)
        AppLog.shared.record(.image, .failed, statusCode: (error as? AIServiceError)?.statusCode, detail: detail)
        if edit { AppLog.shared.record(.image, .warning, detail: "imageEdit") }
        throw error
    }
}

public protocol ImageGenerating: Sendable {
    var config: ImageProviderConfig { get }
    /// Returns the saved local file URL.
    func generate(prompt: String) async throws -> URL
    func edit(image: URL, instruction: String) async throws -> URL
}

public enum NostalgicImagePrompt {
    public static func build(scene: String, era: String = "1960s-1980s", location: String = "Taiwan") -> String {
        "Create a landscape, photorealistic documentary photograph set in "
            + "\(era) \(location). Depict the scene as a specific lived memory, with "
            + "historically accurate Taiwanese faces, clothing, architecture, tools, "
            + "vehicles, food and household objects for that era. Use natural candid "
            + "expressions, gentle daylight, realistic skin texture and warm, subtly "
            + "faded film colors. Avoid modern objects, modern buildings, staged poses, "
            + "generic Chinese scenery, captions, legible signs, logos and watermarks. "
            + "Keep the important people and objects away from the image edges. "
            + "Scene: \(scene)"
    }

    public static func buildEdit(instruction: String) -> String {
        "Edit input image 0 according to this requested correction: \(instruction). "
            + "Preserve the same people, recognizable faces, number of people, camera "
            + "angle, composition, lighting, Taiwanese location and historical era. "
            + "Change only what the correction requires. Keep a photorealistic "
            + "documentary appearance and do not add text, logos or watermarks."
    }
}

/// Saves generated images under Documents/reminicare_images.
public struct LocalImageStore: Sendable {
    public let root: URL
    public init(root: URL = URL.documentsDirectory) { self.root = root }
    public var directory: URL { root.appending(path: "reminicare_images", directoryHint: .isDirectory) }

    public func save(_ data: Data, prefix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "png"
        let micros = Int(Date().timeIntervalSince1970 * 1_000_000)
        let url = directory.appending(path: "\(prefix)_\(micros).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Shrinks an image to at most 504 px on the long edge as JPEG for edit uploads.
public enum ImagePreprocessor {
    public static func prepare(_ url: URL, maximumEdge: Int = 504) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AIServiceError(.configuration, "找不到要修改的原始圖片。")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { throw AIServiceError(.invalidResponse, "無法讀取要修改的原始圖片。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AIServiceError(.invalidResponse, "無法讀取要修改的原始圖片。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIServiceError(.invalidResponse, "無法讀取要修改的原始圖片。") }
        return output as Data
    }
}

public struct CloudflareWorkerImageClient: ImageGenerating {
    public let config: ImageProviderConfig
    public let appToken: String
    private let transport: HTTPTransport
    private let store: LocalImageStore

    public init(config: ImageProviderConfig, appToken: String, client: HTTPSending = URLSession.shared, store: LocalImageStore = LocalImageStore()) {
        self.config = config
        self.appToken = appToken
        self.store = store
        transport = HTTPTransport(client: client, timeout: config.timeout, area: .image)
    }

    public func generate(prompt: String) async throws -> URL {
        try await loggedImageWork(edit: false) { try await request("generations", ["prompt": prompt, "width": 1024, "height": 640], prefix: "generated") }
    }

    public func edit(image: URL, instruction: String) async throws -> URL {
        try await loggedImageWork(edit: true) { try await performEdit(image: image, instruction: instruction) }
    }

    private func performEdit(image: URL, instruction: String) async throws -> URL {
        guard config.supports(.imageEditing) else {
            throw AIServiceError(.unsupportedCapability, "目前的生圖 Provider 不支援原圖編輯。")
        }
        let prepared = try ImagePreprocessor.prepare(image)
        return try await request("edits", [
            "prompt": NostalgicImagePrompt.buildEdit(instruction: instruction),
            "imageBase64": prepared.base64EncodedString(),
            "imageMimeType": "image/jpeg",
            "width": 1024,
            "height": 640,
        ], prefix: "edited")
    }

    private func request(_ endpoint: String, _ payload: [String: Any], prefix: String) async throws -> URL {
        let base = trimmedBase(config.baseURL)
        guard let baseURL = URL(string: base), baseURL.scheme == "https", !(baseURL.host ?? "").isEmpty,
              let url = URL(string: "\(base)/v1/images/\(endpoint)")
        else { throw AIServiceError(.configuration, "Cloudflare Worker URL 必須是有效的 HTTPS 網址。") }
        guard !appToken.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIServiceError(.configuration, "尚未設定 Cloudflare Image App Token。")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(HTTPTransport.jsonRequest(url, bearer: appToken, body: payload))
        } catch is TimeoutError {
            throw AIServiceError(.timeout, "Cloudflare 生圖請求逾時。")
        } catch where isCancellation(error) {
            throw CancellationError()
        } catch {
            throw AIServiceError(.network, "Cloudflare 生圖連線失敗：\(error.localizedDescription)")
        }
        switch response.statusCode {
        case 401, 403:
            throw AIServiceError(.authentication, "Cloudflare Image App Token 無效。", statusCode: response.statusCode)
        case 429:
            throw AIServiceError(.rateLimit, "Cloudflare 生圖請求過於頻繁或今日額度已達限制；可稍後重試，或到設定頁手動切換 Provider。", statusCode: 429)
        case 200..<300:
            break
        default:
            var detail = ""
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = (object["error"] as? [String: Any])?["message"] as? String, !message.isEmpty {
                detail = " \(message)"
            }
            throw AIServiceError(.network, "Cloudflare 生圖服務回傳 HTTP \(response.statusCode)。\(detail)", statusCode: response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = ((object["data"] as? [[String: Any]])?.first?["b64_json"]) as? String, !encoded.isEmpty
        else { throw AIServiceError(.invalidResponse, "Cloudflare 生圖服務沒有回傳圖片資料。") }
        guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
            throw AIServiceError(.invalidResponse, "Cloudflare 生圖服務回傳的圖片格式不正確。")
        }
        return try store.save(bytes, prefix: prefix)
    }
}

public struct OpenAICompatibleImageClient: ImageGenerating {
    public let config: ImageProviderConfig
    public let apiKey: String
    private let transport: HTTPTransport
    private let store: LocalImageStore

    public init(config: ImageProviderConfig, apiKey: String, client: HTTPSending = URLSession.shared, store: LocalImageStore = LocalImageStore()) {
        self.config = config
        self.apiKey = apiKey
        self.store = store
        transport = HTTPTransport(client: client, timeout: config.timeout, area: .image)
    }

    public func generate(prompt: String) async throws -> URL {
        try await loggedImageWork(edit: false) { try await request(["model": config.generationModel, "prompt": prompt, "n": 1, "size": "1024x1024"], prefix: "generated") }
    }

    public func edit(image: URL, instruction: String) async throws -> URL {
        try await loggedImageWork(edit: true) { try await performEdit(image: image, instruction: instruction) }
    }

    private func performEdit(image: URL, instruction: String) async throws -> URL {
        guard config.supports(.imageEditing), let model = config.editModel else {
            throw AIServiceError(.unsupportedCapability, "目前的生圖 Provider 不支援原圖編輯。")
        }
        guard let data = try? Data(contentsOf: image) else {
            throw AIServiceError(.configuration, "找不到要修改的原始圖片。")
        }
        return try await request([
            "model": model,
            "prompt": instruction,
            "image": "data:image/png;base64,\(data.base64EncodedString())",
            "size": "1024x1024",
        ], prefix: "edited")
    }

    private func request(_ payload: [String: Any], prefix: String) async throws -> URL {
        guard !apiKey.isEmpty else { throw AIServiceError(.configuration, "尚未設定生圖 API Key。") }
        guard let url = URL(string: trimmedBase(config.baseURL) + "/images/generations") else {
            throw AIServiceError(.configuration, "生圖 Base URL 格式不正確。")
        }
        do {
            let (data, response) = try await transport.send(HTTPTransport.jsonRequest(url, bearer: apiKey, body: payload))
            let detail = ProviderResponseParser.errorDetail(data)
            switch response.statusCode {
            case 401, 403: throw AIServiceError(.authentication, "生圖 API Key 無效。\(detail)", statusCode: response.statusCode)
            case 429: throw AIServiceError(.rateLimit, "生圖使用量已達限制。", statusCode: 429)
            case 402: throw AIServiceError(.billing, "生圖 Provider 餘額不足或付款設定未完成。\(detail)", statusCode: 402)
            case 200..<300: break
            default: throw AIServiceError(.network, "生圖 Provider 回傳 HTTP \(response.statusCode)。\(detail)", statusCode: response.statusCode)
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let item = ((object?["data"] ?? object?["images"]) as? [[String: Any]])?.first
            guard let item else { throw AIServiceError(.invalidResponse, "無法解析生圖 Provider 回應。") }
            if let b64 = item["b64_json"] as? String, !b64.isEmpty, let bytes = Data(base64Encoded: b64) {
                return try store.save(bytes, prefix: prefix)
            }
            guard let link = item["url"] as? String, let remote = URL(string: link) else {
                throw AIServiceError(.invalidResponse, "生圖回應沒有圖片資料。")
            }
            let (bytes, download) = try await transport.send(URLRequest(url: remote))
            guard (200..<300).contains(download.statusCode) else {
                throw AIServiceError(.network, "圖片下載失敗：HTTP \(download.statusCode)。")
            }
            return try store.save(bytes, prefix: prefix)
        } catch let error as AIServiceError {
            throw error
        } catch is TimeoutError {
            throw AIServiceError(.timeout, "生圖請求逾時。")
        } catch where isCancellation(error) {
            throw CancellationError()
        } catch {
            throw AIServiceError(.network, "生圖連線失敗：\(error.localizedDescription)")
        }
    }
}
