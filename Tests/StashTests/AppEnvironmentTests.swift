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

    /// `STASH_LOG_KEY_TARGET=1` logs each key's target app (never what was typed) for checking
    /// expansion's attribution live.
    func testKeyTargetLoggingIsOptIn() {
        XCTAssertFalse(AppEnvironment.logsKeyTarget(in: [:]))
        XCTAssertFalse(AppEnvironment.logsKeyTarget(in: ["STASH_LOG_KEY_TARGET": "0"]))
        XCTAssertTrue(AppEnvironment.logsKeyTarget(in: ["STASH_LOG_KEY_TARGET": "1"]))
    }
}
