import Foundation
import Sparkle

/// Sparkle's updater, with what Settings shows about it as observable state. Sparkle reports
/// those only through KVO, which a view can't watch. Its own windows do the asking, downloading
/// and installing: each download is checked against SUPublicEDKey before anything runs.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// nil in a bundle with no feed, which is every build.sh build: one updating itself would swap
    /// the build you're testing for the published one.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    /// False while a check runs, and always in a build that can't update.
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    /// Sparkle's own setting, written straight through, since its scheduler reads its own key.
    /// The comparison stops the loop between this and the KVO mirror below.
    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != checksAutomatically
            else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// Off by default (Info.plist), so an update waits for a yes. Sparkle's update window has a
    /// checkbox for it too, which the mirror picks up.
    var installsAutomatically = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyDownloadsUpdates != installsAutomatically
            else { return }
            updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    /// Whether this bundle can update itself: it has a feed and a key to check downloads with.
    /// build.sh strips the feed unless release.sh is building.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    private init() {
        guard Self.isConfigured else {
            controller = nil
            return
        }
        // Starting it schedules the daily check, which is why the app touches `shared` at launch.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        // Sparkle changes these on the main thread.
        observers = [
            updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.checksAutomatically = updater.automaticallyChecksForUpdates
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.installsAutomatically = updater.automaticallyDownloadsUpdates
                }
            },
        ]
    }

    /// Unlike the scheduled check, this one says so when you're up to date.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
