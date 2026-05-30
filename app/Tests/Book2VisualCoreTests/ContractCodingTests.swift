import XCTest
@testable import Book2VisualCore

final class ContractCodingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: JobRequest

    func testJobRequestDecodesFromContractSample() throws {
        let data = try fixture("job_request")
        let req = try ContractCoding.decoder().decode(JobRequest.self, from: data)
        XCTAssertEqual(req.characters.count, 2)
        XCTAssertEqual(req.characters[0].name, "Gregor Samsa")
        XCTAssertEqual(req.characters[0].raceHint, "human")
        XCTAssertNil(req.characters[1].raceHint)
        XCTAssertEqual(req.vramMode, .concurrent)
        XCTAssertEqual(req.consistencyMode, .kontext)
    }

    func testJobRequestRoundTripPreservesSnakeCaseKeys() throws {
        let req = JobRequest(
            text: "hi",
            characters: [CharacterInput(name: "A", raceHint: "elf")],
            vramMode: .sequenced,
            consistencyMode: .lora
        )
        let encoded = try ContractCoding.encoder().encode(req)
        let obj = try jsonObject(encoded)
        XCTAssertEqual(obj["vram_mode"] as? String, "sequenced")
        XCTAssertEqual(obj["consistency_mode"] as? String, "lora")
        let chars = try XCTUnwrap(obj["characters"] as? [[String: Any]])
        XCTAssertEqual(chars.first?["race_hint"] as? String, "elf")

        // Decode back.
        let decoded = try ContractCoding.decoder().decode(JobRequest.self, from: encoded)
        XCTAssertEqual(decoded.vramMode, .sequenced)
        XCTAssertEqual(decoded.consistencyMode, .lora)
        XCTAssertEqual(decoded.characters.first?.raceHint, "elf")
    }

    func testJobRequestOmitsEmptyRaceHint() throws {
        let req = JobRequest(text: "hi", characters: [CharacterInput(name: "A", raceHint: "")])
        let encoded = try ContractCoding.encoder().encode(req)
        let obj = try jsonObject(encoded)
        let chars = try XCTUnwrap(obj["characters"] as? [[String: Any]])
        XCTAssertNil(chars.first?["race_hint"], "Empty race_hint must not be emitted")
    }

    // MARK: ProgressEvent

    func testProgressEventSceneCompleteDecodes() throws {
        let data = try fixture("progress_event_scene_complete")
        let event = try ContractCoding.decoder().decode(ProgressEvent.self, from: data)
        XCTAssertEqual(event.type, .sceneComplete)
        XCTAssertEqual(event.sceneIndex, 3)
        XCTAssertEqual(event.totalScenes, 8)
        XCTAssertFalse(event.type.isTerminal)
        XCTAssertEqual(try XCTUnwrap(event.progressFraction), 4.0 / 8.0, accuracy: 0.0001)
    }

    func testProgressEventJobCompleteDecodesPages() throws {
        let data = try fixture("progress_event_job_complete")
        let event = try ContractCoding.decoder().decode(ProgressEvent.self, from: data)
        XCTAssertEqual(event.type, .jobComplete)
        XCTAssertTrue(event.type.isTerminal)
        XCTAssertEqual(event.pages, 2)
        XCTAssertNil(event.sceneIndex)
        XCTAssertEqual(try XCTUnwrap(event.progressFraction), 1.0)
    }

    func testProgressEventJobErrorDecodesErrorCode() throws {
        let data = try fixture("progress_event_job_error")
        let event = try ContractCoding.decoder().decode(ProgressEvent.self, from: data)
        XCTAssertEqual(event.type, .jobError)
        XCTAssertTrue(event.type.isTerminal)
        XCTAssertEqual(event.errorCode, "image_stage_failed")
    }

    func testProgressEventRoundTrip() throws {
        let original = ProgressEvent(
            type: .sceneStart,
            jobId: "abc",
            sceneIndex: 0,
            totalScenes: 4,
            message: "start",
            ts: "2026-05-29T18:00:00Z"
        )
        let encoded = try ContractCoding.encoder().encode(original)
        let obj = try jsonObject(encoded)
        XCTAssertEqual(obj["job_id"] as? String, "abc")
        XCTAssertEqual(obj["scene_index"] as? Int, 0)
        XCTAssertEqual(obj["total_scenes"] as? Int, 4)
        let decoded = try ContractCoding.decoder().decode(ProgressEvent.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
