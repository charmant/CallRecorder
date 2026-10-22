import AppKit
import CoreAudio

/// A process registered with Core Audio (has played or recorded audio at some point).
struct AudioProcessInfo: Identifiable, Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let executable: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var id: AudioObjectID { objectID }

    var summary: String {
        "pid \(pid) \(executable) [\(bundleID.isEmpty ? "—" : bundleID)] in=\(isRunningInput ? 1 : 0) out=\(isRunningOutput ? 1 : 0)"
    }
}

enum AudioProcesses {
    static func list() -> [AudioProcessInfo] {
        guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
        return processes.compactMap { process in
            guard let pid = try? process.pid, pid > 0 else { return nil }
            return AudioProcessInfo(
                objectID: process.id,
                pid: pid,
                bundleID: (try? process.bundleID) ?? "",
                executable: executableName(pid),
                isRunningInput: (try? process.isRunningInput) ?? false,
                isRunningOutput: (try? process.isRunningOutput) ?? false
            )
        }
    }

    /// Executable name: daemons like avconferenced have no NSRunningApplication.
    static func executableName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }
}

enum CallSource: String, CaseIterable, Identifiable {
    case faceTime, telegram, systemWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .faceTime: "FaceTime"
        case .telegram: "Telegram"
        case .systemWide: "Whole system audio"
        }
    }

    var folderName: String {
        switch self {
        case .faceTime: "FaceTime"
        case .telegram: "Telegram"
        case .systemWide: "System"
        }
    }

    /// Processes whose audio belongs to the call. The other party's voice in FaceTime is played by the
    /// avconferenced daemon (verified on a real call). On macOS 27 the call window is the
    /// "Phone" app, but it only plays the ringtone, so we don't include it in the tap.
    func matches(_ process: AudioProcessInfo) -> Bool {
        let bundle = process.bundleID.lowercased()
        let executable = process.executable.lowercased()
        switch self {
        case .faceTime:
            return bundle == "com.apple.facetime" || executable == "facetime" || executable == "avconferenced"
        case .telegram:
            return bundle.contains("telegram") || executable.contains("telegram")
        case .systemWide:
            return false
        }
    }

    /// A call counts as in progress while any of the app's processes holds the microphone.
    static func activeCall(in processes: [AudioProcessInfo]) -> CallSource? {
        [CallSource.faceTime, .telegram].first { source in
            processes.contains { source.matches($0) && $0.isRunningInput }
        }
    }
}
