import XCTest
@testable import Mindscape

final class SemanticVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemanticVersion(tag: "v0.5.10")?.description, "0.5.10")
        XCTAssertEqual(SemanticVersion(tag: "0.5")?.description, "0.5.0")
        XCTAssertEqual(SemanticVersion(tag: "1")?.description, "1.0.0")
        XCTAssertEqual(SemanticVersion(tag: "  v1.2.3  ")?.description, "1.2.3")
        XCTAssertNil(SemanticVersion(tag: ""))
        XCTAssertNil(SemanticVersion(tag: "v"))
        XCTAssertNil(SemanticVersion(tag: "release-1.0"))
        XCTAssertNil(SemanticVersion(tag: "1.2.3.4"))
        XCTAssertNil(SemanticVersion(tag: "1.a.3"))
    }

    func testOrdering() {
        XCTAssertLessThan(SemanticVersion(tag: "0.5.9")!, SemanticVersion(tag: "0.5.10")!)
        XCTAssertLessThan(SemanticVersion(tag: "0.5.3")!, SemanticVersion(tag: "0.6.0")!)
        XCTAssertLessThan(SemanticVersion(tag: "0.9.9")!, SemanticVersion(tag: "1.0.0")!)
        XCTAssertLessThan(SemanticVersion(tag: "1.0.0-beta.2")!, SemanticVersion(tag: "1.0.0")!)
        XCTAssertLessThan(SemanticVersion(tag: "1.0.0-beta.2")!, SemanticVersion(tag: "1.0.0-beta.10")!)
        XCTAssertEqual(SemanticVersion(tag: "0.5")!, SemanticVersion(tag: "0.5.0")!)
    }
}
