import XCTest
@testable import Book2VisualCore

final class SecretAndTunnelTests: XCTestCase {

    func testInMemorySecretStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.get("k"))
        try store.set("secret", for: "k")
        XCTAssertEqual(try store.get("k"), "secret")
        try store.delete("k")
        XCTAssertNil(try store.get("k"))
    }

    func testSSHTunnelArgumentsUseUbuntuAndForward() {
        let config = SSHTunnelConfig(
            localPort: 8123,
            remotePort: 8000,
            host: "5.6.7.8",
            sshPort: 2222,
            keyPath: "/tmp/key",
            user: "ubuntu"
        )
        let args = config.arguments
        XCTAssertEqual(args.first, "-N")
        XCTAssertTrue(args.contains("8123:127.0.0.1:8000"))
        XCTAssertTrue(args.contains("ubuntu@5.6.7.8"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(args.contains("ServerAliveInterval=30"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
        // -p and the ssh port present
        XCTAssertTrue(args.contains("2222"))
    }

    func testSSHTunnelMissingKeyThrows() async {
        let tunnel = SSHTunnel()
        let config = SSHTunnelConfig(host: "1.2.3.4", keyPath: "/nonexistent/key/path")
        do {
            try await tunnel.start(config: config)
            XCTFail("Expected missing key error")
        } catch let error as SSHTunnelError {
            XCTAssertEqual(error, .missingKey)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}
