import Foundation

/// Contents of session.json: everything needed to make sense of the recording later.
struct SessionInfo: Codable {
    struct Track: Codable {
        var file = ""
        var channels = 0
        var frames: Int64 = 0
        var seconds: Double = 0
        var silenceInsertedFrames: Int64 = 0
        var maxPeakDBFS: Double?
    }

    var app = "CallRecorder 0.1"
    var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var source: String
    var startedAt: Date
    var endedAt: Date?
    var completed = false
    var stopReason: String?
    var processes: [String]
    var microphone = ""
    var outputDevice = ""
    var sampleRate: Double = 0
    var tapFormat = ""
    var aggregateInputChannels: [Int] = []
    var micBufferIndex = 0
    var tapBufferIndex = 0
    var firstCallbackBuffers = ""
    var ioCallbacks = 0
    var local = Track()
    var remote = Track()
    var problems: [String] = []
    var events: [String] = []
    var files: [String] = []
}
