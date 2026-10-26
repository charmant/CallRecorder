import Foundation
import UserNotifications

/// A place in the knowledge base a call can be filed to: a project, a part of a project (a client, the
/// company itself), or the inbox. The transcript goes into `<folder>/calls/`.
struct FilingDestination: Identifiable, Hashable {
    enum Kind {
        case project, part, inbox
    }

    /// Path relative to the knowledge base root, e.g. "03_projects/01_studio/clients/acme".
    let id: String
    /// "01_studio › acme".
    let title: String
    let folder: URL
    var kind = Kind.project

    var callsFolder: URL { folder.appending(path: "calls", directoryHint: .isDirectory) }
}

/// Where a recording's transcript was filed — `filed.json` in the recording folder.
struct FilingRecord: Codable, Hashable {
    var destination: String
    var file: String
    var topic: String?
    var filedAt: Date

    static func url(in folder: URL) -> URL { folder.appending(path: "filed.json") }

    static func load(from folder: URL) -> FilingRecord? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FilingRecord.self, from: data)
    }
}

/// The knowledge base (~/Work): projects live in `03_projects/<project>/`; a project with a `clients/`
/// folder (a studio) also takes calls per client, and its `company/` folder takes calls about the company
/// itself. Calls that belong nowhere go to `inbox/calls/`. Read from disk every time, so a new project
/// or client shows up without touching the app. The layout is described in ~/Work/AGENTS.md.
enum KnowledgeBase {
    static let projectsPath = "03_projects"
    static let inboxPath = "inbox"
    /// Large per-recording files that aren't needed once the transcript is filed.
    static let audioFiles = ["local.caf", "remote.caf", "conversation.m4a", "waveform.json"]

    static func destinations(in root: URL) -> [FilingDestination] {
        let projects = root.appending(path: projectsPath, directoryHint: .isDirectory)
        var result: [FilingDestination] = []
        for project in subfolders(of: projects) {
            let name = project.lastPathComponent
            result.append(FilingDestination(id: "\(projectsPath)/\(name)", title: name, folder: project))
            let clients = subfolders(of: project.appending(path: "clients", directoryHint: .isDirectory))
            for client in clients {
                result.append(FilingDestination(id: "\(projectsPath)/\(name)/clients/\(client.lastPathComponent)",
                                                title: "\(name) › \(client.lastPathComponent)", folder: client, kind: .part))
            }
            let company = project.appending(path: "company", directoryHint: .isDirectory)
            if !clients.isEmpty, FileManager.default.fileExists(atPath: company.path) {
                result.append(FilingDestination(id: "\(projectsPath)/\(name)/company", title: "\(name) › company",
                                                folder: company, kind: .part))
            }
        }
        result.append(FilingDestination(id: inboxPath, title: "Inbox",
                                        folder: root.appending(path: inboxPath, directoryHint: .isDirectory), kind: .inbox))
        return result
    }

    /// Writes `<destination>/calls/<date time> <topic or source>.md` and records it in the recording's
    /// `filed.json`. Returns the new file.
    static func file(recording folder: URL, to destination: FilingDestination, topic: String) throws -> URL {
        guard let transcript = Transcript.load(from: folder) else { throw RecorderError("the recording has no transcript") }
        let session = SessionHeader.load(from: folder)
        let startedAt = session?.startedAt ?? transcript.createdAt
        let source = session?.source ?? "Call"
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(stamp.string(from: startedAt)) \(safeFileName(topic.isEmpty ? source : topic))"
        try FileManager.default.createDirectory(at: destination.callsFolder, withIntermediateDirectories: true)
        let url = uniqueURL(in: destination.callsFolder, base: base)

        let text = markdown(transcript, session: session, startedAt: startedAt, source: source,
                            destination: destination, topic: topic)
        try text.write(to: url, atomically: true, encoding: .utf8)

        let record = FilingRecord(destination: destination.id, file: url.path, topic: topic.isEmpty ? nil : topic, filedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: FilingRecord.url(in: folder), options: .atomic)
        return url
    }

    /// To the Trash, not deleted for good. Returns the files that couldn't be moved.
    static func trashAudio(in folder: URL) -> [String] {
        audioFiles.filter { name in
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil
        }
    }

    // MARK: - Markdown

    /// Front matter, a title, an empty "## Итоги" section that the /call skill fills in once, and the
    /// transcript under "## Расшифровка", which nothing edits afterwards. The section names are part of the
    /// knowledge base's format (it is in Russian), not UI text.

    private static func markdown(_ transcript: Transcript, session: SessionHeader?, startedAt: Date, source: String,
                                 destination: FilingDestination, topic: String) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        let duration = transcript.segments.map(\.end).max() ?? 0
        var front = [
            "---",
            "date: \(date.string(from: startedAt))",
            "source: \(source)",
            "duration: \(formatDuration(session?.duration ?? duration))",
            "project: \(destination.id)",
        ]
        if !topic.isEmpty { front.append("topic: \(yamlString(topic))") }
        front += ["transcribed_with: \(transcript.model)", "---"]

        let title = topic.isEmpty ? "\(source) call · \(RecordingDates.full(startedAt))" : topic
        var lines = front + ["", "# \(title)", "", "## Итоги", "", "## Расшифровка", "",
                             "You = my microphone, Them = the other side.", ""]
        lines += transcript.markdownLines
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yamlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Helpers

    private static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !["archive", "calls"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func safeFileName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    private static func uniqueURL(in folder: URL, base: String) -> URL {
        var url = folder.appending(path: "\(base).md")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(index).md")
            index += 1
        }
        return url
    }

    private struct SessionHeader: Decodable {
        struct Track: Decodable { var seconds: Double? }
        var source: String
        var startedAt: Date
        var local: Track?
        var remote: Track?

        var duration: TimeInterval? {
            let seconds = max(local?.seconds ?? 0, remote?.seconds ?? 0)
            return seconds > 0 ? seconds : nil
        }

        static func load(from folder: URL) -> SessionHeader? {
            guard let data = try? Data(contentsOf: folder.appending(path: "session.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SessionHeader.self, from: data)
        }
    }
}

/// The agent that runs the knowledge base's /call skill on a filed transcript, headless. The command runs
/// in the destination folder through a login shell, with the transcript in `$CALL_FILE` and the inbox
/// (where the skill leaves notes about Sergei for review) in `$KB_INBOX`; everything else is off limits.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }

    var command: String {
        switch self {
        case .claude:
            #"claude -p "/call $CALL_FILE" --permission-mode acceptEdits --add-dir "$KB_INBOX" "#
                + #"--allowedTools "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "#
                + #"--disallowedTools "Bash(git push:*)""#
        case .codex:
            #"codex exec --sandbox workspace-write --add-dir "$KB_INBOX" "\$call $CALL_FILE""#
        }
    }
}

/// Banners for "transcript ready" and the agent's summary. Permission is asked on first use.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func post(title: String, body: String) {
        guard PreviewHarness.state == nil else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
