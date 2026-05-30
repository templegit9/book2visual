import XCTest
@testable import Book2VisualCore

@MainActor
final class RunViewModelTests: XCTestCase {

    private func makeOutputStore() -> OutputStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2v-tests-\(UUID().uuidString)", isDirectory: true)
        return OutputStore(root: dir)
    }

    func testSuccessfulRunReachesCompletionAndLoadsPages() async throws {
        let store = makeOutputStore()
        let client = MockJobClient(scenario: .success, totalScenes: 4, outputStore: store)
        let vm = RunViewModel(client: client, outputStore: store)
        vm.text = "A short story."
        vm.characters = [CharacterInput(name: "Hero")]

        var completionPages: [URL]?
        vm.onCompletion = { completionPages = $0 }

        await vm.run()

        XCTAssertEqual(vm.phase, .completed)
        XCTAssertEqual(vm.progressFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vm.scenesComplete, 4)
        XCTAssertEqual(vm.pages.count, 4, "All 4 pages should be unzipped and loaded")
        XCTAssertEqual(completionPages?.count, 4)
        XCTAssertNil(vm.lastError)
    }

    func testJobErrorPathSetsFailedPhase() async throws {
        let store = makeOutputStore()
        let client = MockJobClient(
            scenario: .error(code: "image_stage_failed", message: "FLUX crashed"),
            totalScenes: 4,
            outputStore: store
        )
        let vm = RunViewModel(client: client, outputStore: store)
        vm.text = "Story"
        vm.characters = [CharacterInput(name: "Hero")]

        await vm.run()

        guard case .failed(let message) = vm.phase else {
            return XCTFail("Expected failed phase, got \(vm.phase)")
        }
        XCTAssertTrue(message.contains("image_stage_failed"))
        XCTAssertTrue(vm.pages.isEmpty)
        XCTAssertNotNil(vm.lastError)
    }

    func testCancelPathStopsRun() async throws {
        let store = makeOutputStore()
        // Slow stream so we can cancel mid-flight.
        let client = MockJobClient(scenario: .success, totalScenes: 20, outputStore: store, interEventDelay: 50_000_000)
        let vm = RunViewModel(client: client, outputStore: store)
        vm.text = "Story"
        vm.characters = [CharacterInput(name: "Hero")]

        let runTask = Task { await vm.run() }
        // Let it start streaming.
        try await Task.sleep(nanoseconds: 120_000_000)
        await vm.cancel()
        await runTask.value

        XCTAssertEqual(vm.phase, .cancelled)
    }

    func testCanRunGuard() {
        let store = makeOutputStore()
        let client = MockJobClient(outputStore: store)
        let vm = RunViewModel(client: client, outputStore: store)

        XCTAssertFalse(vm.canRun(instanceRunning: true), "No text/characters yet")
        vm.text = "hello"
        // Default characters is one empty-name row -> validCharacters empty.
        XCTAssertFalse(vm.canRun(instanceRunning: true), "Empty character name should not enable Run")
        vm.characters = [CharacterInput(name: "Hero")]
        XCTAssertTrue(vm.canRun(instanceRunning: true))
        XCTAssertFalse(vm.canRun(instanceRunning: false), "Instance must be running")
    }

    func testMakeRequestTrimsAndDropsEmptyCharacters() {
        let store = makeOutputStore()
        let client = MockJobClient(outputStore: store)
        let vm = RunViewModel(client: client, outputStore: store)
        vm.text = "  body  "
        vm.characters = [
            CharacterInput(name: "  Hero  ", raceHint: "  human "),
            CharacterInput(name: "   ")
        ]
        let req = vm.makeRequest()
        XCTAssertEqual(req.characters.count, 1)
        XCTAssertEqual(req.characters[0].name, "Hero")
        XCTAssertEqual(req.characters[0].raceHint, "human")
    }

    func testWordAndCharCount() {
        let store = makeOutputStore()
        let client = MockJobClient(outputStore: store)
        let vm = RunViewModel(client: client, outputStore: store)
        vm.text = "one two three"
        XCTAssertEqual(vm.wordCount, 3)
        XCTAssertEqual(vm.charCount, 13)
    }
}
