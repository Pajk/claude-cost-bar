import Foundation
import Testing
@testable import CostCore

@Test func pricesCacheDurationsAndFastMode() {
    let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                           cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
    let rate = Pricing.rate(for: "claude-opus-5-5")!
    #expect(rate.cost(usage) == 37.2)
    #expect(rate.cost(usage, fast: true) == 74.4)
}

@Test func streamingDuplicatesCountOnceAndUnknownModelsAreFlagged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = [
        row(id: "req_1", output: 10, model: "claude-sonnet-5"),
        row(id: "req_1", output: 20, model: "claude-sonnet-5"),
        row(id: "req_2", output: 5, model: "claude-future-9")
    ].joined(separator: "\n") + "\n"
    try rows.write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    let snapshot = try UsageReader.read(root: root)
    let summary = snapshot.summary(since: nil)
    #expect(snapshot.filesScanned == 1)
    #expect(summary.requests == 2)
    #expect(summary.tokens.output == 25)
    #expect(summary.unpricedRequests == 1)
}

@Test func incrementalReadOnlyParsesAppendedLines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.jsonl")
    try (row(id: "req_1", output: 10, model: "claude-sonnet-5") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let reader = UsageReader()
    #expect(try reader.read(root: root).summary(since: nil).requests == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    // Second row plus a partial line that must wait until it is complete.
    try handle.write(contentsOf: Data((row(id: "req_2", output: 5, model: "claude-sonnet-5") + "\n{\"type\":\"assi").utf8))
    try handle.close()
    let summary = try reader.read(root: root).summary(since: nil)
    #expect(summary.requests == 2)
    #expect(summary.tokens.output == 15)
}

private func row(id: String, output: Int, model: String) -> String {
    """
    {"type":"assistant","timestamp":"2026-09-24T08:00:00.000Z","requestId":"\(id)","message":{"id":"msg_\(id)","model":"\(model)","usage":{"input_tokens":100,"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
}
