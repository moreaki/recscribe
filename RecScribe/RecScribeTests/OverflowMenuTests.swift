import AppKit
import Testing
@testable import RecScribe

@MainActor
struct OverflowMenuTests {
    @Test(arguments: [true, false])
    func nativeMenuKeepsActionIdentityAndLiveTargets(unlocked: Bool) throws {
        let context = OverflowContext(allowsCaptureSourceChange: unlocked)
        let definition = OverflowMenu()
        let actions = definition.actions(context)
        #expect(Set(actions.map(\.id)).count == actions.count)
        #expect(actions.allSatisfy { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(actions.map(\.id)).isSuperset(of: ["showWindow", "exportDiagnostics", "reportProblem", "quit"]))
        #expect(actions.filter { $0.commandKey != nil }.map(\.id) == ["quit"])
        #expect(actions.first { $0.id == "quit" }?.commandKey == "q")
        let menu = definition.makeNSMenu(context)
        func inspect(_ native: NSMenu, rows: [OverflowEntry]) {
            #expect(native.items.count == rows.count)
            for (item, row) in zip(native.items, rows) {
                switch row {
                case .separator: #expect(item.isSeparatorItem)
                case .sectionHeader(let text): #expect(item.title == text)
                case .disabledNotice(let text): #expect(item.title == text && !item.isEnabled)
                case .submenu(let child):
                    #expect(item.title == child.title)
                    if let submenu = item.submenu { inspect(submenu, rows: child.entries) }
                    else { Issue.record("Missing native submenu") }
                case .action(let action):
                    #expect(item.title == action.title && item.isEnabled == action.isEnabled)
                    #expect(item.keyEquivalent == action.commandKey.map(String.init) ?? "")
                    if action.isEnabled { #expect(item.target != nil && item.action != nil) }
                    else { #expect(item.action == nil) }
                }
            }
        }
        inspect(menu, rows: definition.entries(context))
    }

    @Test func pointerRoutingFollowsNativeMenuConventions() {
        for flags: NSEvent.ModifierFlags in [[], .shift, .command, .option, .control] {
            #expect(MenuBarController.shouldShowOverflowMenu(type: .leftMouseUp, modifiers: flags) == flags.contains(.control))
            #expect(MenuBarController.shouldShowOverflowMenu(type: .rightMouseUp, modifiers: flags))
        }
    }

    @Test func menuInstancesKeepTheirOwnCallbacksAndBuildWithoutExecutingThem() throws {
        var events: [String] = []
        func actions(_ name: String) -> OverflowMenu {
            OverflowMenu(onSelectSource: { _ in events.append(name + ":source") },
                onRequestPermission: { events.append(name + ":permission") },
                openWindow: { events.append(name + ":" + $0.rawValue) })
        }
        let first = actions("first"), second = actions("second")
        let firstMenu = first.actions()
        let secondMenu = second.actions()
        #expect(events.isEmpty)
        try #require(firstMenu.first { $0.id == "sourceSystemAll" }).perform()
        try #require(secondMenu.first { $0.id == "recordings" }).perform()
        try #require(firstMenu.first { $0.id == "settings" }).perform()
        #expect(events == ["first:source", "second:recordings", "first:settings"])
    }

}
