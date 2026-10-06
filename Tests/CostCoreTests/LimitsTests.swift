import Foundation
import Testing
@testable import CostCore

@Test func parsesUsageResponse() throws {
    let json = """
    {"five_hour":{"utilization":42.0,"resets_at":"2026-10-03T01:00:00.123456+00:00"},
     "seven_day":{"utilization":18,"resets_at":"2026-10-07T09:00:00Z"},
     "seven_day_opus":null,"seven_day_oauth_apps":null}
    """
    let limits = try LimitsClient.parse(Data(json.utf8))
    #expect(limits.fiveHour?.utilization == 42)
    #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_989_200))
    #expect(limits.sevenDay?.utilization == 18)
    #expect(limits.sevenDay?.resetsAt != nil)
    #expect(limits.sevenDayOpus == nil)
}

@Test func rejectsUnrelatedResponse() {
    #expect(throws: LimitsError.badResponse) { try LimitsClient.parse(Data(#"{"error":"x"}"#.utf8)) }
}

@Test func readsTokenAndDetectsExpiry() throws {
    let creds = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":2000000000000}}"#.utf8)
    #expect(try LimitsClient.token(fromCredentials: creds, now: Date(timeIntervalSince1970: 1_900_000_000)) == "sk-ant-oat01-x")
    #expect(throws: LimitsError.tokenExpired) {
        try LimitsClient.token(fromCredentials: creds, now: Date(timeIntervalSince1970: 2_100_000_000))
    }
}
