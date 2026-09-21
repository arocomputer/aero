import AppKit
import Sparkle

/// Owns Sparkle's signed-feed updater. Development builds without a publisher key never contact a feed.
@MainActor final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?
    private var message: String?

    static func validConfiguration(feed: URL?, publicKey: String?) -> Bool {
        guard let feed, feed.scheme == "https", feed.host?.isEmpty == false,
            let publicKey, Data(base64Encoded: publicKey)?.count == 32
        else { return false }
        return true
    }

    var isConfigured: Bool {
        Self.validConfiguration(
            feed: (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)),
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    var canCheck: Bool { isConfigured && (controller?.updater.canCheckForUpdates ?? true) }
    var status: String {
        guard isConfigured else {
            return
                "Signed updates are not configured for this development build. A publisher signing key and signed update feed are required."
        }
        if let message { return message }
        if let date = controller?.updater.lastUpdateCheckDate {
            return
                "Last checked \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)). Updates and their feed are signature-verified."
        }
        return "Updates and their feed are verified with the publisher's signing key before installation."
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            controller.updater.sendsSystemProfile = false
            self.controller = controller
        } catch { message = error.localizedDescription }
    }

    func check() {
        start()
        guard let controller, controller.updater.canCheckForUpdates else { return }
        message = "Checking for updates…"
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        start()
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        start()
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "An update is available. Use Check for Updates to review and install it."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        message = error.localizedDescription
    }
}
