@preconcurrency import CoreAudio
import Foundation

/// Applies volume writes on a background queue, always writing only the most
/// recent level. A Core Audio volume write can take ~20 ms on real hardware;
/// doing that on the main thread for every drag event made the slider stutter.
/// Intermediate levels submitted while a write is in flight are skipped.
final class VolumeWriteCoalescer: @unchecked Sendable {
    struct Job {
        let device: AudioObjectID
        let addresses: [AudioObjectPropertyAddress]
        let level: Float32
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Job?
    private var isDraining = false
    private let write: (Job) -> Void
    private let onWritten: () -> Void

    init(
        label: String,
        write: @escaping (Job) -> Void = VolumeWriteCoalescer.writeToHardware,
        onWritten: @escaping () -> Void
    ) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        self.write = write
        self.onWritten = onWritten
    }

    func submit(_ job: Job) {
        lock.lock()
        pending = job
        let startDraining = !isDraining
        isDraining = true
        lock.unlock()
        if startDraining {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                isDraining = false
                lock.unlock()
                break
            }
            pending = nil
            lock.unlock()
            write(job)
        }
        onWritten()
    }

    static func writeToHardware(_ job: Job) {
        var scalar = job.level
        for var address in job.addresses {
            _ = AudioObjectSetPropertyData(
                job.device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &scalar
            )
        }
    }
}
