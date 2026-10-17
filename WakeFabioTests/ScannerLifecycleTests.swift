import XCTest
@testable import WakeFabio

final class ScannerLifecycleTests: XCTestCase {
    func testControllerCanDeallocateBeforeLoadingCamera() async {
        await MainActor.run {
            weak var releasedController: ScannerSessionViewController?
            autoreleasepool {
                let controller = ScannerSessionViewController()
                releasedController = controller
                // Reproduces cleanup in deinit without requiring camera hardware.
            }
            XCTAssertNil(releasedController)
        }
    }

    func testRepeatedDismissalThenDeallocationDoesNotRetainController() async {
        await MainActor.run {
            for _ in 0..<20 {
                weak var releasedController: ScannerSessionViewController?
                autoreleasepool {
                    let controller = ScannerSessionViewController()
                    releasedController = controller
                    controller.viewWillDisappear(false)
                    controller.viewWillDisappear(false)
                }
                XCTAssertNil(releasedController)
            }
        }
    }
}
