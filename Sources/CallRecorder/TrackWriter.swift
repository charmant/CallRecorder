import Accelerate
import AudioToolbox
import Foundation
import Synchronization

/// Recording track: the IOProc puts samples into a ring buffer, the writer thread flushes them to CAF.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    let channels: Int
    let sampleRate: Double
    let ring: SampleRingBuffer

    private var file: ExtAudioFileRef?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchSamples: Int
    private let startUptime = DispatchTime.now().uptimeNanoseconds

    // Modified only by the writer thread; read after stop.
    private(set) var framesWritten: Int64 = 0
    private(set) var silenceInsertedFrames: Int64 = 0
    private(set) var maxPeak: Float = 0

    // For UI indicators.
    private let currentPeak = Atomic<UInt32>(0)
    private let lastSoundUptime = Atomic<UInt64>(0)

    init(url: URL, channels: Int, sampleRate: Double) throws {
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        ring = SampleRingBuffer(capacity: Int(sampleRate) * channels * 20) // 20 s of headroom for disk latency
        scratchSamples = Int(sampleRate / 2) * channels
        scratch = .allocate(capacity: scratchSamples)
        file = try Self.createFile(url: url, channels: channels, sampleRate: sampleRate)
    }

    deinit {
        close()
        scratch.deallocate()
    }

    var peak: Float { Float(bitPattern: currentPeak.load(ordering: .relaxed)) }
    var everHadSound: Bool { lastSoundUptime.load(ordering: .relaxed) != 0 }

    /// Seconds of digital silence (exact zeros) on the track.
    var secondsSinceSound: TimeInterval {
        let last = lastSoundUptime.load(ordering: .relaxed)
        return Double(DispatchTime.now().uptimeNanoseconds - (last == 0 ? startUptime : last)) / 1e9
    }

    /// Writer thread: drain the ring buffer and write it to disk.
    func drain() throws {
        guard let file else { return }
        let dropped = ring.takeDropped()
        if dropped > 0 {
            try writeSilence(file, frames: dropped / channels)
        }
        var peak: Float = 0
        while true {
            let count = ring.read(into: scratch, maxCount: scratchSamples)
            guard count > 0 else { break }
            var chunkPeak: Float = 0
            vDSP_maxmgv(scratch, 1, &chunkPeak, vDSP_Length(count))
            peak = max(peak, chunkPeak)
            try write(file, frames: count / channels)
        }
        maxPeak = max(maxPeak, peak)
        currentPeak.store(peak.bitPattern, ordering: .relaxed)
        if peak > 0 {
            lastSoundUptime.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        }
    }

    func close() {
        if let file {
            ExtAudioFileDispose(file)
            self.file = nil
        }
    }

    func summary(file name: String) -> SessionInfo.Track {
        SessionInfo.Track(
            file: name,
            channels: channels,
            frames: framesWritten,
            seconds: (Double(framesWritten) / sampleRate * 100).rounded() / 100,
            silenceInsertedFrames: silenceInsertedFrames,
            maxPeakDBFS: dbfs(maxPeak)
        )
    }

    private func write(_ file: ExtAudioFileRef, frames: Int) throws {
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(scratch)
            )
        )
        try check(ExtAudioFileWrite(file, UInt32(frames), &list), "Writing \(url.lastPathComponent)")
        framesWritten += Int64(frames)
    }

    private func writeSilence(_ file: ExtAudioFileRef, frames: Int) throws {
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, scratchSamples / channels)
            scratch.update(repeating: 0, count: chunk * channels)
            try write(file, frames: chunk)
            remaining -= chunk
        }
        silenceInsertedFrames += Int64(frames)
    }

    /// CAF, 16-bit. The header size is updated on every write, so after a crash
    /// what has already been written remains readable.
    private static func createFile(url: URL, channels: Int, sampleRate: Double) throws -> ExtAudioFileRef {
        let channelCount = UInt32(channels)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var created: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created),
            "Creating \(url.lastPathComponent)"
        )
        guard let file = created else { throw RecorderError("Couldn't create \(url.lastPathComponent)") }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat),
            "Format of \(url.lastPathComponent)"
        )

        var audioFile: AudioFileID?
        var size = UInt32(MemoryLayout<AudioFileID?>.size)
        if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile) == noErr, let audioFile {
            var deferUpdates: UInt32 = 0
            AudioFileSetProperty(audioFile, kAudioFilePropertyDeferSizeUpdates, UInt32(MemoryLayout<UInt32>.size), &deferUpdates)
        }
        return file
    }
}
