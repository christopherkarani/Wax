import Foundation
import Testing
@testable import Wax

@discardableResult
private func withStore<T>(
    resolvesRelativeDates: Bool = true,
    _ body: (Memory) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-reldates-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Memory.Config.default
    config.enableVectorSearch = false
    config.reranking = .disabled
    config.resolvesRelativeDates = resolvesRelativeDates
    let memory = try await Memory(at: url, config: config)
    do {
        let result = try await body(memory)
        try await memory.close()
        return result
    } catch {
        try? await memory.close()
        throw error
    }
}

private let textOnly = Memory.SearchOptions(topK: 10, mode: .textOnly, inferTimeRange: false)

private func onlyItem(_ memory: Memory, _ query: String) async throws -> RAGContext.Item {
    try await memory.flush()
    let items = try await memory.search(query, options: textOnly).items
    let item = try #require(items.first)
    return item
}

@Test
func saveWithAPastObservationDateResolvesAgainstThatDate() async throws {
    try await withStore { memory in
        let raw = "Caroline went to the support group yesterday."
        try await memory.save(raw, metadata: [Memory.RelativeDates.observedAtKey: "2023-05-08"])
        let item = try await onlyItem(memory, "support group")
        #expect(item.text == "Caroline went to the support group yesterday (7 May 2023).")
        #expect(item.metadata[Memory.RelativeDates.observedAtKey] == "2023-05-08")
        let original: String = try #require(Memory.RelativeDates.originalText(item.text, metadata: item.metadata))
        #expect(original == raw)
    }
}

@Test
func saveWithoutAnObservationDateStoresTextUnchanged() async throws {
    try await withStore { memory in
        let raw = "The dentist appointment is tomorrow."
        try await memory.save(raw)
        let item = try await onlyItem(memory, "dentist")
        #expect(item.text == raw)
        #expect(item.metadata.keys.allSatisfy { !$0.hasPrefix("wax.relative_dates") })
    }
}

@Test
func batchAndImportWithoutAnObservationDateAnnotateNothing() async throws {
    try await withStore { memory in
        try await memory.save(contentsOf: [(text: "The kiln broke last week.", metadata: [:])])
        try await memory.importDocuments([(text: "The pottery class starts tomorrow.", metadata: ["doc_id": "p"])])
        try await memory.save("The glaze order ships next month.")
        #expect(try await onlyItem(memory, "kiln").text == "The kiln broke last week.")
        #expect(try await onlyItem(memory, "pottery").text == "The pottery class starts tomorrow.")
        #expect(try await onlyItem(memory, "glaze").text == "The glaze order ships next month.")
    }
}

@Test
func aLiveSaveResolvesAgainstTheDayItPasses() async throws {
    try await withStore { memory in
        let now = Date()
        let observedAt = Memory.RelativeDates.observedAt(now)
        try await memory.save(
            "The dentist appointment is tomorrow.",
            metadata: [Memory.RelativeDates.observedAtKey: observedAt]
        )
        let day = try #require(ObservedDay(iso8601: observedAt))
        let expected = RelativeDateAnnotator(observedDay: day).annotate("The dentist appointment is tomorrow.").text
        #expect(try await onlyItem(memory, "dentist").text == expected)
    }
}

@Test
func observedAtIsTheCalendarDayInTheGivenTimeZone() throws {
    let instant = Date(timeIntervalSince1970: 1_692_662_400) // 2023-08-22T00:00:00Z
    let utc = try #require(TimeZone(identifier: "UTC"))
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    #expect(Memory.RelativeDates.observedAt(instant, timeZone: utc) == "2023-08-22")
    #expect(Memory.RelativeDates.observedAt(instant, timeZone: newYork) == "2023-08-21")
}

@Test
func resolvingRelativeDatesCanBeTurnedOff() async throws {
    try await withStore(resolvesRelativeDates: false) { memory in
        let raw = "Caroline went to the support group yesterday."
        try await memory.save(raw, metadata: [Memory.RelativeDates.observedAtKey: "2023-05-08"])
        let item = try await onlyItem(memory, "support group")
        #expect(item.text == raw)
    }
}

@Test
func textWithoutRelativeDatesIsStoredUnchanged() async throws {
    try await withStore { memory in
        let raw = "Melanie painted a sunrise over the lake."
        try await memory.save(raw, metadata: ["doc_id": "d1"])
        let item = try await onlyItem(memory, "sunrise")
        #expect(item.text == raw)
        #expect(item.metadata.keys.allSatisfy { !$0.hasPrefix("wax.relative_dates") })
    }
}

@Test
func batchAndImportResolveRelativeDatesAgainstTheGivenDate() async throws {
    try await withStore { memory in
        let observed = [Memory.RelativeDates.observedAtKey: "2023-08-22"]
        try await memory.save(contentsOf: [(text: "The kiln broke last week.", metadata: observed)])
        try await memory.importDocuments([(text: "The pottery class starts tomorrow.", metadata: observed)])
        #expect(try await onlyItem(memory, "kiln").text == "The kiln broke last week (14–20 Aug 2023).")
        #expect(try await onlyItem(memory, "pottery").text == "The pottery class starts tomorrow (23 Aug 2023).")
    }
}

@Test
func savingTheSameTextAndObservationDateAgainReturnsTheSameFrame() async throws {
    try await withStore { memory in
        let observed = [Memory.RelativeDates.observedAtKey: "2023-08-22"]
        let first = try await memory.save("I adopted a puppy yesterday.", metadata: observed)
        let second = try await memory.save("I adopted a puppy yesterday.", metadata: observed)
        #expect(first == second)
    }
}

@Test
func malformedObservationDatesAreRejected() async throws {
    try await withStore { memory in
        await #expect(throws: WaxError.self) {
            try await memory.save("I went yesterday.", metadata: [Memory.RelativeDates.observedAtKey: "May 8"])
        }
    }
}

@Test
func aMalformedObservationDateRejectsTheWholeBatchBeforeWriting() async throws {
    try await withStore { memory in
        let documents: [(text: String, metadata: [String: String])] = [
            (text: "The quail flew yesterday.", metadata: [Memory.RelativeDates.observedAtKey: "2023-08-22"]),
            (text: "The heron flew.", metadata: [Memory.RelativeDates.observedAtKey: "22 Aug"]),
        ]
        await #expect(throws: WaxError.self) { try await memory.save(contentsOf: documents) }
        await #expect(throws: WaxError.self) { try await memory.importDocuments(documents) }
        try await memory.flush()
        let found = try await memory.search("quail", options: textOnly).items
        #expect(found.isEmpty)
    }
}
