import Combine
import Foundation

public enum LogArea: String, Sendable, CaseIterable {
    case app, flow, recording, stt, tts, ai, llm, image, settings, history, cache
}

public enum LogEvent: String, Sendable {
    case started, completed, failed, cancelled, progress, stageChanged, warning
    case recordingStopped, requestStarted, requestCompleted, requestFailed
    case cacheHit, saving, saved, cleared, frameworkError
    case transcription, partialTranscription

    var label: String {
        switch self {
        case .started: "開始"
        case .completed: "完成"
        case .failed: "失敗"
        case .cancelled: "取消"
        case .progress: "進度"
        case .stageChanged: "切換階段"
        case .warning: "警告"
        case .recordingStopped: "錄音停止"
        case .requestStarted: "送出請求"
        case .requestCompleted: "收到回應"
        case .requestFailed: "請求失敗"
        case .cacheHit: "使用快取"
        case .saving: "開始保存"
        case .saved: "保存完成"
        case .cleared: "清理完成"
        case .frameworkError: "介面錯誤"
        case .transcription: "辨識結果"
        case .partialTranscription: "部分辨識結果（未完整成功）"
        }
    }
}

public struct AppLogEntry: Sendable, Identifiable {
    public let id: Int
    public let time: Date
    public let elapsed: TimeInterval
    public let area: LogArea
    public let event: LogEvent
    public var operationId: Int?
    public var durationMs: Int?
    public var bytes: Int?
    public var complete: Int?
    public var total: Int?
    public var statusCode: Int?
    /// 錄音期間麥克風最大音量（dBFS）；約 -50 以下代表幾乎沒收到聲音。
    public var peakDb: Int?
    public var detail: String?
    public var transcript: String?
    public var transcriptTruncated = false

    public var isError: Bool {
        event == .failed || event == .requestFailed || event == .frameworkError
            || (statusCode ?? 0) >= 400
    }

    public var message: String {
        guard let detail else { return event.label }
        return "\(event.label)・\(AppLog.detailLabels[detail] ?? detail)"
    }

    public var line: String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: time)
        let stamp = String(
            format: "%02d:%02d:%02d.%03d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000
        )
        var metrics: [String] = []
        if let operationId { metrics.append("操作=\(operationId)") }
        if let durationMs { metrics.append("耗時=\(durationMs) ms") }
        if let bytes { metrics.append("大小=\(bytes) bytes") }
        if let complete, let total { metrics.append("進度=\(complete)/\(total)") }
        if let statusCode { metrics.append("HTTP=\(statusCode)") }
        if let peakDb { metrics.append("最大音量=\(peakDb) dB") }
        if let transcript {
            let encoded = (try? String(data: JSONEncoder().encode(transcript), encoding: .utf8)) ?? "\"\""
            metrics.append("文字=\(encoded)")
        }
        if transcriptTruncated { metrics.append("文字已截短") }
        let head = "\(stamp) (+\(String(format: "%.3f", elapsed)) 秒) [\(area.rawValue.uppercased())] \(message)"
        return metrics.isEmpty ? head : "\(head)  \(metrics.joined(separator: "  "))"
    }
}

/// In-memory diagnostics. Free-form messages, URLs, payloads and errors are
/// deliberately not accepted; `detail` must be a whitelisted code.
/// STT text has a dedicated bounded recording method.
public final class AppLog: ObservableObject, @unchecked Sendable {
    public static let shared = AppLog()
    public static let maxTranscriptCharacters = 16_000

    public let capacity: Int
    private let lock = NSLock()
    private let started = Date()
    private var storage: [AppLogEntry] = []
    private var nextId = 0
    private var notifyScheduled = false

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    public var entries: [AppLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public static let detailLabels: [String: String] = [
        "topicLoading": "載入主題", "topicSelection": "選擇主題", "introduction": "自我介紹",
        "question": "分享回憶", "imageGenerating": "產生回憶圖片", "evaluation": "確認圖片",
        "revisionRecording": "說明修圖要求", "revisionGenerating": "修改圖片", "summary": "摘要",
        "idle": "待命", "preparing": "準備錄音", "recording": "錄音中", "stopping": "停止中",
        "completed": "完成", "failed": "失敗", "manual": "手動停止", "silence": "停頓停止",
        "maximumDuration": "錄音時間上限", "cancelled": "取消", "interrupted": "中斷",
        "timeout": "逾時", "network": "連線錯誤", "server": "服務錯誤", "authentication": "認證錯誤",
        "invalidAudio": "音檔格式錯誤", "invalidResponse": "回應格式錯誤", "incomplete": "辨識未完整結束",
        "payloadTooLarge": "請求過大", "configuration": "設定錯誤", "unsupportedCapability": "不支援的功能",
        "rateLimit": "請求頻率限制", "billing": "額度／付款錯誤", "unexpected": "未分類錯誤",
        "tw": "台語", "zh": "中文", "processing": "處理", "noSpeech": "尚未開口", "disposed": "結束流程",
        "invalidInput": "輸入格式錯誤", "tailo": "台語備援：LLM 轉台羅", "legacyServer": "台語備援：舊伺服器",
        "tailoSkipped": "台語備援：未設定轉台羅模型的 API Key，略過 LLM",
        "sttBackendRefused": "成大 STT 後端辨識伺服器拒絕連線（伺服器端問題）",
        "sttBackendTimeout": "成大 STT 後端辨識伺服器逾時（伺服器端問題）",
        "sttBackendError": "成大 STT 後端回報錯誤",
        "permissionDenied": "麥克風權限未開啟",
        "audioSession": "無法取得音訊使用權（可能被其他 App 或通話佔用）",
        "recorderStart": "錄音器無法啟動",
        "unexpectedStop": "系統中途停止錄音",
        "routeChanged": "音訊裝置被拔除",
        "background": "App 進入背景",
        "foreground": "App 回到前景",
        "playback": "音檔無法播放",
        "keychain": "鑰匙圈（Keychain）存取失敗",
        "load": "讀取",
        "save": "儲存",
        "delete": "刪除",
        "fallbackQuestions": "AI 問題產生失敗，改用預設問題",
        "fallbackName": "姓氏未確認，改用聽到的名字",
        "noName": "沒有聽到可用的名字",
        "fallbackKeywords": "AI 整理回憶失敗，改用簡易關鍵字",
        "fallbackFollowUp": "AI 延伸問題失敗，改用預設問題",
        "imageSave": "圖片存檔失敗",
        "imageEdit": "改圖",
    ]

    public func record(
        _ area: LogArea,
        _ event: LogEvent,
        operationId: Int? = nil,
        durationMs: Int? = nil,
        bytes: Int? = nil,
        complete: Int? = nil,
        total: Int? = nil,
        statusCode: Int? = nil,
        peakDb: Int? = nil,
        detail: String? = nil
    ) {
        append { id, time, elapsed in
            AppLogEntry(
                id: id, time: time, elapsed: elapsed, area: area, event: event,
                operationId: operationId, durationMs: durationMs, bytes: bytes,
                complete: complete, total: total, statusCode: statusCode, peakDb: peakDb,
                detail: detail.map { Self.detailLabels[$0] == nil ? "unexpected" : $0 }
            )
        }
    }

    public func recordTranscription(_ text: String, operationId: Int, partial: Bool = false) {
        let truncated = text.count > Self.maxTranscriptCharacters
        let kept = truncated ? String(text.prefix(Self.maxTranscriptCharacters)) : text
        append { id, time, elapsed in
            AppLogEntry(
                id: id, time: time, elapsed: elapsed, area: .stt,
                event: partial ? .partialTranscription : .transcription,
                operationId: operationId, transcript: kept, transcriptTruncated: truncated
            )
        }
    }

    public func exportText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        scheduleNotify()
    }

    private func append(_ make: (Int, Date, TimeInterval) -> AppLogEntry) {
        lock.lock()
        nextId += 1
        let entry = make(nextId, Date(), elapsed)
        storage.append(entry)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        lock.unlock()
        #if DEBUG
        print(entry.line)
        #endif
        scheduleNotify()
    }

    private func scheduleNotify() {
        lock.lock()
        if notifyScheduled {
            lock.unlock()
            return
        }
        notifyScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notifyScheduled = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }
}

/// Monotonic stopwatch in milliseconds.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var elapsed: Duration { ContinuousClock.now - start }
    public var milliseconds: Int {
        let components = elapsed.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
