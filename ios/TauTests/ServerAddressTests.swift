import XCTest

/// Server addresses as typed (Tau/Settings/ServerAddress.swift).
final class ServerAddressTests: XCTestCase {
    func testABareHostGetsWebSocketsAndTausPort() {
        XCTAssertEqual(normalizedServerAddress("my-mac.example.ts.net"), "ws://my-mac.example.ts.net:7878")
        XCTAssertEqual(normalizedServerAddress("  192.168.1.5  "), "ws://192.168.1.5:7878")
        XCTAssertEqual(normalizedServerAddress("my-mac:8000"), "ws://my-mac:8000")
    }

    func testASchemeKeepsItsOwnDefaultPort() {
        XCTAssertEqual(normalizedServerAddress("ws://tau.example.com"), "ws://tau.example.com")
        XCTAssertEqual(normalizedServerAddress("wss://tau.example.com"), "wss://tau.example.com")
        XCTAssertEqual(normalizedServerAddress("ws://tau.example.com:7878"), "ws://tau.example.com:7878")
    }

    func testABrowsersAddressIsTakenAsWebSockets() {
        XCTAssertEqual(normalizedServerAddress("https://my-mac.example.ts.net/"), "wss://my-mac.example.ts.net")
        XCTAssertEqual(normalizedServerAddress("HTTPS://my-mac.example.ts.net"), "wss://my-mac.example.ts.net")
        XCTAssertEqual(normalizedServerAddress("http://localhost:7878"), "ws://localhost:7878")
    }

    func testWhatIsNoAddress() {
        XCTAssertNil(normalizedServerAddress(""))
        XCTAssertNil(normalizedServerAddress("ftp://example.com"))
        XCTAssertNil(normalizedServerAddress("ws://"))
    }

    func testTheShownAddressDropsWebSocketsOnlyWhereThatLosesNothing() {
        XCTAssertEqual(displayedServerAddress("ws://my-mac:7878"), "my-mac:7878")
        XCTAssertEqual(displayedServerAddress("ws://tau.example.com"), "ws://tau.example.com")
        XCTAssertEqual(displayedServerAddress("wss://tau.example.com"), "wss://tau.example.com")
    }
}
