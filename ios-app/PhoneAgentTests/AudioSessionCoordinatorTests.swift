import XCTest
@testable import PhoneAgent

private final class SessionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0
    var pending: AudioSessionCoordinator.Completion?
    var hold = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    func activate(_ completion: @escaping AudioSessionCoordinator.Completion) {
        lock.lock(); _starts += 1; let delay = hold
        if delay { pending = completion }; lock.unlock()
        if !delay { completion(true) }
    }
    func deactivate(_ completion: @escaping @Sendable () -> Void) {
        lock.lock(); _stops += 1; lock.unlock(); completion()
    }
    func finish() { lock.lock(); let completion = pending; pending = nil; hold = false; lock.unlock(); completion?(true) }
}
final class AudioSessionCoordinatorTests: XCTestCase {
    func testBothOrdersOnlyLastReleaseDeactivatesAndStaleReleaseIsHarmless() async throws {
        for reverse in [false, true] {
            let probe = SessionProbe(), owner = UUID()
            let session = AudioSessionCoordinator(activate: { probe.activate($0) }, deactivate: { probe.deactivate($0) })
            let audio = AudioSessionToken(owner: owner, generation: UUID()), pip = AudioSessionToken(owner: UUID(), generation: UUID())
            if reverse { try await session.acquire(pip); try await session.acquire(audio) }
            else { try await session.acquire(audio); try await session.acquire(pip) }
            XCTAssertEqual(probe.starts, 1)
            session.release(audio); session.release(audio); await session.drain()
            XCTAssertEqual(probe.stops, 0)
            let next = AudioSessionToken(owner: owner, generation: UUID())
            try await session.acquire(next); session.release(audio); session.release(pip); await session.drain()
            XCTAssertEqual(probe.stops, 0)
            session.release(next); await session.drain(); XCTAssertEqual(probe.stops, 1)
        }
    }
    func testReleaseDuringPendingActivationAndNextOwnerAreSerialized() async throws {
        let probe = SessionProbe(); probe.hold = true
        let session = AudioSessionCoordinator(activate: { probe.activate($0) }, deactivate: { probe.deactivate($0) })
        let old = AudioSessionToken(owner: UUID(), generation: UUID())
        let pending = Task { try await session.acquire(old) }
        while probe.starts == 0 { await Task.yield() }
        session.release(old); probe.finish(); try await pending.value; await session.drain()
        XCTAssertEqual(probe.stops, 1)
        let next = AudioSessionToken(owner: old.owner, generation: UUID())
        try await session.acquire(next); session.release(old); await session.drain(); XCTAssertEqual(probe.stops, 1)
        session.release(next); await session.drain(); XCTAssertEqual(probe.stops, 2)
    }
}
