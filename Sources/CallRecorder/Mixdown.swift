import AVFoundation

enum Mixdown {
    /// Mixes the tracks into conversation.m4a (AAC, stereo): them as is, your voice in the center.
    /// Both tracks came from the same IOProc, so their sample rate and start match — summing them is enough.
    static func run(local localURL: URL, remote remoteURL: URL, output: URL) throws {
        let local = try AVAudioFile(forReading: localURL)
        let remote = try AVAudioFile(forReading: remoteURL)
        let sampleRate = remote.processingFormat.sampleRate
        guard local.processingFormat.sampleRate == sampleRate else {
            throw RecorderError("track sample rates differ: \(local.processingFormat.sampleRate) and \(sampleRate)")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let chunk: AVAudioFrameCount = 32_768
        guard let localBuffer = AVAudioPCMBuffer(pcmFormat: local.processingFormat, frameCapacity: chunk),
              let remoteBuffer = AVAudioPCMBuffer(pcmFormat: remote.processingFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: chunk)
        else { throw RecorderError("couldn't allocate mixdown buffers") }

        let total = max(local.length, remote.length)
        var position: AVAudioFramePosition = 0
        while position < total {
            try read(local, into: localBuffer, chunk)
            try read(remote, into: remoteBuffer, chunk)
            let frames = Int(min(AVAudioFramePosition(chunk), total - position))
            mix(local: localBuffer, remote: remoteBuffer, into: outBuffer, frames: frames)
            try out.write(from: outBuffer)
            position += AVAudioFramePosition(frames)
        }
    }

    private static func read(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer, _ chunk: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard file.framePosition < file.length else { return }
        try file.read(into: buffer, frameCount: chunk)
    }

    private static func mix(local: AVAudioPCMBuffer, remote: AVAudioPCMBuffer, into out: AVAudioPCMBuffer, frames: Int) {
        guard let mine = local.floatChannelData, let theirs = remote.floatChannelData, let mixed = out.floatChannelData else { return }
        let localChannels = Int(local.format.channelCount)
        let remoteChannels = Int(remote.format.channelCount)
        let localFrames = Int(local.frameLength)
        let remoteFrames = Int(remote.frameLength)
        for channel in 0..<Int(out.format.channelCount) {
            let remoteChannel = theirs[min(channel, remoteChannels - 1)]
            for frame in 0..<frames {
                var voice: Float = 0
                if frame < localFrames {
                    for localChannel in 0..<localChannels { voice += mine[localChannel][frame] }
                    voice /= Float(localChannels)
                }
                let other = frame < remoteFrames ? remoteChannel[frame] : 0
                mixed[channel][frame] = max(-1, min(1, voice + other))
            }
        }
        out.frameLength = AVAudioFrameCount(frames)
    }
}
