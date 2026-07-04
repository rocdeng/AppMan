import XCTest
@testable import AppManCore

final class LimitedConcurrentMapTests: XCTestCase {
    func testMapsWithConcurrencyLimitAndPreservesOrder() throws {
        let tracker = ConcurrencyTracker()

        let values = try LimitedConcurrentMap.map(Array(0..<9), limit: 3) { value in
            tracker.enter()
            Thread.sleep(forTimeInterval: 0.01)
            tracker.leave()
            return value * 2
        }

        XCTAssertEqual(values, [0, 2, 4, 6, 8, 10, 12, 14, 16])
        XCTAssertLessThanOrEqual(tracker.maxActive, 3)
        XCTAssertGreaterThan(tracker.maxActive, 1)
    }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maxActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
