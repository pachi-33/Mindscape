import Sparkle
import XCTest
@testable import Mindscape

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testExistingPreferenceSurvivesAndUpstreamStateDoesNotThrottleNewSource() throws {
        let suite = "update-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let fresh = UpdateChecker(defaults: defaults)
        XCTAssertFalse(fresh.autoCheckEnabled)
        XCTAssertTrue(fresh.needsAutoCheckConsent)
        XCTAssertFalse(fresh.shouldCheck(manual: false, atLaunch: true, now: now))

        fresh.resolveAutoCheckConsent(accepted: true)
        defaults.set(now, forKey: "updates.lastCheckAt")
        defaults.set("99.0.0", forKey: "updates.skippedVersion")
        let migrated = UpdateChecker(defaults: defaults)
        XCTAssertTrue(migrated.autoCheckEnabled)
        XCTAssertFalse(migrated.needsAutoCheckConsent)
        XCTAssertTrue(migrated.shouldCheck(manual: false, atLaunch: false, now: now))

        defaults.set(now, forKey: "ownReleaseUpdates.lastCheck")
        XCTAssertFalse(migrated.shouldCheck(manual: false, atLaunch: false, now: now))
        XCTAssertTrue(migrated.shouldCheck(manual: false, atLaunch: true, now: now))
        XCTAssertTrue(migrated.shouldCheck(manual: true, atLaunch: false, now: now))
        XCTAssertTrue(migrated.shouldCheck(manual: false, atLaunch: false, now: now.addingTimeInterval(86_400)))
    }

    func testCandidateMustBeNewerAndMatchOwnReleaseAndChannel() throws {
        let stable = UpdateChecker(bundle: try fixtureBundle(version: "0.7.0"))
        let beta = UpdateChecker(bundle: try fixtureBundle(version: "0.7.1-beta.1"))
        let stableVersion = "0.7.1"
        let betaVersion = "0.7.1-beta.2"
        let root = "https://github.com/pachi-33/Mindscape/releases/download"
        func url(_ version: String) -> URL {
            URL(string: "\(root)/v\(version)/Mindscape-\(version).zip")!
        }
        XCTAssertNotNil(stable.eligibleVersion(stableVersion, archive: url(stableVersion)))
        XCTAssertNil(stable.eligibleVersion("0.7.0", archive: url("0.7.0")))
        XCTAssertNil(stable.eligibleVersion(betaVersion, archive: url(betaVersion)))
        XCTAssertNotNil(beta.eligibleVersion(betaVersion, archive: url(betaVersion)))
        XCTAssertNotNil(beta.eligibleVersion(stableVersion, archive: url(stableVersion)))
        XCTAssertNil(stable.eligibleVersion(stableVersion, archive: url(betaVersion)))
        XCTAssertNil(stable.eligibleVersion(stableVersion, archive:
            URL(string: "https://github.com/jiuxianzai/Mindscape/releases/download/v0.7.1/Mindscape-0.7.1.zip")!))
        XCTAssertNil(stable.eligibleVersion(stableVersion, archive: URL(string: "http://127.0.0.1/update.zip")!))
    }

    func testSaveFailureCancelsPreparedInstallation() {
        let checker = UpdateChecker()
        checker.prepareToInstall = { throw UpdateError.inMemoryLibrary }
        XCTAssertEqual(checker.prepareVerifiedInstallation(), .skip)
        XCTAssertFalse(checker.isPreparingApplication)
        guard case .failed(let message) = checker.phase else { return XCTFail("missing save failure") }
        XCTAssertEqual(message, UpdateError.inMemoryLibrary.localizedDescription)
    }

    func testQuitAlsoRequiresSuccessfulSaveAfterHandoff() {
        let checker = UpdateChecker()
        checker.prepareToInstall = {}
        checker.recheckBeforeQuit = { throw UpdateError.saveUnavailable }
        XCTAssertEqual(checker.prepareVerifiedInstallation(), .install)
        XCTAssertTrue(checker.isPreparingApplication)
        XCTAssertEqual(checker.evaluateExit(continueAfterCancellation: { _ in }), .stayOpen)
    }

    func testSignatureFailureIsVisibleAndDoesNotAllowInstallation() {
        let checker = UpdateChecker()
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))
        var acknowledged = false
        checker.showUpdaterError(error, acknowledgement: { acknowledged = true })
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(checker.isPreparingApplication)
        guard case .failed = checker.phase else { return XCTFail("missing signature failure") }
    }

    func testPreparedUpdateWithoutUserAuthorizationIsCancelled() {
        let checker = UpdateChecker()
        checker.prepareToInstall = { XCTFail("unexpected save") }
        var choice: SPUUserUpdateChoice?
        checker.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .skip)
        XCTAssertFalse(checker.isPreparingApplication)
    }

    func testCancellingDownloadClearsCancellationAndPreventsInstall() {
        let checker = UpdateChecker()
        var cancellationCount = 0
        checker.showDownloadInitiated { cancellationCount += 1 }
        XCTAssertTrue(checker.canCancel)
        checker.cancel()
        checker.cancel()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(checker.canCancel)
        checker.showReady(toInstallAndRelaunch: { XCTAssertEqual($0, .skip) })
        checker.finishSession(error: nil)
        XCTAssertEqual(checker.evaluateExit(continueAfterCancellation: { _ in XCTFail("unexpected pending exit") }), .allow)
    }

    func testQuitDuringDownloadWaitsForCancellationAndChecksSaveAgain() {
        let checker = UpdateChecker()
        var cancellationCount = 0
        var firstSave = true
        checker.recheckBeforeQuit = {
            guard firstSave else { throw UpdateError.saveUnavailable }
            firstSave = false
        }
        checker.showDownloadInitiated { cancellationCount += 1 }
        var permission: Bool?
        XCTAssertEqual(checker.evaluateExit { permission = $0 }, .cancelUpdateFirst)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(permission)
        checker.showReady(toInstallAndRelaunch: { XCTAssertEqual($0, .skip) })
        checker.finishSession(error: nil)
        XCTAssertEqual(permission, false)
        guard case .failed = checker.phase else { return XCTFail("missing save failure") }
    }

    func testDownloadAndPermissionErrorsKeepRecoveryAvailable() {
        let checker = UpdateChecker()
        for code in [SUError.downloadError, .installationWriteNoPermissionError] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue))
            checker.showUpdaterError(error, acknowledgement: {})
            guard case .failed(let message) = checker.phase else { return XCTFail("missing recovery state") }
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(checker.isPreparingApplication)
        }
    }

    private func fixtureBundle(version: String) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bundle")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.youyanping.mindscape.update-tests",
            "CFBundleShortVersionString": version
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: url))
    }
}
