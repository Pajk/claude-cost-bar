import Foundation

public struct TokenUsage: Sendable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite5m: Int64 = 0
    public var cacheWrite1h: Int64 = 0

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
             cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
}

public struct Rate: Sendable {
    public let input: Double
    public let output: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double
    public let cacheRead: Double

    public init(_ input: Double, _ output: Double, _ cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2
        self.cacheRead = cacheRead ?? input * 0.1
    }

    public func cost(_ usage: TokenUsage, fast: Bool = false) -> Double {
        let amount = Double(usage.input) * input + Double(usage.output) * output
            + Double(usage.cacheWrite5m) * cacheWrite5m
            + Double(usage.cacheWrite1h) * cacheWrite1h
            + Double(usage.cacheRead) * cacheRead
        return amount * (fast ? 2 : 1) / 1_000_000
    }
}

public enum Pricing {
    // USD per million tokens. Checked against Anthropic's API pricing on 2026-09-24.
    public static let source = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!

    public static func rate(for model: String) -> Rate? {
        let name = model.lowercased()
        if name.contains("opus-5-5") { return Rate(4, 20, 0.20) }
        if name.contains("opus-5") || name.contains("opus-4-8") || name.contains("opus-4-7")
            || name.contains("opus-4-6") || name.contains("opus-4-5") { return Rate(5, 25) }
        if name.contains("opus-4-1") || name.contains("opus-4-") { return Rate(15, 75) }
        if name.contains("sonnet-5") { return Rate(2, 10) }
        if name.contains("sonnet-4") { return Rate(3, 15) }
        if name.contains("haiku-4-5") { return Rate(1, 5) }
        if name.contains("haiku-3-5") { return Rate(0.8, 4) }
        if name.contains("fable-5-1") || name.contains("mythos-5-1") { return Rate(10, 50, 0.25) }
        if name.contains("fable-5") || name.contains("mythos-5") { return Rate(10, 50) }
        return nil
    }
}

public struct UsageRecord: Sendable {
    public let id: String
    public let date: Date
    public let model: String
    public let tokens: TokenUsage
    public let fast: Bool

    public var cost: Double? { Pricing.rate(for: model)?.cost(tokens, fast: fast) }
}

public struct UsageSummary: Sendable {
    public var cost: Double = 0
    public var tokens = TokenUsage()
    public var requests = 0
    public var unpricedRequests = 0
    public var byModel: [String: Double] = [:]

    public init() {}

    public mutating func add(_ record: UsageRecord) {
        tokens = tokens + record.tokens
        requests += 1
        if let value = record.cost {
            cost += value
            byModel[record.model, default: 0] += value
        } else {
            unpricedRequests += 1
        }
    }
}

public struct UsageSnapshot: Sendable {
    public let records: [UsageRecord]
    public let filesScanned: Int

    public init(records: [UsageRecord], filesScanned: Int) {
        self.records = records
        self.filesScanned = filesScanned
    }

    public func summary(since start: Date?) -> UsageSummary {
        var result = UsageSummary()
        for record in records where start == nil || record.date >= start! { result.add(record) }
        return result
    }
}

/// Reads Claude Code session logs incrementally: each refresh only parses bytes appended since the
/// previous refresh, so steady-state cost is proportional to new log output, not total log size.
public final class UsageReader: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64
        var modified: Date?
    }

    private var files: [String: FileState] = [:]
    private var byID: [String: UsageRecord] = [:]
    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackFormatter = ISO8601DateFormatter()
    private static let newline = UInt8(ascii: "\n")
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let assistantMarker = Data(#""assistant""#.utf8)

    public init() {}

    /// One-shot full read (used by tests).
    public static func read(root: URL) throws -> UsageSnapshot {
        try UsageReader().read(root: root)
    }

    public func read(root: URL) throws -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return UsageSnapshot(records: [], filesScanned: 0) }

        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            count += 1
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate
            var state = files[url.path] ?? FileState(offset: 0, modified: nil)
            if size == state.offset && modified == state.modified { continue }
            if size < state.offset { state.offset = 0 } // rewritten or truncated
            state.offset = readNewLines(url: url, from: state.offset)
            state.modified = modified
            files[url.path] = state
        }
        return UsageSnapshot(records: Array(byID.values), filesScanned: count)
    }

    /// Parses complete lines starting at `offset`; returns the offset just past the last complete line.
    private func readNewLines(url: URL, from offset: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: Self.newline) else { return offset }

        var lineStart = data.startIndex
        while lineStart <= lastNewline {
            let lineEnd = data[lineStart...lastNewline].firstIndex(of: Self.newline) ?? lastNewline
            let line = data[lineStart..<lineEnd]
            // Session logs contain prompts and tool output. Cheap byte check before any JSON decoding.
            if line.range(of: Self.usageMarker) != nil, line.range(of: Self.assistantMarker) != nil {
                parse(line: Data(line), fallbackID: "\(url.path):\(offset + UInt64(lineStart - data.startIndex))")
            }
            lineStart = lineEnd + 1
        }
        return offset + UInt64(lastNewline - data.startIndex + 1)
    }

    private func parse(line: Data, fallbackID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String,
              model != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = dateFormatter.date(from: stamp) ?? fallbackFormatter.date(from: stamp)
        else { return }
        let cache = usage["cache_creation"] as? [String: Any] ?? [:]
        let totalWrite = Self.number(usage["cache_creation_input_tokens"])
        let oneHour = Self.number(cache["ephemeral_1h_input_tokens"])
        let fiveMinute = cache.isEmpty ? totalWrite : Self.number(cache["ephemeral_5m_input_tokens"])
        let tokens = TokenUsage(input: Self.number(usage["input_tokens"]), output: Self.number(usage["output_tokens"]),
                                cacheRead: Self.number(usage["cache_read_input_tokens"]),
                                cacheWrite5m: fiveMinute + max(0, totalWrite - oneHour - fiveMinute),
                                cacheWrite1h: oneHour)
        guard tokens.total > 0 else { return }
        let id = (object["requestId"] as? String) ?? (message["id"] as? String)
            ?? (object["uuid"] as? String) ?? fallbackID
        let fast = (usage["speed"] as? String) == "fast"
        // Streaming writes repeat the same request with progressively complete usage.
        if let previous = byID[id], previous.date > date { return }
        byID[id] = UsageRecord(id: id, date: date, model: model, tokens: tokens, fast: fast)
    }

    private static func number(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}
