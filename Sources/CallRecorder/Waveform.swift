import Accelerate
import AVFoundation

/// Conversation envelope for the player's timeline: per-segment loudness of each track.
/// Computed once from local.caf and remote.caf and cached in waveform.json next to the recording.
struct Waveform: Codable, Equatable {
    static let bins = 480

    /// 0…1 per segment; −50…0 dBFS scale by RMS.
    var local: [Float]
    var remote: [Float]

    static func cacheURL(in folder: URL) -> URL { folder.appending(path: "waveform.json") }

    /// From the cache, or compute and save it if missing. An hour of recording takes about a second.
    static func load(for recording: Recording) async -> Waveform? {
        if PreviewHarness.state != nil { return preview(seed: recording.duration) }
        if let data = try? Data(contentsOf: cacheURL(in: recording.folder)),
           let cached = try? JSONDecoder().decode(Waveform.self, from: data),
           cached.local.count == bins {
            return cached
        }
        let folder = recording.folder
        return await Task.detached(priority: .utility) { build(in: folder) }.value
    }

    /// Synchronous: also called after recording, from the saving thread.
    @discardableResult
    static func build(in folder: URL) -> Waveform? {
        guard let local = envelope(folder.appending(path: "local.caf")),
              let remote = envelope(folder.appending(path: "remote.caf"))
        else { return nil }
        let waveform = Waveform(local: local, remote: remote)
        if let data = try? JSONEncoder().encode(waveform) {
            try? data.write(to: cacheURL(in: folder), options: .atomic)
        }
        return waveform
    }

    private static func envelope(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let framesPerBin = max(1, Int(file.length) / bins)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBin)) else { return nil }
        var result: [Float] = []
        result.reserveCapacity(bins)
        while result.count < bins, file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerBin))) != nil,
                  buffer.frameLength > 0, let channels = buffer.floatChannelData
            else { break }
            var rms: Float = 0
            for channel in 0..<Int(format.channelCount) {
                var value: Float = 0
                vDSP_rmsqv(channels[channel], 1, &value, vDSP_Length(buffer.frameLength))
                rms = max(rms, value)
            }
            result.append(rms > 0 ? max(0, min(1, (20 * log10(rms) + 50) / 50)) : 0)
        }
        result += Array(repeating: 0, count: max(0, bins - result.count))
        return result
    }

    /// A plausible envelope for design screenshots: speakers taking turns.
    private static func preview(seed: Double) -> Waveform {
        var local: [Float] = []
        var remote: [Float] = []
        for index in 0..<bins {
            let phase = Double(index) / 37 + seed.truncatingRemainder(dividingBy: 7)
            let speaker = sin(phase) > 0
            let level = Float(0.45 + 0.35 * abs(sin(Double(index) * 0.9 + seed)))
            local.append(speaker ? level : 0.04)
            remote.append(speaker ? 0.05 : level * 0.9)
        }
        return Waveform(local: local, remote: remote)
    }
}
