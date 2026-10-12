import Foundation
import os

private final class ClaudeHTTPStub: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var status = 200
        var data = Data()
        var retryAfter: String?
        var error: URLError?
        var requests: [URLRequest] = []
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { value in
            value.requests.append(request)
            return value
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [self] in
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
            let headers = reply.retryAfter.map { ["Retry-After": $0] }
            let http = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
@MainActor
private struct ClaudeUsageProbeChecks {
    static var checks = 0
    nonisolated static let date = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let account = ClaudeUsageAccount(credentialID: "fixture", plan: "pro")
    nonisolated static let payload = Data(#"{"five_hour":{"utilization":0,"resets_at":"2027-01-16T17:29:59.585956+00:00"},"seven_day":{"utilization":3,"resets_at":"2027-01-20T08:59:59Z"},"seven_day_opus":null,"extra_usage":{"is_enabled":false},"future_field":42}"#.utf8)

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ClaudeProbeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func expectFailure(_ failure: ClaudeUsageFailure, _ message: String, _ operation: () throws -> Void) throws {
        do { try operation(); try expect(false, message) }
        catch let actual as ClaudeUsageFailure { try expect(actual == failure, message) }
    }
    static func credential(token: String = "fixture-access", expires: Double? = 1_800_001_000_000,
                           scopes: [String] = ["user:profile"]) throws -> Data {
        var oauth: [String: Any] = ["accessToken": token, "subscriptionType": "pro", "scopes": scopes]
        if let expires { oauth["expiresAt"] = expires }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }
    static func main() async throws {
        try parserChecks()
        try await transportChecks()
        print("Claude usage parser/transport checks passed: \(checks)")
    }
    static func parserChecks() throws {
        let value = try ClaudeUsageParser.snapshot(payload, account: account, at: date)
        try expect(value.windows.map(\.id) == ["five_hour", "seven_day"], "Null and unknown buckets must not become fake quotas")
        try expect(value.windows[0].remainingPercent == 100 && value.windows[1].remainingPercent == 97, "Utilization must convert to remaining percentage")
        try expect(value.windows.allSatisfy { $0.resetsAt != nil }, "Fractional and whole-second ISO dates must parse")
        try expect(value.fetchedAt == date && value.account == account, "Snapshot must preserve verified identity and fetch time")
        try expect(!value.windows[0].isCurrent(at: value.windows[0].resetsAt!), "Passing a reset must invalidate the shown percentage")
        let unknown = try ClaudeUsageParser.snapshot(Data(#"{"five_hour":{"utilization":null,"resets_at":null}}"#.utf8), account: account, at: date)
        try expect(unknown.windows[0].remainingPercent == nil && unknown.windows[0].resetsAt == nil, "Missing percentage/reset must stay unknown")
        let over = try ClaudeUsageParser.snapshot(Data(#"{"five_hour":{"utilization":130}}"#.utf8), account: account, at: date)
        try expect(over.windows[0].remainingPercent == 0, "Overages must clamp to zero remaining")
        for source in ["{}", #"{"five_hour":null,"seven_day":null}"#] {
            try expectFailure(.usageUnavailable, "No reported window must be unavailable") {
                _ = try ClaudeUsageParser.snapshot(Data(source.utf8), account: account, at: date)
            }
        }
        for source in ["[]", "broken", #"{"five_hour":[]}"#, #"{"five_hour":{"utilization":true}}"#,
                       #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{"utilization":"3"}}"#,
                       #"{"five_hour":{"resets_at":"tomorrow"}}"#] {
            try expectFailure(.invalidResponse, "Malformed payload must not become valid usage") {
                _ = try ClaudeUsageParser.snapshot(Data(source.utf8), account: account, at: date)
            }
        }
        try expectFailure(.invalidResponse, "Response size must be bounded") {
            _ = try ClaudeUsageParser.snapshot(Data(repeating: 32, count: 1_048_577), account: account, at: date)
        }
        let first = try ClaudeUsageParser.credential(credential(), at: date)
        let second = try ClaudeUsageParser.credential(credential(token: "second-fixture"), at: date)
        try expect(first.account.plan == "pro" && first.account.credentialID.count == 64, "Only a fingerprint and plan should identify credentials")
        try expect(first.account != second.account, "Credential changes must invalidate the old identity")
        let encoded = String(decoding: try JSONEncoder().encode(first.account), as: UTF8.self)
        try expect(!encoded.contains(first.accessToken), "Serialized identity must not contain the access token")
        try expectFailure(.expiredLogin, "Expired credentials require Claude Code refresh") {
            _ = try ClaudeUsageParser.credential(credential(expires: 1_800_000_000_000), at: date)
        }
        try expectFailure(.unsupportedAccount, "Inference-only tokens cannot read profile usage") {
            _ = try ClaudeUsageParser.credential(credential(scopes: ["user:inference"]), at: date)
        }
        for data in [Data("{}".utf8), try credential(token: ""), try credential(token: "bad\r\nheader")] {
            try expectFailure(.notSignedIn, "Missing or unsafe credentials must not produce requests") {
                _ = try ClaudeUsageParser.credential(data, at: date)
            }
        }
        try expect(ClaudeUsageParser.retryDate("7200", at: date) == date.addingTimeInterval(7200), "Long Retry-After must be honored")
        try expect(ClaudeUsageParser.retryDate("Sat, 16 Jan 2027 09:00:00 GMT", at: date) != nil, "HTTP-date Retry-After must parse")
        try expect(ClaudeUsageParser.retryDate("nan", at: date) == nil && ClaudeUsageParser.retryDate("-5", at: date) == nil, "Invalid Retry-After must be ignored")
    }

    static func transportChecks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let credentialData = try credential()
        let prompts = OSAllocatedUnfairLock(initialState: [Bool]())
        let probe = ClaudeUsageProbe(session: session, readCredential: { allowed in
            prompts.withLock { $0.append(allowed) }
            return credentialData
        }, now: { date })
        ClaudeHTTPStub.state.withLock { $0 = .init(data: payload) }
        let identity = await probe.fetch(.init())
        try expect(identity.account?.plan == "pro" && identity.snapshot == nil, "Identity checks must stay local")
        try expect(ClaudeHTTPStub.state.withLock { $0.requests.isEmpty }, "Identity checks must make no HTTP request")
        let result = await probe.fetch(.init(usage: true))
        try expect(result.snapshot?.windows[1].remainingPercent == 97, "Live transport must pass bytes through the real parser")
        let sent = ClaudeHTTPStub.state.withLock { $0.requests.last! }
        try expect(sent.url == ClaudeUsageProbe.endpoint && sent.httpMethod == "GET", "Usage must only go to the fixed endpoint")
        try expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "OAuth bearer header must be set")
        try expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "OAuth usage requires the beta header")
        try expect(sent.value(forHTTPHeaderField: "User-Agent") == "BoringNotch/ClaudeUsage", "Requests must identify this app")
        _ = await probe.fetch(.init(allowKeychainPrompt: true))
        try expect(prompts.withLock { $0 == [false, false, true] }, "Only explicit connect may request Keychain interaction")

        for (status, failure) in [(401, ClaudeUsageFailure.expiredLogin), (403, .unsupportedAccount),
                                  (429, .rateLimited), (503, .connection), (302, .invalidResponse)] {
            ClaudeHTTPStub.state.withLock { $0 = .init(status: status, data: Data("private response".utf8), retryAfter: "7200") }
            let reply = await probe.fetch(.init(usage: true))
            try expect(reply.issue?.failure == failure && reply.snapshot == nil && reply.account != nil, "HTTP \(status) must preserve typed error and verified identity")
            if status == 429 { try expect(reply.issue?.retryAt == date.addingTimeInterval(7200), "Transport must preserve server cooldown") }
            let data = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
            try expect(!data.contains("private response") && !data.contains("fixture-access"), "XPC result must not expose bodies or tokens")
        }
        ClaudeHTTPStub.state.withLock { $0 = .init(error: URLError(.timedOut)) }
        try expect(await probe.fetch(.init(usage: true)).issue?.failure == .timedOut, "Timeout must have its own state")
        ClaudeHTTPStub.state.withLock { $0 = .init(data: Data(repeating: 32, count: 1_048_577)) }
        try expect(await probe.fetch(.init(usage: true)).issue?.failure == .invalidResponse, "Oversized streamed responses must stop")

        ClaudeHTTPStub.state.withLock { $0 = .init(data: payload) }
        async let a = probe.fetch(.init(usage: true))
        async let b = probe.fetch(.init(usage: true))
        let both = await [a, b]
        try expect(both.allSatisfy { $0.snapshot != nil } && ClaudeHTTPStub.state.withLock { $0.requests.count == 1 }, "Concurrent identical queries must share one HTTP request")
        let denied = ClaudeUsageProbe(session: session, readCredential: { _ in throw ClaudeUsageFailure.permissionRequired })
        try expect(await denied.fetch(.init(usage: true)).issue?.failure == .permissionRequired, "Denied Keychain access must be actionable")
        try expect(ClaudeHTTPStub.state.withLock { $0.requests.count == 1 }, "Denied credentials must make no network request")

        let redirected = OSAllocatedUnfairLock(initialState: true)
        ClaudeUsageRedirectGuard().urlSession(session, task: session.dataTask(with: ClaudeUsageProbe.endpoint),
            willPerformHTTPRedirection: HTTPURLResponse(url: ClaudeUsageProbe.endpoint, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://example.invalid")!)) { request in
                redirected.withLock { $0 = request != nil }
            }
        try expect(!redirected.withLock { $0 }, "Redirects must be rejected before credentials can leave the host")
    }
}
