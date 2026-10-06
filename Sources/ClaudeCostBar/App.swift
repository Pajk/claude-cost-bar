import AppKit
import CostCore
import SwiftUI

@MainActor
final class CostStore: ObservableObject {
    @Published var snapshot = UsageSnapshot(records: [], filesScanned: 0)
    /// Precomputed per refresh so SwiftUI redraws never walk all records.
    @Published fileprivate var summaries: [Period: UsageSummary] = [:]
    private let reader = UsageReader()
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var isLoading = false
    @Published var limits: PlanLimits?
    @Published var limitsError: String?
    @Published var limitsUpdated: Date?
    private var limitsLoading = false
    private var timer: Timer?

    let logFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refreshLimits(force: Bool = false) {
        guard !limitsLoading else { return }
        if !force, let last = limitsUpdated, Date().timeIntervalSince(last) < 60 { return }
        limitsLoading = true
        Task {
            do {
                let value = try await Task.detached(priority: .utility) { try await LimitsClient.fetch() }.value
                limits = value
                limitsUpdated = Date()
                limitsError = nil
            } catch {
                // Keep the last good numbers on transient failures.
                limitsError = error.localizedDescription
            }
            limitsLoading = false
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let folder = logFolder
        let reader = reader
        Task.detached(priority: .utility) {
            let result = Result { () throws -> (UsageSnapshot, [Period: UsageSummary]) in
                let data = try reader.read(root: folder)
                let now = Date()
                var summaries: [Period: UsageSummary] = [:]
                for period in Period.allCases { summaries[period] = data.summary(since: period.start(now: now)) }
                return (data, summaries)
            }
            await MainActor.run {
                switch result {
                case .success(let (data, summaries)):
                    self.snapshot = data
                    self.summaries = summaries
                    self.lastUpdated = Date()
                    self.error = nil
                case .failure(let failure):
                    self.error = failure.localizedDescription
                }
                self.isLoading = false
            }
        }
    }
}

fileprivate enum Period: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case week = "7 days"
    case month = "Month"
    case all = "All"

    var id: Self { self }

    func start(now: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        case .all: return nil
        }
    }
}

private func money(_ amount: Double) -> String {
    if amount > 0 && amount < 0.01 { return String(format: "$%.4f", amount) }
    return String(format: "$%.2f", amount)
}

private func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func resetText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = max(0, date.timeIntervalSince(now))
    if seconds < 24 * 3600 {
        let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "resets in \(hours) h \(minutes) min" : "resets in \(minutes) min"
    }
    return "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private func limitColor(_ value: Double) -> Color {
    value >= 90 ? .red : value >= 75 ? .orange : .accentColor
}

private func count(_ value: Int64) -> String {
    value.formatted(.number.notation(.compactName))
}

/// MenuBarExtra windows resize around their bottom-left origin, so when the content height changes
/// (limits load, period switch) the panel drifts away from the menu bar. Keep its top edge pinned
/// right under the menu bar.
private struct WindowTopAnchor: NSViewRepresentable {
    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pin() }
                })
            }
            pin()
        }

        private func pin() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let top = screen.visibleFrame.maxY - 1
            guard abs(window.frame.maxY - top) > 0.5 else { return }
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
    }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}
}

struct CostPanel: View {
    @ObservedObject var store: CostStore
    @State private var period: Period = .today

    var body: some View {
        let summary = store.summaries[period] ?? UsageSummary()
        // "All" is a superset of every other period. Size the panel for it so switching periods never
        // changes the height (MenuBarExtra windows grow but do not shrink cleanly).
        let all = store.summaries[.all] ?? UsageSummary()
        let models = summary.byModel.sorted { $0.value > $1.value }
        let padding = max(0, all.byModel.count - models.count)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code cost")
                        .font(.headline)
                    Text("Estimated API equivalent · USD")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh(); store.refreshLimits(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
                .help("Refresh usage")
            }

            limitsSection

            Divider()

            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(money(summary.cost))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(summary.requests.formatted()) API requests · \(count(summary.tokens.total)) tokens")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                tokenRow("Input", summary.tokens.input, "Output", summary.tokens.output)
                tokenRow("Cache read", summary.tokens.cacheRead, "Cache write", summary.tokens.cacheWrite5m + summary.tokens.cacheWrite1h)
            }
            .font(.caption)

            if !all.byModel.isEmpty {
                Divider()
                Text("BY MODEL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(models, id: \.key) { model, cost in
                    HStack {
                        Text(model.replacingOccurrences(of: "claude-", with: ""))
                            .lineLimit(1)
                        Spacer()
                        Text(money(cost)).monospacedDigit()
                    }
                    .font(.caption)
                }
                ForEach(0..<padding, id: \.self) { _ in
                    Text(" ").font(.caption).hidden()
                }
            }

            if store.snapshot.filesScanned == 0 {
                Text("No Claude Code session logs found in ~/.claude/projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if all.unpricedRequests > 0 {
                Text("\(summary.unpricedRequests) requests use unknown models and are excluded from the estimate.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2, reservesSpace: true)
                    .opacity(summary.unpricedRequests > 0 ? 1 : 0)
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Text(store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Loading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("API prices", destination: Pricing.source)
                    .font(.caption)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowTopAnchor())
        .onAppear { store.refresh(); store.refreshLimits() }
    }

    @ViewBuilder
    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLAN LIMITS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let limits = store.limits {
                limitRow("5-hour session", limits.fiveHour)
                limitRow("Weekly · all models", limits.sevenDay)
                if let opus = limits.sevenDayOpus { limitRow("Weekly · Opus", opus) }
                if let sonnet = limits.sevenDaySonnet { limitRow("Weekly · Sonnet", sonnet) }
            } else {
                // Same height as real data so the panel does not jump when limits arrive.
                limitRow("5-hour session", LimitWindow(utilization: 0, resetsAt: nil)).redacted(reason: .placeholder)
                limitRow("Weekly · all models", LimitWindow(utilization: 0, resetsAt: nil)).redacted(reason: .placeholder)
            }
            if let error = store.limitsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func limitRow(_ title: String, _ window: LimitWindow?) -> some View {
        if let window {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(percent(window.utilization)).monospacedDigit().fontWeight(.semibold)
                }
                .font(.caption)
                ProgressView(value: min(window.utilization, 100), total: 100)
                    .tint(limitColor(window.utilization))
                Text(window.resetsAt == nil ? " " : resetText(window.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tokenRow(_ firstLabel: String, _ firstValue: Int64, _ secondLabel: String, _ secondValue: Int64) -> some View {
        GridRow {
            Text(firstLabel).foregroundStyle(.secondary)
            Text(count(firstValue)).monospacedDigit()
            Text(secondLabel).foregroundStyle(.secondary)
            Text(count(secondValue)).monospacedDigit()
        }
    }
}

@main
struct ClaudeCostBarApp: App {
    @StateObject private var store = CostStore()

    var body: some Scene {
        MenuBarExtra {
            CostPanel(store: store)
        } label: {
            Text(money(store.summaries[.today]?.cost ?? 0))
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
