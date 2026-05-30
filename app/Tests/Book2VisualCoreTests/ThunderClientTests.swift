import XCTest
@testable import Book2VisualCore

/// Programmable HTTP transport for ThunderClient tests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Data, HTTPURLResponse)
    private let handler: Handler
    init(handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, resp) = handler(request)
        return (data, resp)
    }
}

private func ok(_ json: String, url: URL = URL(string: "https://api.thundercompute.com:8443")!) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

final class ThunderClientTests: XCTestCase {

    func testListInstancesDecodesArray() async throws {
        let transport = StubTransport { _ in
            ok("""
            [{"id":"i-1","status":"RUNNING","ip":"1.2.3.4","port":22,"gpu_type":"a100"}]
            """)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "token" })
        let instances = try await client.listInstances()
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].id, "i-1")
        XCTAssertTrue(instances[0].isRunning)
        XCTAssertEqual(instances[0].ip, "1.2.3.4")
        XCTAssertEqual(instances[0].gpuType, "a100")
    }

    func testListInstancesDecodesEnvelope() async throws {
        let transport = StubTransport { _ in
            ok("""
            {"instances":[{"id":"i-2","status":"STOPPED","ip":null,"port":null,"gpu_type":"a100"}]}
            """)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "token" })
        let instances = try await client.listInstances()
        XCTAssertEqual(instances.first?.id, "i-2")
        XCTAssertFalse(instances.first!.isRunning)
    }

    func testMissingTokenThrows() async {
        let transport = StubTransport { _ in ok("[]") }
        let client = ThunderClient(transport: transport, tokenProvider: { "" })
        do {
            _ = try await client.listInstances()
            XCTFail("Expected missingToken")
        } catch let error as ThunderError {
            XCTAssertEqual(error, .missingToken)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testHTTPErrorSurfaced() async {
        let transport = StubTransport { req in
            (Data("nope".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "t" })
        do {
            _ = try await client.listInstances()
            XCTFail("Expected http error")
        } catch let ThunderError.http(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testCreateInstanceSendsPublicKeyAndDecodesId() async throws {
        let received = LockedBox<URLRequest?>(nil)
        let transport = StubTransport { req in
            received.value = req
            return ok(#"{"id":"new-instance"}"#)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "t" })
        let resp = try await client.createInstance(publicKey: "ssh-ed25519 AAAA", gpuType: "a100")
        XCTAssertEqual(resp.id, "new-instance")
        let body = try XCTUnwrap(received.value?.httpBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["public_key"] as? String, "ssh-ed25519 AAAA")
        XCTAssertEqual(obj["gpu_type"] as? String, "a100")
        XCTAssertEqual(obj["mode"] as? String, "production")
        let auth = received.value?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer t")
    }

    func testPollUntilRunningSucceedsAfterRetries() async throws {
        let calls = LockedBox<Int>(0)
        let transport = StubTransport { _ in
            calls.value += 1
            if calls.value < 3 {
                return ok(#"[{"id":"i-1","status":"STARTING","ip":null,"port":null,"gpu_type":"a100"}]"#)
            }
            return ok(#"[{"id":"i-1","status":"RUNNING","ip":"9.9.9.9","port":22,"gpu_type":"a100"}]"#)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "t" })
        let inst = try await client.pollUntilRunning(id: "i-1", interval: 0, timeout: 10, sleeper: { _ in })
        XCTAssertEqual(inst.ip, "9.9.9.9")
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    func testPollUntilRunningTimesOut() async {
        let transport = StubTransport { _ in
            ok(#"[{"id":"i-1","status":"STARTING","ip":null,"port":null,"gpu_type":"a100"}]"#)
        }
        let client = ThunderClient(transport: transport, tokenProvider: { "t" })
        do {
            _ = try await client.pollUntilRunning(id: "i-1", interval: 0, timeout: 0, sleeper: { _ in })
            XCTFail("Expected timeout")
        } catch let error as ThunderError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}

/// Tiny thread-safe box for capturing values from @Sendable closures in tests.
final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
