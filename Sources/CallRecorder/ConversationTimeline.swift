import SwiftUI

/// Conversation waveform you can click to jump around: them on top, you on the bottom.
/// A click or drag moves playback to that spot; if the recording isn't playing yet,
/// it starts playing from there. For VoiceOver it's a regular slider.
struct ConversationTimeline: View {
    let recording: Recording
    let playback: Playback
    var height: CGFloat = 30

    @State private var waveform: Waveform?
    @State private var hover: Double?

    private static let remoteColor = Color.blue
    private static let localColor = Color.green

    var body: some View {
        let isCurrent = playback.isCurrent(recording)
        let progress = isCurrent ? playback.progress : 0
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            Canvas { context, size in
                draw(in: &context, size: size, progress: progress, showsPlayhead: isCurrent)
            }
            .overlay(alignment: .topLeading) {
                if let hover {
                    Text(formatDuration(hover * recording.duration))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(.background, in: .rect(cornerRadius: 4))
                        .fixedSize()
                        .offset(x: min(max(0, hover * width - 18), width - 40), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Self.clamp(value.location.x / width)
                        playback.setScrubbing(true)
                        if playback.isCurrent(recording) {
                            playback.seek(to: fraction)
                        } else {
                            playback.play(recording, at: fraction)
                        }
                    }
                    .onEnded { _ in playback.setScrubbing(false) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = Self.clamp(location.x / width)
                case .ended: hover = nil
                }
            }
        }
        .frame(height: height)
        .task(id: recording.id) { waveform = await Waveform.load(for: recording) }
        .help("Top: them, bottom: you. Click to jump there.")
        .accessibilityRepresentation {
            Slider(value: Binding(get: { progress }, set: { playback.play(recording, at: $0) })) {
                Text("Playback position")
            }
            .accessibilityValue(isCurrent ? playback.timeText : recording.durationText)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress: Double, showsPlayhead: Bool) {
        let middle = size.height / 2
        guard let waveform, !waveform.local.isEmpty else {
            // The waveform is still being computed: a thin track, which can be clicked too.
            let track = CGRect(x: 0, y: middle - 1.5, width: size.width, height: 3)
            context.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(.secondary.opacity(0.3)))
            context.fill(Path(roundedRect: CGRect(x: 0, y: track.minY, width: size.width * progress, height: 3), cornerRadius: 1.5),
                         with: .color(.accentColor))
            return
        }
        let count = waveform.local.count
        let step = size.width / CGFloat(count)
        let barWidth = max(1, step - 0.6)
        var playedRemote = Path(), restRemote = Path(), playedLocal = Path(), restLocal = Path()
        for index in 0..<count {
            let x = CGFloat(index) * step
            let up = max(0.5, CGFloat(waveform.remote[index]) * (middle - 1))
            let down = max(0.5, CGFloat(waveform.local[index]) * (middle - 1))
            let played = Double(index + 1) / Double(count) <= progress
            let remoteBar = CGRect(x: x, y: middle - up, width: barWidth, height: up)
            let localBar = CGRect(x: x, y: middle, width: barWidth, height: down)
            if played {
                playedRemote.addRect(remoteBar)
                playedLocal.addRect(localBar)
            } else {
                restRemote.addRect(remoteBar)
                restLocal.addRect(localBar)
            }
        }
        context.fill(restRemote, with: .color(Self.remoteColor.opacity(0.35)))
        context.fill(restLocal, with: .color(Self.localColor.opacity(0.35)))
        context.fill(playedRemote, with: .color(Self.remoteColor))
        context.fill(playedLocal, with: .color(Self.localColor))
        if showsPlayhead {
            context.fill(Path(CGRect(x: size.width * progress - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
        }
        if let hover {
            context.fill(Path(CGRect(x: size.width * hover - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(.primary.opacity(0.4)))
        }
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}
