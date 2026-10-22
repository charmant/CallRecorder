import Synchronization

/// Sample ring buffer: one writer (the audio thread) and one reader (the disk-writing thread).
/// Writing never blocks or allocates; on overflow the data is dropped and the dropped
/// count is remembered so the reader can insert the same amount of silence and the tracks stay aligned.
final class SampleRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writePosition = Atomic<Int>(0)
    private let readPosition = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Called from the audio thread.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard let start = reserve(count) else { return }
        let first = min(count, capacity - start)
        (storage + start).update(from: source, count: first)
        if first < count {
            storage.update(from: source + first, count: count - first)
        }
        commit(count)
    }

    /// Called from the audio thread when there is no data for the track in this cycle.
    func writeSilence(count: Int) {
        guard let start = reserve(count) else { return }
        let first = min(count, capacity - start)
        (storage + start).update(repeating: 0, count: first)
        if first < count {
            storage.update(repeating: 0, count: count - first)
        }
        commit(count)
    }

    /// Called from the writer thread. Returns the number of samples read.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let read = readPosition.load(ordering: .relaxed)
        let written = writePosition.load(ordering: .acquiring)
        let count = min(written - read, maxCount)
        guard count > 0 else { return 0 }
        let start = read % capacity
        let first = min(count, capacity - start)
        destination.update(from: storage + start, count: first)
        if first < count {
            (destination + first).update(from: storage, count: count - first)
        }
        readPosition.store(read + count, ordering: .releasing)
        return count
    }

    /// Number of samples dropped since the last call.
    func takeDropped() -> Int {
        dropped.exchange(0, ordering: .relaxed)
    }

    private func reserve(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        let written = writePosition.load(ordering: .relaxed)
        let read = readPosition.load(ordering: .acquiring)
        guard capacity - (written - read) >= count else {
            _ = dropped.wrappingAdd(count, ordering: .relaxed)
            return nil
        }
        return written % capacity
    }

    private func commit(_ count: Int) {
        writePosition.store(writePosition.load(ordering: .relaxed) + count, ordering: .releasing)
    }
}
