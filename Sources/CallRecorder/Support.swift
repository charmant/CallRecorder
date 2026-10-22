import CoreAudio
import Foundation

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Throws an error with a readable message if the Core Audio call returned something other than noErr.
func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw RecorderError("\(what): \(fourCC(status))") }
}

/// Core Audio codes are often four characters ('!obj', 'who?'); this makes them easier to search for.
func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32($0))) }
    guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return "\(status)" }
    return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
}

extension AudioStreamBasicDescription {
    var summary: String {
        let isFloat = mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(mSampleRate)) Hz, \(mChannelsPerFrame) ch, \(mBitsPerChannel)-bit \(isFloat ? "float" : "int"), \(interleaved ? "interleaved" : "non-interleaved")"
    }
}

/// Peak (0…1) → meter position on a −60…0 dBFS scale.
func meterValue(peak: Float) -> Float {
    guard peak > 0 else { return 0 }
    return max(0, min(1, (20 * log10(peak) + 60) / 60))
}

func dbfs(_ peak: Float) -> Double? {
    peak > 0 ? (20 * Double(log10(peak)) * 10).rounded() / 10 : nil
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%02d:%02d", total / 60, total % 60)
}

/// Text log with timestamps; writes in the background, safe to call from any thread.
final class DiagnosticLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "CallRecorder.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func write(_ line: String) { write([line]) }

    func write(_ lines: [String]) {
        let date = Date()
        queue.async { [url] in
            let stamp = Self.formatter.string(from: date)
            let text = lines.map { "\(stamp) \($0)\n" }.joined()
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}
