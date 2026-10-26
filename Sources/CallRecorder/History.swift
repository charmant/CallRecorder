import AVFoundation
import Foundation

/// A saved call recording — a folder in the recordings folder (~/Calls by default) with session.json.
struct Recording: Identifiable, Hashable {
    let folder: URL
    let source: String
    let startedAt: Date
    let duration: TimeInterval
    let problems: [String]
    let canPlay: Bool
    var hasTranscript = false
    /// The source tracks are still there, so the recording can be transcribed (again).
    var hasAudio = true
    /// Where the transcript was filed in the knowledge base, if it was.
    var filing: FilingRecord?

    var id: URL { folder }
    var conversationURL: URL { folder.appending(path: "conversation.m4a") }
    var hasProblems: Bool { !problems.isEmpty }
    var durationText: String { formatDuration(duration) }
    var dayTimeText: String { RecordingDates.dayTime(startedAt) }

    var sourceSymbol: String {
        switch source {
        case CallSource.faceTime.title: "video.fill"
        case CallSource.telegram.title: "paperplane.fill"
        default: "waveform"
        }
    }

    /// `transcript` is the recording's transcript text, when it has been loaded for search.
    func matches(_ query: String, transcript: String? = nil) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let text = [source, dayTimeText, RecordingDates.dayTitle(startedAt), transcript ?? ""] + problems
        return text.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum RecordingHistory {
    /// Call recordings, newest first. Only FaceTime and Telegram sessions are kept, so self-tests
    /// (all system audio, whatever title older session.json files carry) stay out of the history.
    static func load(from root: URL) -> [Recording] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "session.json")),
                  let session = try? decoder.decode(Summary.self, from: data),
                  [CallSource.faceTime.title, CallSource.telegram.title].contains(session.source)
            else { return nil }
            var problems = session.problems ?? []
            var duration = max(session.remote?.seconds ?? 0, session.local?.seconds ?? 0)
            if session.endedAt == nil {
                // The app quit mid-recording: take the duration from the file itself.
                problems.insert("recording interrupted — the app quit while recording", at: 0)
                duration = fileDuration(folder.appending(path: "remote.caf"))
            }
            let canPlay = FileManager.default.fileExists(atPath: folder.appending(path: "conversation.m4a").path)
            return Recording(folder: folder, source: session.source, startedAt: session.startedAt,
                             duration: duration, problems: problems, canPlay: canPlay,
                             hasTranscript: FileManager.default.fileExists(atPath: Transcript.url(in: folder).path),
                             hasAudio: FileManager.default.fileExists(atPath: folder.appending(path: "remote.caf").path),
                             filing: FilingRecord.load(from: folder))
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private static func fileDuration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Only the session.json fields we need, all optional — so old recordings stay readable
    /// after the session format grows.
    private struct Summary: Decodable {
        struct Track: Decodable { var seconds: Double? }
        var source: String
        var startedAt: Date
        var endedAt: Date?
        var problems: [String]?
        var local: Track?
        var remote: Track?
    }
}

/// Recordings of a single day — a section in the history window.
struct RecordingDay: Identifiable {
    let id: Date
    let title: String
    let recordings: [Recording]

    static func group(_ recordings: [Recording]) -> [RecordingDay] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { day in
            RecordingDay(id: day, title: RecordingDates.dayTitle(day), recordings: byDay[day] ?? [])
        }
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, faceTime, telegram, problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Recordings"
        case .faceTime: "FaceTime"
        case .telegram: "Telegram"
        case .problems: "With Issues"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .faceTime: "video"
        case .telegram: "paperplane"
        case .problems: "exclamationmark.triangle"
        }
    }

    func includes(_ recording: Recording) -> Bool {
        switch self {
        case .all: true
        case .faceTime: recording.source == CallSource.faceTime.title
        case .telegram: recording.source == CallSource.telegram.title
        case .problems: recording.hasProblems
        }
    }
}

enum RecordingDates {
    private static let locale = Locale(identifier: "en_US")

    /// "Today", "Yesterday", "Monday, October 20".
    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale))
    }

    /// "Today, 1:36 PM", "Yesterday, 9:05 AM", "Oct 20, 1:36 PM".
    static func dayTime(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day().locale(locale))), \(time)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().year().hour().minute().locale(locale))
    }
}
