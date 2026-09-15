import Testing
@testable import Wax

/// W3-b: daily remember/recall tool summaries must not teach `session_open`.
/// Absence checks throw — Swift Testing 0.99 can pass `#expect(contains == false)`.
@Suite
struct DailyCatalogCeremonyTests {
    @Test(arguments: ["remember", "recall", "stats"])
    func dailyToolSummaryOmitsSessionOpen(_ name: String) throws {
        let entry = try #require(BrokerCommandCatalog.entry(for: name))
        if entry.summary.contains("session_open") {
            throw CeremonyCatalogError.summaryMentionsSessionOpen(name: name, summary: entry.summary)
        }
        for argument in entry.arguments {
            if let description = argument.description, description.contains("session_open") {
                throw CeremonyCatalogError.argumentMentionsSessionOpen(
                    name: name,
                    argument: argument.name,
                    description: description
                )
            }
        }
    }

    @Test
    func rememberAndRecallSummariesStayUsableWithoutSessionOpen() throws {
        let remember = try #require(BrokerCommandCatalog.entry(for: "remember"))
        #expect(remember.summary.contains("memory_type"))
        #expect(remember.summary.localizedCaseInsensitiveContains("metadata"))
        let scope = try #require(remember.arguments.first { $0.name == "scope" }?.description)
        #expect(scope.contains("inherited from the connection session"))

        let recall = try #require(BrokerCommandCatalog.entry(for: "recall"))
        #expect(recall.summary.contains("Preferred read path"))
        #expect(recall.summary.contains("Omit mode unless you need an override"))
        #expect(recall.summary.contains("scope=global"))
        #expect(recall.summary.localizedCaseInsensitiveContains("optional session_id"))
    }
}

private enum CeremonyCatalogError: Error, CustomStringConvertible {
    case summaryMentionsSessionOpen(name: String, summary: String)
    case argumentMentionsSessionOpen(name: String, argument: String, description: String)

    var description: String {
        switch self {
        case .summaryMentionsSessionOpen(let name, let summary):
            return "\(name) summary still mentions session_open: \(summary)"
        case .argumentMentionsSessionOpen(let name, let argument, let description):
            return "\(name).\(argument) still mentions session_open: \(description)"
        }
    }
}
