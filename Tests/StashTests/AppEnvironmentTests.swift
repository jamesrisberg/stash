import Foundation
import XCTest
@testable import Stash

/// `STASH_HOME` is the isolation variable.
final class AppEnvironmentTests: XCTestCase {
    func testHomeIsTheDataDirectory() {
        XCTAssertEqual(AppEnvironment.dataDirectory(in: ["STASH_HOME": "/tmp/a"])?.path, "/tmp/a")
    }

    func testUnsetOrEmptyMeansTheDefault() {
        XCTAssertNil(AppEnvironment.dataDirectory(in: [:]))
        XCTAssertNil(AppEnvironment.dataDirectory(in: ["STASH_HOME": ""]))
    }

    func testTildeExpands() {
        XCTAssertEqual(AppEnvironment.dataDirectory(in: ["STASH_HOME": "~/x"])?.path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("x"))
    }
}
