import Foundation

/// Polls Core Audio's audio processes once a second and writes changes to the diagnostic log.
/// The log shows which processes are actually playing and recording audio during a call.
@MainActor
final class ProcessMonitor {
    private(set) var processes: [AudioProcessInfo] = []
    var onChange: (@MainActor (_ processes: [AudioProcessInfo], _ changes: [String]) -> Void)?
    private var timer: Timer?
    private let log: DiagnosticLog

    init(log: DiagnosticLog) {
        self.log = log
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func poll() {
        let current = AudioProcesses.list()
        let previous = Dictionary(processes.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.objectID))
        var changes: [String] = []
        for process in current {
            if let old = previous[process.objectID] {
                if old.isRunningInput != process.isRunningInput || old.isRunningOutput != process.isRunningOutput {
                    changes.append("~ " + process.summary)
                }
            } else {
                changes.append("+ " + process.summary)
            }
        }
        for process in processes where !currentIDs.contains(process.objectID) {
            changes.append("- " + process.summary)
        }
        processes = current
        guard !changes.isEmpty else { return }
        log.write(changes)
        onChange?(current, changes)
    }
}
