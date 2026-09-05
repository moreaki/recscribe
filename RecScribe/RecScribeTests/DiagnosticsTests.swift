//
//  DiagnosticsTests.swift
//  RecScribeTests
//
//  BL-042: the diagnostics report and "Report a Problem" URL carry the
//  environment info needed to act on a user report.
//

import Testing
import Foundation
@testable import RecScribe

@MainActor
struct DiagnosticsTests {

    @Test("Report includes app + macOS version")
    func reportIncludesEnvironment() {
        let report = Diagnostics.report()
        #expect(report.contains("RecScribe Diagnostics"))
        #expect(report.contains(Diagnostics.appVersion))
        #expect(report.contains(Diagnostics.systemVersion))
        #expect(report.contains("Recent log entries:"))
    }

    @Test("Report-a-Problem URL is valid and prefilled with version info")
    func reportIssueURLIsPrefilled() throws {
        let url = try #require(Diagnostics.reportIssueURL())
        #expect(url.absoluteString.contains("github.com/moreaki/recscribe/issues/new"))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("App version:"))
        #expect(body.contains("macOS:"))
        #expect(components.queryItems?.contains { $0.name == "title" } == true)
    }
}
