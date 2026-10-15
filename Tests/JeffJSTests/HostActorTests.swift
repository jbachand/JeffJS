// HostActorTests.swift
// JeffJS — `JeffJSHostActor` (Core/JeffJSHostActor.swift) runs on the main actor's
// executor unless a host installs its own, so the CLI and the tests see no change.

import Foundation
import XCTest
@testable import JeffJS

final class HostActorTests: XCTestCase {
    func testDefaultExecutorIsTheMainActor() {
        XCTAssertTrue(JeffJSHost.usesMainExecutor)
    }

    @JeffJSHostActor
    func testHostActorWorkRunsOnTheMainThread() async {
        let onMain = await Task { @JeffJSHostActor in Thread.isMainThread }.value
        XCTAssertTrue(onMain)
    }
}
