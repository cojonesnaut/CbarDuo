import CoreAudio
import XCTest
@testable import CbarDuo

final class VolumeWriteCoalescerTests: XCTestCase {
    func testSlowWritesAreCoalescedToTheLatestLevel() {
        let lock = NSLock()
        var written: [Float32] = []
        let finished = expectation(description: "drained")
        finished.assertForOverFulfill = false
        let writer = VolumeWriteCoalescer(
            label: "test.volume",
            write: { job in
                Thread.sleep(forTimeInterval: 0.005) // a slow hardware write
                lock.lock(); written.append(job.level); lock.unlock()
            },
            onWritten: {
                lock.lock(); let last = written.last; lock.unlock()
                if last == 1.0 { finished.fulfill() }
            }
        )
        let address = AudioObjectPropertyAddress(mSelector: 0, mScope: 0, mElement: 0)
        for step in 0...100 {
            writer.submit(.init(device: 1, addresses: [address], level: Float32(step) / 100))
        }
        wait(for: [finished], timeout: 2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(written.last, 1.0, "the final level must always be written")
        XCTAssertLessThan(written.count, 101, "intermediate levels should be skipped while a write is in flight")
    }

    func testSubmitDoesNotWaitForTheWrite() {
        let writer = VolumeWriteCoalescer(label: "test.volume.async", write: { _ in Thread.sleep(forTimeInterval: 0.05) }, onWritten: {})
        let address = AudioObjectPropertyAddress(mSelector: 0, mScope: 0, mElement: 0)
        let start = Date()
        for _ in 0..<20 { writer.submit(.init(device: 1, addresses: [address], level: 0.5)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.02, "submitting must return immediately")
    }
}
