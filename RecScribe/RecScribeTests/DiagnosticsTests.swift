import Foundation
import Testing
@testable import RecScribe

@MainActor struct DiagnosticsTests {
    @Test func localReportAndIssueLinkContainVersionContext() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let report = Diagnostics.report(date: fixed)
        for part in ["RecScribe Diagnostics", "Recent log entries:", Diagnostics.appVersion,
                     Diagnostics.systemVersion, ISO8601DateFormatter().string(from: fixed)] {
            #expect(report.contains(part))
        }
        let page = try #require(Diagnostics.reportIssueURL())
        let link = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false))
        #expect(link.host == "github.com")
        #expect(link.path == "/moreaki/recscribe/issues/new")
        let fields = Dictionary((link.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(fields["title"]?.isEmpty == false)
        #expect(fields["body"]?.contains(Diagnostics.appVersion) == true)
        #expect(fields["body"]?.contains(Diagnostics.systemVersion) == true)
        #expect(Diagnostics.recentLogLines(limit: 0).isEmpty)
    }
}
