import Foundation

/// One rolling usage window (e.g. the 5-hour session or the 7-day week).
public struct LimitWindow: Sendable, Equatable {
    /// Percent of the window already used, 0–100.
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Subscription limits as reported by the same endpoint Claude Code's `/usage` uses.
public struct PlanLimits: Sendable, Equatable {
    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let sevenDayOpus: LimitWindow?
    public let sevenDaySonnet: LimitWindow?

    public init(fiveHour: LimitWindow?, sevenDay: LimitWindow?, sevenDayOpus: LimitWindow? = nil, sevenDaySonnet: LimitWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
    }
}

public enum LimitsError: LocalizedError, Equatable {
    case noCredentials
    case tokenExpired
    case unauthorized
    case rateLimited
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "Claude Code login not found. Run `claude` and log in with your subscription."
        case .tokenExpired: return "Claude Code login token expired. Run `claude` once to refresh it."
        case .unauthorized: return "Usage endpoint rejected the Claude Code token. Run `claude` once to refresh it."
        case .rateLimited: return "Usage endpoint is rate limiting; will retry later."
        case .http(let code): return "Usage endpoint returned HTTP \(code)."
        case .badResponse: return "Unexpected response from the usage endpoint."
        }
    }
}

public enum LimitsClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> PlanLimits {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }
        let limits = PlanLimits(fiveHour: window(object["five_hour"]), sevenDay: window(object["seven_day"]),
                                sevenDayOpus: window(object["seven_day_opus"]),
                                sevenDaySonnet: window(object["seven_day_sonnet"]))
        guard limits.fiveHour != nil || limits.sevenDay != nil else { throw LimitsError.badResponse }
        return limits
    }

    private static func window(_ value: Any?) -> LimitWindow? {
        guard let object = value as? [String: Any],
              let utilization = (object["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return LimitWindow(utilization: utilization, resetsAt: (object["resets_at"] as? String).flatMap(date))
    }

    /// Accepts ISO 8601 with or without fractional seconds (any precision) and with Z or ±hh:mm.
    static func date(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: Credentials

    /// Reads the OAuth access token Claude Code stores after `claude` login.
    /// macOS: Keychain item "Claude Code-credentials" (read through /usr/bin/security, which Claude Code
    /// itself uses, so no extra Keychain prompt). Fallback: ~/.claude/.credentials.json.
    public static func accessToken(now: Date = Date()) throws -> String {
        let raw = keychainCredentials() ?? fileCredentials()
        guard let raw else { throw LimitsError.noCredentials }
        return try token(fromCredentials: raw, now: now)
    }

    static func token(fromCredentials data: Data, now: Date) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw LimitsError.noCredentials }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) <= now { throw LimitsError.tokenExpired }
        return token
    }

    private static func keychainCredentials() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func fileCredentials() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    // MARK: Fetch

    public static func fetch() async throws -> PlanLimits {
        let token = try accessToken()
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try parse(data)
        case 401, 403: throw LimitsError.unauthorized
        case 429: throw LimitsError.rateLimited
        default: throw LimitsError.http(status)
        }
    }
}
