import AppKit

@MainActor final class PerAppListCache {
    private(set) var apps: [RunningAppInfo]?
    func update(_ value: [RunningAppInfo]) { apps = value }
}

/// Menu tracking reads the cache synchronously and refreshes it in a separate
/// task. A newer open cancels delivery from an older open without blocking AppKit.
@MainActor final class PerAppMenuDelegate: NSObject, NSMenuDelegate {
    private let cache: PerAppListCache
    private let source: AudioSourceProviding
    private let actions: OverflowMenu
    private let makeContext: @MainActor () -> OverflowContext
    private var request: Task<Void, Never>?
    private var revision = UUID()
    init(cache: PerAppListCache, source: AudioSourceProviding, actions: OverflowMenu = .init(),
         makeContext: @escaping @MainActor () -> OverflowContext) {
        self.cache = cache
        self.source = source
        self.actions = actions
        self.makeContext = makeContext
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        request?.cancel()
        revision = UUID()
        let identity = revision
        let snapshot = makeContext()
        render(menu, snapshot: snapshot)
        guard snapshot.permissionGranted else { return }
        let provider = source
        request = Task { [weak self, weak menu] in
            guard let discovered = try? await provider.availableApps(), !Task.isCancelled,
                  let self, self.revision == identity else { return }
            self.cache.update(discovered)
            guard let menu else { return }
            self.render(menu, snapshot: self.makeContext())
        }
    }
    private func render(_ menu: NSMenu, snapshot: OverflowContext) {
        OverflowMenu.populate(menu, with: actions.perAppSubmenu(snapshot).entries)
    }
    deinit { request?.cancel() }
}
