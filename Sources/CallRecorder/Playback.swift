import AVFoundation
import Observation

/// Playback of conversation.m4a from the panel and the history window — one player for the whole app.
@MainActor
@Observable
final class Playback {
    private(set) var current: Recording?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var elapsed: TimeInterval = 0

    /// The player lives only while something is playing: AVPlayer registers an audio session
    /// with the system, and there is no point holding it while the app just sits in the menu bar.
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var readyObserver: NSKeyValueObservation?
    @ObservationIgnored private var isScrubbing = false

    var timeText: String {
        "\(formatDuration(elapsed)) / \(formatDuration(current?.duration ?? 0))"
    }

    func isCurrent(_ recording: Recording) -> Bool { current?.id == recording.id }

    func isPlaying(_ recording: Recording) -> Bool { isCurrent(recording) && isPlaying }

    func toggle(_ recording: Recording) {
        if isCurrent(recording) {
            togglePause()
        } else {
            start(recording)
        }
    }

    /// Play from `fraction` (0…1): a click on the waveform of a recording that hasn't played yet.
    func play(_ recording: Recording, at fraction: Double) {
        if isCurrent(recording) {
            seek(to: fraction)
            if player?.timeControlStatus == .paused { player?.play() }
        } else {
            start(recording, at: fraction)
        }
    }

    func togglePause() {
        guard current != nil, let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(to fraction: Double) {
        guard let current else { return }
        seek(seconds: max(0, min(1, fraction)) * current.duration)
    }

    /// While the slider is being dragged, the player's periodic timer must not move it back.
    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
    }

    private func seek(seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timeChanged(seconds)
    }

    func stop() {
        if let player {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        readyObserver = nil
        player = nil
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        current = nil
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    /// For design screenshots only: show a recording as playing without real audio.
    func showPreview(_ recording: Recording, progress: Double) {
        current = recording
        isPlaying = true
        self.progress = progress
        elapsed = progress * recording.duration
    }

    private func start(_ recording: Recording, at fraction: Double = 0) {
        stop()
        let item = AVPlayerItem(url: recording.conversationURL)
        let player = AVPlayer(playerItem: item)
        if fraction > 0 {
            // A seek is ignored until the item is ready — jump once it is.
            let seconds = fraction * recording.duration
            readyObserver = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                Task { @MainActor in
                    self?.readyObserver = nil
                    self?.seek(seconds: seconds)
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.timeChanged(time.seconds)
            }
        }
        statusObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        self.player = player
        current = recording
        timeChanged(fraction * recording.duration)
        player.play()
    }

    private func timeChanged(_ seconds: Double) {
        guard let current, current.duration > 0, seconds.isFinite else { return }
        elapsed = seconds
        progress = min(1, max(0, seconds / current.duration))
    }
}
