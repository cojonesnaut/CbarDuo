import Foundation
import XCTest
@testable import CbarDuo

final class InstallationLocationTests: XCTestCase {
    func testMountedDiskImageBundleIsDetected() {
        let bundleURL = URL(fileURLWithPath: "/Volumes/CbarDuo 1.3.0/CbarDuo.app")
        XCTAssertTrue(InstallationLocation.isRunningFromDiskImage(bundleURL: bundleURL))
        XCTAssertTrue(InstallationLocation.shouldOfferApplicationsHelp(bundleURL: bundleURL, hasPresentedThisLaunch: false))
    }

    func testNonVolumeApplicationAndDevelopmentPathsDoNotPretendToBeDiskImages() {
        XCTAssertFalse(InstallationLocation.isRunningFromDiskImage(bundleURL: URL(fileURLWithPath: "/Applications/CbarDuo.app")))
        XCTAssertFalse(InstallationLocation.isRunningFromDiskImage(bundleURL: URL(fileURLWithPath: "/Users/example/Applications/CbarDuo.app")))
        XCTAssertFalse(InstallationLocation.isRunningFromDiskImage(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/CbarDuo.app")))
        XCTAssertFalse(InstallationLocation.isRunningFromDiskImage(bundleURL: URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/CbarDuo.app")))
        XCTAssertFalse(InstallationLocation.isRunningFromDiskImage(bundleURL: URL(fileURLWithPath: "/VolumesBackup/CbarDuo.app")))
    }

    func testPromptIsOncePerLaunchDecision() {
        let bundleURL = URL(fileURLWithPath: "/Volumes/CbarDuo/CbarDuo.app")
        XCTAssertFalse(InstallationLocation.shouldOfferApplicationsHelp(bundleURL: bundleURL, hasPresentedThisLaunch: true))
    }
}
