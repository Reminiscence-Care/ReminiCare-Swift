import Foundation
#if os(iOS)
import AVFoundation
#endif

/// What a recording file actually contains: header format plus sample-level
/// statistics. Never throws, so it can describe broken files too. Used for the
/// App Log after every recording and by the settings-page recording test.
public struct WavInspection: Sendable, Equatable {
    /// Ordered from most to least fundamental; the first that applies wins.
    public enum Verdict: String, Sendable {
        case ok
        case fileMissing = "recordingFileMissing"
        case notWav
        case incompleteFile = "recordingIncomplete"
        case formatMismatch
        case tooShort = "recordingTooShort"
        case digitalSilence
        case micSilent
        case tooQuiet

        /// Plain-language explanation for the recording test page.
        public var advice: String {
            switch self {
            case .ok: "錄音正常。"
            case .fileMissing: "沒有產生錄音檔：錄音器可能沒有啟動成功，請重新錄音。"
            case .notWav: "錄音檔不是有效的 WAV，錄音器可能出錯。"
            case .incompleteFile: "錄音檔不完整：錄音器可能沒有正常結束（被中斷或被系統停止）。"
            case .formatMismatch: "錄音格式不符：語音辨識需要 16 kHz 單聲道 16-bit PCM。"
            case .tooShort: "錄音太短（不到 0.3 秒），請說完再停止。"
            case .digitalSilence:
                "麥克風完全沒有訊號（錄到的全是 0）。請確認：設定 → 隱私權與安全性 → 麥克風已允許本 App；"
                    + "沒有連接藍牙耳機或外接麥克風；沒有其他 App 或通話正在使用麥克風。"
            case .micSilent: "幾乎沒有收到聲音（音量極低）。請確認麥克風沒有被遮住，或改用 iPad 內建麥克風。"
            case .tooQuiet: "有收到聲音但非常小，語音辨識可能聽不到。請靠近 iPad 說話。"
            }
        }
    }

    public var exists = false
    public var fileBytes = 0
    public var formatTag: Int?
    public var channels: Int?
    public var sampleRate: Int?
    public var bitsPerSample: Int?
    public var dataBytes = 0
    public var seconds: Double = 0
    /// dBFS; nil when the samples could not be read (not 16-bit PCM).
    public var peakDb: Double?
    public var rmsDb: Double?
    /// Share of 20 ms windows louder than −50 dBFS.
    public var loudPercent: Int?
    /// Share of samples that are exactly zero.
    public var zeroPercent: Int?
    public var clipPercent: Int?
    public var verdict: Verdict = .fileMissing

    public static let silenceFloorDb = -120.0

    public static func inspect(file: URL?) -> WavInspection {
        guard let file, let data = try? Data(contentsOf: file) else { return WavInspection() }
        return inspect(data)
    }

    public static func inspect(_ data: Data) -> WavInspection {
        var result = WavInspection()
        result.exists = true
        result.fileBytes = data.count
        let layout = WavLayout.read([UInt8](data))
        if let format = layout.format {
            result.formatTag = format.tag
            result.channels = format.channels
            result.sampleRate = format.sampleRate
            result.bitsPerSample = format.bitsPerSample
        }
        result.dataBytes = layout.pcm.count
        if let format = layout.format, format.sampleRate > 0, format.channels > 0, format.bitsPerSample >= 8 {
            let bytesPerSecond = format.sampleRate * format.channels * format.bitsPerSample / 8
            result.seconds = Double(layout.pcm.count) / Double(bytesPerSecond)
        }
        if let format = layout.format, format.isPCM, format.bitsPerSample == 16, layout.pcm.count >= 2 {
            result.measure(layout.pcm, samplesPerWindow: max(1, format.sampleRate * max(format.channels, 1) / 50))
        }
        result.verdict = verdict(result, layout)
        return result
    }

    private static func verdict(_ result: WavInspection, _ layout: WavLayout) -> Verdict {
        if layout.problem == .notRiff { return .notWav }
        guard let format = layout.format, layout.hasDataChunk else {
            return layout.problem == nil ? .notWav : .incompleteFile
        }
        if layout.problem != nil { return .incompleteFile }
        if !format.isSpeechFormat { return .formatMismatch }
        if result.seconds < 0.3 { return .tooShort }
        if (result.zeroPercent ?? 0) >= 99 { return .digitalSilence }
        if (result.peakDb ?? silenceFloorDb) < -60 { return .micSilent }
        if (result.peakDb ?? silenceFloorDb) < -45 || result.loudPercent == 0 { return .tooQuiet }
        return .ok
    }

    private mutating func measure(_ pcm: Data, samplesPerWindow: Int) {
        let count = pcm.count / 2
        var peak = 0
        var sumSquares = 0.0
        var zeros = 0
        var clipped = 0
        var windows = 0
        var loudWindows = 0
        var windowSquares = 0.0
        var windowSamples = 0
        // −50 dBFS as a mean square over full scale.
        let loudMeanSquare = pow(10, -50.0 / 10) * 32768.0 * 32768.0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                if sample == 0 { zeros += 1 }
                if magnitude >= 32767 { clipped += 1 }
                let square = Double(sample * sample)
                sumSquares += square
                windowSquares += square
                windowSamples += 1
                if windowSamples == samplesPerWindow {
                    windows += 1
                    if windowSquares / Double(windowSamples) >= loudMeanSquare { loudWindows += 1 }
                    windowSquares = 0
                    windowSamples = 0
                }
            }
        }
        if windowSamples > 0 {
            windows += 1
            if windowSquares / Double(windowSamples) >= loudMeanSquare { loudWindows += 1 }
        }
        func dbfs(_ amplitude: Double) -> Double {
            amplitude <= 0 ? Self.silenceFloorDb : max(20 * log10(amplitude / 32768), Self.silenceFloorDb)
        }
        peakDb = dbfs(Double(peak))
        rmsDb = dbfs((sumSquares / Double(count)).squareRoot())
        loudPercent = windows == 0 ? 0 : loudWindows * 100 / windows
        zeroPercent = zeros * 100 / count
        clipPercent = clipped * 100 / count
    }

    /// e.g. "WAV PCM 16000 Hz 單聲道 16-bit".
    public var formatDescription: String {
        guard let sampleRate, let channels, let bitsPerSample else { return "無法讀取格式" }
        let encoding = switch formatTag {
        case 1: "PCM"
        case 0xFFFE: "PCM（EXTENSIBLE）"
        case 3: "浮點數"
        default: "格式代碼 \(formatTag ?? 0)"
        }
        let layout = channels == 1 ? "單聲道" : "\(channels) 聲道"
        return "WAV \(encoding) \(sampleRate) Hz \(layout) \(bitsPerSample)-bit"
    }
}

/// The audio input the system is using, as App Log codes and numbers only
/// (never device names).
public struct AudioRouteSnapshot: Sendable, Equatable {
    public enum Input: String, Sendable {
        case builtIn = "inputBuiltIn"
        case bluetooth = "inputBluetooth"
        case wired = "inputWired"
        case usb = "inputUsb"
        case other = "inputOther"
        case none = "inputNone"

        public var label: String {
            switch self {
            case .builtIn: "內建麥克風"
            case .bluetooth: "藍牙耳機"
            case .wired: "有線耳機"
            case .usb: "USB 音訊裝置"
            case .other: "其他裝置"
            case .none: "找不到麥克風"
            }
        }
    }

    public var input: Input
    public var inputAvailable: Bool
    /// Hardware sample rate of the session (the recorder converts to 16 kHz).
    public var sampleRate: Int
    public var inputChannels: Int
    /// 0–100, nil when unknown.
    public var inputGainPercent: Int?

    public init(input: Input, inputAvailable: Bool, sampleRate: Int, inputChannels: Int, inputGainPercent: Int? = nil) {
        self.input = input
        self.inputAvailable = inputAvailable
        self.sampleRate = sampleRate
        self.inputChannels = inputChannels
        self.inputGainPercent = inputGainPercent
    }

    /// Nil where there is no audio session (macOS tests).
    public static func current() -> AudioRouteSnapshot? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let input: Input = switch session.currentRoute.inputs.first?.portType {
        case nil: .none
        case .builtInMic?: .builtIn
        case .bluetoothHFP?, .bluetoothLE?, .bluetoothA2DP?: .bluetooth
        case .headsetMic?, .lineIn?: .wired
        case .usbAudio?: .usb
        default: .other
        }
        return AudioRouteSnapshot(
            input: input,
            inputAvailable: session.isInputAvailable,
            sampleRate: Int(session.sampleRate.rounded()),
            inputChannels: session.inputNumberOfChannels,
            inputGainPercent: Int((session.inputGain * 100).rounded())
        )
        #else
        return nil
        #endif
    }
}
