import AppKit

/// AppKit owns the services even when no SwiftUI window has been created.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services: AppServices
    private let prepareForTermination: () async -> Void
    private var terminating = false

    override convenience init() {
        self.init(services: AppServices())
    }

    init(services: AppServices, prepareForTermination: (() async -> Void)? = nil) {
        self.services = services
        self.prepareForTermination = prepareForTermination ?? { await services.shutdown() }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Includes AppKit panels; the template status icon follows the menu bar.
        (FocusAppearance(rawValue: UserDefaults.standard.string(forKey: FocusAppearance.defaultsKey) ?? "") ?? .system).apply()
        services.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func requestTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await prepareForTermination()
            reply(true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
