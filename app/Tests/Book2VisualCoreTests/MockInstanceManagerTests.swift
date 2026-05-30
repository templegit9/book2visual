import XCTest
@testable import Book2VisualCore

final class MockInstanceManagerTests: XCTestCase {

    func testStartTransitionsStoppedToStartingToRunning() async throws {
        let manager = MockInstanceManager()
        let endpoint = try await manager.start()
        XCTAssertEqual(endpoint.ip, "10.0.0.2")
        let transitions = await manager.transitions
        XCTAssertEqual(transitions, [
            .stopped,
            .starting,
            .running(ip: "10.0.0.2", port: 22)
        ])
        let status = await manager.currentStatus()
        XCTAssertTrue(status.isRunning)
    }

    func testStopTransitionsToStopped() async throws {
        let manager = MockInstanceManager(initial: .running(ip: "10.0.0.2", port: 22))
        try await manager.stop()
        let status = await manager.currentStatus()
        XCTAssertEqual(status, .stopped)
        let transitions = await manager.transitions
        XCTAssertEqual(transitions.last, .stopped)
        XCTAssertTrue(transitions.contains(.stopping))
    }

    func testInjectedFailurePutsManagerInError() async {
        let manager = MockInstanceManager()
        await manager.injectFailure(ThunderError.timedOut)
        do {
            _ = try await manager.start()
            XCTFail("Expected failure")
        } catch {
            let status = await manager.currentStatus()
            if case .error = status {} else { XCTFail("Expected error status, got \(status)") }
        }
    }

    func testPrepareEnvironmentRunsAllPhasesAndEndsRunning() async throws {
        let manager = MockInstanceManager()
        try await manager.prepareEnvironment { _ in }
        let phases = await manager.preparePhases
        XCTAssertEqual(phases.count, 4)
        let status = await manager.currentStatus()
        XCTAssertTrue(status.isRunning)
    }

    func testStatusLightMapping() {
        XCTAssertEqual(InstanceStatus.stopped.light, .grey)
        XCTAssertEqual(InstanceStatus.starting.light, .yellow)
        XCTAssertEqual(InstanceStatus.stopping.light, .yellow)
        XCTAssertEqual(InstanceStatus.running(ip: "x", port: 22).light, .green)
        XCTAssertEqual(InstanceStatus.error("boom").light, .red)
    }
}
