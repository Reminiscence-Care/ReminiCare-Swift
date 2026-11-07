import Foundation

/// Validated 16 kHz mono 16-bit PCM. Splits cover every sample exactly once.
public struct WavAudio: Sendable, Equatable {
    public static let bytesPerSecond = 32_000
    private static let pcmSubFormat: [UInt8] = [
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ]

    public let pcm: Data
    public init(pcm: Data) { self.pcm = Data(pcm) }
    public var seconds: Double { Double(pcm.count) / Double(Self.bytesPerSecond) }

    public struct FormatError: Error, Sendable { public let message: String }

    public static func parse(_ input: Data) throws -> WavAudio {
        let bytes = [UInt8](input)
        func tag(_ offset: Int) -> String { String(decoding: bytes[offset..<offset + 4], as: UTF8.self) }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw FormatError(message: "錄音不是有效的 WAV") }
        var offset = 12
        var validFormat = false
        var pcm = Data()
        while offset + 8 <= bytes.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let start = offset + 8
            guard start + size <= bytes.count else { throw FormatError(message: "WAV 音訊不完整") }
            if id == "fmt " {
                guard size >= 16 else { throw FormatError(message: "WAV 格式不完整") }
                let formatTag = u16(start)
                // AVFoundation may write WAVE_FORMAT_EXTENSIBLE; accept it only
                // when the sub-format GUID is plain PCM with 16 valid bits.
                let isPCM = formatTag == 1 || (
                    formatTag == 0xFFFE && size >= 40 && u16(start + 16) >= 22 && u16(start + 18) == 16
                        && Array(bytes[start + 24..<start + 40]) == pcmSubFormat
                )
                validFormat = isPCM && u16(start + 2) == 1 && u32(start + 4) == 16_000 && u16(start + 14) == 16
            } else if id == "data" {
                pcm.append(contentsOf: bytes[start..<start + size])
            }
            offset = start + size + (size % 2)
        }
        guard offset == bytes.count else { throw FormatError(message: "WAV 尾端區塊不完整") }
        guard validFormat, !pcm.isEmpty, pcm.count % 2 == 0 else {
            throw FormatError(message: "錄音需為 16kHz 單聲道 16-bit PCM，且包含音訊")
        }
        return WavAudio(pcm: pcm)
    }

    public func encode() -> Data { Self.wav(pcm: pcm, sampleRate: 16_000) }

    /// 44-byte canonical WAV header around mono 16-bit PCM.
    public static func wav(pcm: Data, sampleRate: Int) -> Data {
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + pcm.count); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(pcm.count)
        return header + pcm
    }

    /// Splits at quiet 20 ms windows near each `maximumBytes` boundary, keeping segments over 1 s.
    public func split(maximumBytes: Int = 5 * bytesPerSecond) -> [WavAudio] {
        let samples = [UInt8](pcm)
        func sample(_ index: Int) -> Int { Int(Int16(bitPattern: UInt16(samples[index]) | UInt16(samples[index + 1]) << 8)) }
        var segments: [WavAudio] = []
        var start = 0
        while start < samples.count {
            var end = min(start + maximumBytes, samples.count)
            if end < samples.count {
                var bestEnergy = Int.max
                var bestEnd = end
                var candidate = min(max(end - 16_000, start + 32_000), end)
                while candidate <= end {
                    var energy = 0
                    var i = candidate - 640
                    while i < candidate { energy += abs(sample(i)); i += 2 }
                    if energy < bestEnergy { bestEnergy = energy; bestEnd = candidate }
                    candidate += 640
                }
                end = bestEnd
            }
            segments.append(WavAudio(pcm: Data(samples[start..<end])))
            start = end
        }
        return segments
    }
}
