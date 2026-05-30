import XCTest
@testable import Book2VisualCore

final class SSEAndZipTests: XCTestCase {

    func testParseSSEDataDecodesProgressEvent() {
        let json = #"{"type":"scene_complete","job_id":"j","scene_index":1,"total_scenes":4,"message":"ok","ts":"2026-05-29T18:00:00Z"}"#
        let event = HTTPJobClient.parseSSEData(json)
        XCTAssertEqual(event?.type, .sceneComplete)
        XCTAssertEqual(event?.sceneIndex, 1)
    }

    func testParseSSEDataIgnoresBlank() {
        XCTAssertNil(HTTPJobClient.parseSSEData("   "))
        XCTAssertNil(HTTPJobClient.parseSSEData(""))
    }

    func testTinyZipUnzipsToPNGPages() throws {
        let names = ["page_000.png", "page_001.png", "page_002.png"]
        let zip = try MockJobClient.makeTinyZip(pageNames: names)
        XCTAssertFalse(zip.isEmpty)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2v-zip-\(UUID().uuidString)", isDirectory: true)
        let store = OutputStore(root: dir)
        let outDir = try store.saveAndUnzip(zipData: zip, jobId: "job1")
        let pages = store.pages(in: outDir)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map { $0.lastPathComponent }, names)
        // Each page is a valid (non-empty) PNG.
        for page in pages {
            let data = try Data(contentsOf: page)
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic")
        }
    }

    func testDefaultZipNameFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 29
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let name = ViewerView.defaultZipName(slug: "kafka", date: date)
        XCTAssertEqual(name, "book2visual-kafka-2026-05-29.zip")
    }
}
