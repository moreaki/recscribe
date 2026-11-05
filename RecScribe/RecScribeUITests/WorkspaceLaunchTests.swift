import XCTest

final class WorkspaceLaunchTests: XCTestCase {
    func testApplicationStartsWithoutLosingItsProcess() {
        let candidate = XCUIApplication()
        candidate.launch()
        XCTAssertTrue(candidate.wait(for: .runningForeground, timeout: 10))
        candidate.terminate()
    }
}
