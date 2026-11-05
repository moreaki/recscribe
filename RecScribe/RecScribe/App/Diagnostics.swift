import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

enum Diagnostics {
    static let subsystem = "com.moreaki.recscribe"
    static let issueBaseURL = "https://github.com/moreaki/recscribe/issues/new"
    static var appVersion: String {
        let metadata = Bundle.main
        let version = metadata.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = metadata.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return version + " (" + build + ")"
    }
    static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static func report(date: Date = .now) -> String {
        let header = """
        RecScribe Diagnostics
        App version: \(appVersion)
        macOS: \(systemVersion)
        Generated: \(ISO8601DateFormatter().string(from: date))

        Recent log entries:
        """
        return header + "\n" + recentLogLines().joined(separator: "\n")
    }

    static func recentLogLines(limit: Int = 500) -> [String] {
        guard limit > 0 else { return [] }
        do {
            let log = try OSLogStore(scope: .currentProcessIdentifier)
            let beginning = log.position(date: .now.addingTimeInterval(-3_600))
            let filter = NSPredicate(format: "subsystem == %@", subsystem)
            var retained = [String]()
            for case let event as OSLogEntryLog in try log.getEntries(at: beginning, matching: filter) {
                retained.append("[" + event.category + "] " + event.composedMessage)
                // The report keeps a bounded suffix, even during long sessions.
                if retained.count > limit && retained.count - limit > limit { retained.removeFirst(retained.count - limit) }
            }
            return retained.isEmpty ? ["(no recent log entries)"] : Array(retained.suffix(limit))
        } catch {
            return ["(could not read logs: \(error.localizedDescription))"]
        }
    }

    static func reportIssueURL() -> URL? {
        var destination = URLComponents(string: issueBaseURL)
        destination?.queryItems = [.init(name: "title", value: "RecScribe issue"), .init(name: "body", value:
            "Describe the problem:\n\n---\nApp version: \(appVersion)\nmacOS: \(systemVersion)")]
        return destination?.url
    }
    @MainActor static func exportReport() {
        let chooser = NSSavePanel()
        chooser.allowedContentTypes = [.plainText]
        chooser.title = "Export Diagnostics"
        chooser.nameFieldStringValue = "RecScribe-Diagnostics.txt"
        guard chooser.runModal() == .OK, let file = chooser.url else { return }
        do { try Data(report().utf8).write(to: file, options: .atomic) }
        catch { Log.file.error("Diagnostic export failed: \(error.localizedDescription, privacy: .private)") }
    }
    @MainActor static func reportProblem() {
        if let page = reportIssueURL() { NSWorkspace.shared.open(page) }
    }
}
