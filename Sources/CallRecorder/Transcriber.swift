import Accelerate
import Foundation
import FluidAudio

/// One line of a transcript: who spoke, when (seconds from the start of the recording) and what.
struct TranscriptSegment: Codable, Hashable {
    enum Speaker: String, Codable {
        case you, them

        var title: String { self == .you ? "You" : "Them" }
    }

    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Contents of transcript.json; transcript.md is rendered from it.
struct Transcript: Codable {
    var model: String
    var createdAt: Date
    var processingSeconds: Double
    var segments: [TranscriptSegment]

    static func url(in folder: URL) -> URL { folder.appending(path: "transcript.json") }
    static func markdownURL(in folder: URL) -> URL { folder.appending(path: "transcript.md") }

    static func load(from folder: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    var plainText: String { segments.map(\.text).joined(separator: " ") }
}

/// On-device transcription with Parakeet TDT 0.6B v3 via FluidAudio (Core ML, Neural Engine).
///
/// Each track is cut into utterances at pauses and every utterance is transcribed on its own:
/// the tracks are already separated by speaker, so no diarization is needed. This setup won our
/// benchmark on a real call (see docs/DEVELOPMENT.md). The model is downloaded on first use
/// (~480 MB) and unloaded when the queue is empty.
actor Transcriber {
    enum Progress: Sendable {
        case downloadingModel(Double)
        case transcribing(Double)
    }

    static let shared = Transcriber()
    /// The model in use; `--model` / `--encoder` override it for benchmarking. Ultra (a full-precision
    /// post-training of v3, ~610 MB) had the fewest errors of the Core ML builds on our call.
    nonisolated(unsafe) static var modelVersion: AsrModelVersion = .ultra
    nonisolated(unsafe) static var encoderPrecision: ParakeetEncoderPrecision = .int8
    static var modelName: String {
        modelVersion == .ultra ? "Parakeet Ultra" : "Parakeet TDT 0.6B v3 (\(encoderPrecision.rawValue))"
    }

    private var manager: AsrManager?

    func transcribe(folder: URL, progress: @escaping @Sendable (Progress) -> Void) async throws -> Transcript {
        let started = Date()
        let manager = try await loadedManager { progress(.downloadingModel($0)) }
        let converter = AudioConverter()
        var segments: [TranscriptSegment] = []
        let tracks: [(TranscriptSegment.Speaker, String)] = [(.you, "local.caf"), (.them, "remote.caf")]
        for (trackIndex, (speaker, file)) in tracks.enumerated() {
            let samples = try converter.resampleAudioFile(folder.appending(path: file))
            let utterances = UtteranceSplitter.split(samples)
            for (index, range) in utterances.enumerated() {
                try Task.checkCancellation()
                var clip = Array(samples[range])
                if clip.count < UtteranceSplitter.rate {  // the model needs at least 0.3 s; pad short clips to 1 s
                    clip += [Float](repeating: 0, count: UtteranceSplitter.rate - clip.count)
                }
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                // No `language:` on purpose: FluidAudio's Russian filter keeps only Cyrillic tokens and
                // would turn English words such as "GitHub" or "JSON" into Cyrillic transliterations.
                let result = try await manager.transcribe(clip, decoderState: &state, language: nil)
                let start = Double(range.lowerBound) / Double(UtteranceSplitter.rate)
                let end = Double(range.upperBound) / Double(UtteranceSplitter.rate)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.keeps(text, duration: end - start) {
                    segments.append(TranscriptSegment(speaker: speaker, start: start, end: end, text: text))
                }
                let done = (Double(trackIndex) + Double(index + 1) / Double(max(utterances.count, 1))) / Double(tracks.count)
                progress(.transcribing(done))
            }
        }
        segments.sort { $0.start < $1.start }
        let transcript = Transcript(model: Self.modelName, createdAt: Date(),
                                    processingSeconds: Date().timeIntervalSince(started), segments: segments)
        try Self.save(transcript, in: folder)
        return transcript
    }

    /// Benchmark helper: transcribes ready-made clips as they are (no splitting, no filtering).
    func transcribeClips(_ urls: [URL]) async throws -> [String: String] {
        let manager = try await loadedManager { _ in }
        let converter = AudioConverter()
        var texts: [String: String] = [:]
        for url in urls {
            var clip = try converter.resampleAudioFile(url)
            if clip.count < UtteranceSplitter.rate {
                clip += [Float](repeating: 0, count: UtteranceSplitter.rate - clip.count)
            }
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(clip, decoderState: &state, language: nil)
            texts[url.deletingPathExtension().lastPathComponent] = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return texts
    }

    /// Frees the model's memory; the next transcription loads it again from disk.
    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    private func loadedManager(progress: @escaping @Sendable (Double) -> Void) async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: Self.modelVersion, encoderPrecision: Self.encoderPrecision) {
            progress($0.fractionCompleted)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }

    /// Short clips with no Cyrillic at all are almost always noise or a backchannel the model heard
    /// as "Yeah" / "Nie" / "Mm-hmm" — dropping them removed every phantom line in our benchmark.
    static func keeps(_ text: String, duration: TimeInterval) -> Bool {
        guard !text.isEmpty else { return false }
        let hasCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let hasLatin = text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.isASCII }
        return !(duration < 1.6 && hasLatin && !hasCyrillic)
    }

    // MARK: - Files

    private static func save(_ transcript: Transcript, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: Transcript.url(in: folder), options: .atomic)
        try markdown(transcript, folder: folder).write(to: Transcript.markdownURL(in: folder), atomically: true, encoding: .utf8)
    }

    /// transcript.md: a header, then one line per utterance — "[05:12–05:14] Them: text" — with no blank
    /// lines in between. Two trailing spaces are a Markdown line break, so rendered views keep one line per
    /// utterance too instead of merging them into a paragraph.
    private static func markdown(_ transcript: Transcript, folder: URL) -> String {
        var header = ["Transcribed on device with \(transcript.model)", "You = your microphone, Them = the other side"]
        if let session = SessionHeader.load(from: folder) {
            header.insert("\(session.source) · \(RecordingDates.full(session.startedAt))", at: 0)
        }
        var lines = ["# Transcript", "", header.joined(separator: " · "), ""]
        lines += transcript.segments.map {
            "[\(formatDuration($0.start))–\(formatDuration($0.end))] \($0.speaker.title): \($0.text)  "
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct SessionHeader: Decodable {
        var source: String
        var startedAt: Date

        static func load(from folder: URL) -> SessionHeader? {
            guard let data = try? Data(contentsOf: folder.appending(path: "session.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SessionHeader.self, from: data)
        }
    }
}

/// Cuts a 16 kHz mono track into utterances at pauses — the same rules as the benchmark:
/// 30 ms frames, a threshold 15 dB above the noise floor, pauses under 0.6 s kept inside an
/// utterance, utterances under 0.4 s dropped, 0.2 s of padding, and anything longer than one
/// model window (15 s) split at its quietest point.
enum UtteranceSplitter {
    static let rate = 16_000
    private static let frame = rate * 30 / 1000
    private static let frameSeconds = 0.03

    static func split(_ samples: [Float]) -> [Range<Int>] {
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }
        var levels = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<frameCount {
                var meanSquare: Float = 0
                vDSP_measqv(buffer.baseAddress! + index * frame, 1, &meanSquare, vDSP_Length(frame))
                levels[index] = 10 * log10(meanSquare + 1e-12)
            }
        }
        let floor = levels.sorted()[frameCount / 10]
        let threshold = max(floor + 15, -45)

        var spans: [(Int, Int)] = []
        var start: Int?
        for (index, level) in levels.enumerated() {
            if level > threshold, start == nil { start = index }
            if level <= threshold, let begin = start { spans.append((begin, index)); start = nil }
        }
        if let begin = start { spans.append((begin, frameCount)) }

        var merged: [(Int, Int)] = []
        for span in spans {
            if let last = merged.last, Double(span.0 - last.1) * frameSeconds < 0.6 {
                merged[merged.count - 1].1 = span.1
            } else {
                merged.append(span)
            }
        }

        let maxFrames = Int(14.5 / frameSeconds), minSplit = Int(5 / frameSeconds)
        var result: [Range<Int>] = []
        for (begin, end) in merged where Double(end - begin) * frameSeconds >= 0.4 {
            var first = max(0, begin - 7)
            let last = min(frameCount, end + 7)
            while last - first > maxFrames {
                let window = (first + minSplit)..<(first + maxFrames)
                let cut = window.min { levels[$0] < levels[$1] } ?? (first + maxFrames)
                result.append((first * frame)..<(cut * frame))
                first = cut
            }
            result.append((first * frame)..<(last * frame))
        }
        return result
    }
}
