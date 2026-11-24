import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateChecker: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double?), verifying, installing
        case failed(String)

        var isUpdating: Bool {
            switch self {
            case .downloading, .verifying, .installing: return true
            default: return false
            }
        }
    }

    struct Release {
        let version: SemanticVersion
        let build: String
        let notes: String
    }

    enum ExitDecision: Equatable {
        case allow, cancelUpdateFirst, stayOpen
    }

    private enum Key {
        static let autoCheck = "updates.autoCheck"
        static let didAskAutoCheck = "updates.didAskAutoCheck"
        static let lastCheck = "ownReleaseUpdates.lastCheck"
        static let dismissedBuild = "ownReleaseUpdates.dismissedBuild"
    }

    private static let repository = "pachi-33/Mindscape"
    private static let releasePage = URL(string: "https://github.com/\(repository)/releases")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var phase: Phase = .idle
    private(set) var release: Release?
    private(set) var bannerDismissed = false
    private(set) var isPreparingApplication = false
    private(set) var canCancel = false
    let installedVersion: SemanticVersion
    var installedVersionDescription: String { installedVersion.description }
    var isBetaChannel: Bool { installedVersion.prerelease != nil }

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var cancelSession: (() -> Void)?
    @ObservationIgnored private var requestedBuild: String?
    @ObservationIgnored private var authorizedBuild: String?
    @ObservationIgnored private var manualCheck = false
    @ObservationIgnored private var isPresentingConsent = false
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private var exitAfterCancellation: ((Bool) -> Void)?
    @ObservationIgnored var prepareToInstall: (() throws -> Void)?
    @ObservationIgnored var recheckBeforeQuit: (() throws -> Void)?

    var autoCheckEnabled: Bool {
        didSet {
            guard autoCheckEnabled != oldValue else { return }
            defaults.set(autoCheckEnabled, forKey: Key.autoCheck)
            if autoCheckEnabled {
                start()
            } else {
                launchTask?.cancel()
                periodicTask?.cancel()
                launchTask = nil
                periodicTask = nil
            }
        }
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.defaults = defaults
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        installedVersion = SemanticVersion(tag: version) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        autoCheckEnabled = defaults.object(forKey: Key.autoCheck) as? Bool ?? false
        super.init()
    }

    var channelDescription: String {
        isBetaChannel
            ? String(localized: "Beta 通道：会检测后续预发布版本")
            : String(localized: "稳定版通道：只检测正式版本")
    }

    var shouldShowBanner: Bool { phase == .available && !bannerDismissed }

    var statusDescription: String {
        switch phase {
        case .idle:
            if let lastCheck = defaults.object(forKey: Key.lastCheck) as? Date {
                return String(localized: "上次检查：\(RelativeDate.short(lastCheck))")
            }
            return String(localized: "尚未检查")
        case .checking: return String(localized: "正在检查…")
        case .upToDate: return String(localized: "暂无可用更新")
        case .available: return String(localized: "有可用更新")
        case .downloading: return String(localized: "正在下载…")
        case .verifying: return String(localized: "正在验证更新…")
        case .installing: return String(localized: "正在安装并重启…")
        case .failed: return String(localized: "更新失败")
        }
    }

    // MARK: - First-run consent

    /// 只在「从未问过、也没有写过偏好」时询问一次；老用户或已手动改过设置的用户不再打扰。
    var needsAutoCheckConsent: Bool {
        !defaults.bool(forKey: Key.didAskAutoCheck)
            && defaults.object(forKey: Key.autoCheck) == nil
    }

    func presentAutoCheckConsentIfNeeded(onFinish: (() -> Void)? = nil) {
        // 单元测试会以 App 为宿主启动，这里不弹窗，避免干扰测试。
        guard !Self.isRunningUnitTests, needsAutoCheckConsent, !isPresentingConsent else {
            onFinish?()
            return
        }
        guard let window = consentHostWindow else {
            onFinish?()
            return
        }

        isPresentingConsent = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "BrandMark")
        alert.messageText = String(localized: "是否自动检查更新？")
        alert.informativeText = String(localized: "开启后每次启动会检查一次，运行期间每 24 小时检查一次。关闭后只在你手动检查时联网。此选择可在「设置 → 通用 → 更新」中修改。")
        alert.addButton(withTitle: String(localized: "暂不"))
        alert.addButton(withTitle: String(localized: "开启自动检查"))

        // 用 sheet 而不是 runModal：不阻塞 App 主线程，窗口关掉也不会把进程卡住。
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingConsent = false
            self.resolveAutoCheckConsent(accepted: response == .alertSecondButtonReturn)
            DispatchQueue.main.async {
                onFinish?()
            }
        }
    }

    private var consentHostWindow: NSWindow? {
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Mindscape" }) {
            return main
        }
        if let key = NSApp.keyWindow, key.isVisible {
            return key
        }
        return NSApp.windows.first(where: { $0.isVisible })
    }

    func resolveAutoCheckConsent(accepted: Bool) {
        defaults.set(true, forKey: Key.didAskAutoCheck)
        defaults.set(accepted, forKey: Key.autoCheck)
        autoCheckEnabled = accepted
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Checking

    func start() {
        guard autoCheckEnabled, !Self.isRunningUnitTests, periodicTask == nil else { return }
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.check(manual: false, atLaunch: true)
        }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard !Task.isCancelled, let self else { return }
                self.check(manual: false)
            }
        }
    }

    func check(manual: Bool, atLaunch: Bool = false) {
        guard !phase.isUpdating, phase != .checking else { return }
        guard shouldCheck(manual: manual, atLaunch: atLaunch, now: Date()) else { return }
        guard let updater = startUpdater(reportError: manual), !updater.sessionInProgress else { return }
        manualCheck = manual
        if manual { phase = .checking }
        updater.checkForUpdateInformation()
    }

    func shouldCheck(manual: Bool, atLaunch: Bool, now: Date) -> Bool {
        if manual { return true }
        guard autoCheckEnabled else { return false }
        if atLaunch { return true }
        guard let lastCheck = defaults.object(forKey: Key.lastCheck) as? Date else { return true }
        return now.timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    func install() {
        guard phase == .available, let release,
              let updater = startUpdater(reportError: true), !updater.sessionInProgress else { return }
        requestedBuild = release.build
        manualCheck = true
        phase = .checking
        updater.checkForUpdates()
    }

    private func startUpdater(reportError: Bool) -> SPUUpdater? {
        if let updater { return updater }
        do {
            guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                  Data(base64Encoded: key)?.count == 32 else { throw UpdateError.missingPublicKey }
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
            try updater.start()
            self.updater = updater
            return updater
        } catch {
            if reportError { phase = .failed(error.localizedDescription) }
            return nil
        }
    }

    func dismissBanner() {
        if let release { defaults.set(release.build, forKey: Key.dismissedBuild) }
        bannerDismissed = true
        bannerTask?.cancel()
    }

    private func offer(_ candidate: Release) {
        release = candidate
        phase = .available
        bannerDismissed = defaults.string(forKey: Key.dismissedBuild) == candidate.build
        bannerTask?.cancel()
        if !bannerDismissed {
            bannerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.bannerDismissed = true
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(Self.releasePage)
    }

    func cancel() {
        guard let cancelSession else { return }
        self.cancelSession = nil
        requestedBuild = nil
        authorizedBuild = nil
        canCancel = false
        cancelSession()
    }

    func evaluateExit(continueAfterCancellation: @escaping (Bool) -> Void) -> ExitDecision {
        if exitAfterCancellation != nil { return .cancelUpdateFirst }
        if isPreparingApplication {
            do {
                guard let recheckBeforeQuit else { throw UpdateError.saveUnavailable }
                try recheckBeforeQuit()
                return .allow
            } catch {
                phase = .failed(error.localizedDescription)
                return .stayOpen
            }
        }
        if phase.isUpdating || requestedBuild != nil || authorizedBuild != nil {
            do {
                guard let recheckBeforeQuit else { throw UpdateError.saveUnavailable }
                try recheckBeforeQuit()
            } catch {
                phase = .failed(error.localizedDescription)
                authorizedBuild = nil
                requestedBuild = nil
                cancel()
                return .stayOpen
            }
            exitAfterCancellation = continueAfterCancellation
            cancel()
            return .cancelUpdateFirst
        }
        return .allow
    }

    // MARK: - Sparkle updater delegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        isBetaChannel ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard candidate(from: item) != nil else { throw UpdateError.invalidCandidate }
    }

    private func candidate(from item: SUAppcastItem) -> Release? {
        guard !item.isInformationOnlyUpdate, let url = item.fileURL,
              let version = eligibleVersion(item.displayVersionString, archive: url) else { return nil }
        return Release(version: version, build: item.versionString, notes: item.itemDescription ?? "")
    }

    func eligibleVersion(_ displayVersion: String, archive url: URL) -> SemanticVersion? {
        guard let version = SemanticVersion(tag: displayVersion), version > installedVersion,
              isBetaChannel || version.prerelease == nil else { return nil }
        if url.scheme == "https", url.host == "github.com",
           url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
           url.path == "/\(Self.repository)/releases/download/v\(version)/Mindscape-\(version).zip" {
            return version
        }
#if DEBUG
        // 只有另一个 bundle ID 的开发验收副本才可访问隔离的回环更新目录。
        guard bundle.bundleIdentifier == "com.youyanping.mindscape.update-test",
              let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)),
              feed.host == "127.0.0.1", url.scheme == feed.scheme, url.host == feed.host,
              url.port == feed.port else { return nil }
        return version
#else
        return nil
#endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard requestedBuild == nil, !phase.isUpdating, let candidate = candidate(from: item) else { return }
        offer(candidate)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        finishSession(error: error)
    }

    func finishSession(error: (any Error)?) {
        cancelSession = nil
        canCancel = false
        requestedBuild = nil
        authorizedBuild = nil
        isPreparingApplication = false
        let shouldReport = manualCheck
        manualCheck = false
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
                defaults.set(Date(), forKey: Key.lastCheck)
                release = nil
                phase = shouldReport ? .upToDate : .idle
            } else if shouldReport, phase == .checking || phase.isUpdating {
                phase = .failed(Self.failureMessage(error))
            }
        } else {
            defaults.set(Date(), forKey: Key.lastCheck)
            if phase == .checking || phase.isUpdating {
                phase = release == nil ? .idle : .available
            }
        }
        let continueExit = exitAfterCancellation
        exitAfterCancellation = nil
        if let continueExit {
            do {
                guard let recheckBeforeQuit else { throw UpdateError.saveUnavailable }
                try recheckBeforeQuit()
                continueExit(true)
            } catch {
                phase = .failed(error.localizedDescription)
                continueExit(false)
            }
        }
    }

    // MARK: - Sparkle user driver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 应用自己的首启询问和计时器负责后台检查。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelSession = cancellation
        canCancel = true
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let candidate = candidate(from: appcastItem), exitAfterCancellation == nil else {
            reply(state.stage == .installing ? .skip : .dismiss)
            return
        }
        let authorized = requestedBuild == candidate.build
            && release?.version == candidate.version
        requestedBuild = nil
        if state.stage == .installing {
            // 会话恢复时没有有效的保存许可，先撤销安装再让用户重试。
            reply(.skip)
            phase = .failed(String(localized: "先前的更新已取消，请重新检查更新。"))
        } else if authorized {
            authorizedBuild = candidate.build
            phase = .downloading(nil)
            reply(.install)
        } else {
            offer(candidate)
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        phase = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        phase = .failed(Self.failureMessage(error))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        cancelSession = cancellation
        canCancel = true
        phase = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { phase = .downloading(min(1, Double(receivedBytes) / Double(expectedBytes))) }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelSession = nil
        canCancel = false
        phase = .verifying
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard exitAfterCancellation == nil, authorizedBuild != nil else {
            reply(.skip)
            return
        }
        reply(prepareVerifiedInstallation())
    }

    func prepareVerifiedInstallation() -> SPUUserUpdateChoice {
        do {
            guard let prepareToInstall else { throw UpdateError.saveUnavailable }
            try prepareToInstall()
            isPreparingApplication = true
            phase = .installing
            return .install
        } catch {
            phase = .failed(error.localizedDescription)
            return .skip
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}

    private static func failureMessage(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue),
                 Int(SUError.insufficientSigningError.rawValue):
                return String(localized: "更新包签名验证失败。当前版本已保留，请重新检查更新。")
            case Int(SUError.installationCanceledError.rawValue), Int(SUError.authenticationFailure.rawValue),
                 Int(SUError.installationWriteNoPermissionError.rawValue), Int(SUError.runningFromDiskImageError.rawValue):
                return String(localized: "更新未获得安装授权，或应用位置不可写。请从发布页手动安装。")
            default: break
            }
        }
        return error.localizedDescription
    }
}

enum UpdateError: LocalizedError {
    case invalidCandidate, missingPublicKey, saveUnavailable, cannotCommitEditing, inMemoryLibrary
    case saveFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .invalidCandidate:
            return String(localized: "更新来源或版本无效，请重新检查。")
        case .missingPublicKey:
            return String(localized: "此构建未配置更新公钥。请从发布页安装可更新的版本。")
        case .saveUnavailable, .cannotCommitEditing:
            return String(localized: "无法保存当前编辑。请先完成编辑，再重试更新。")
        case .inMemoryLibrary:
            return String(localized: "当前文稿库只在内存中。请先将导图导出或保存到磁盘，再重试更新。")
        case .saveFailed(let error):
            return String(localized: "无法保存导图：\(error.localizedDescription)。请检查文稿库后重试。")
        }
    }
}
