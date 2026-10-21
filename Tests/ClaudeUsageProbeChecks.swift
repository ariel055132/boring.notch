import Foundation
import LocalAuthentication
import Security
import os

// All Keychain behavior is simulated. These checks never call Security APIs or
// query the real Claude Code credential.
private final class ClaudeKeychainStub {
    var interactionAllowed: Bool
    var getStatus = errSecSuccess
    var setStatuses: [OSStatus] = []
    var applyFailedSet = false
    var copyStatus = errSecSuccess
    var item: CFTypeRef? = Data("fixture-keychain-data".utf8) as CFData
    var events: [String] = []
    var query: [String: Any]?

    init(interactionAllowed: Bool = true) {
        self.interactionAllowed = interactionAllowed
    }

    var client: ClaudeUsageKeychainClient {
        ClaudeUsageKeychainClient(
            getInteractionAllowed: { [self] allowed in
                events.append("get")
                allowed = interactionAllowed
                return getStatus
            },
            setInteractionAllowed: { [self] allowed in
                events.append("set:\(allowed)")
                let status = setStatuses.isEmpty ? errSecSuccess : setStatuses.removeFirst()
                if status == errSecSuccess || applyFailedSet { interactionAllowed = allowed }
                return status
            },
            copyMatching: { [self] query, result in
                events.append("copy:\(interactionAllowed)")
                self.query = query as NSDictionary as? [String: Any]
                result = item
                return copyStatus
            }
        )
    }
}

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
        try keychainChecks()
        try parserChecks()
        try await transportChecks()
        print("Claude usage Keychain/parser/transport checks passed: \(checks)")
    }

    static func keychainChecks() throws {
        for original in [true, false] {
            for allowInteraction in [false, true] {
                let stub = ClaudeKeychainStub(interactionAllowed: original)
                let data = try ClaudeUsageKeychain.read(allowInteraction: allowInteraction, client: stub.client)
                try expect(data == Data("fixture-keychain-data".utf8), "A permitted read must return the fixture data")
                try expect(stub.events == ["get", "set:\(allowInteraction)", "copy:\(allowInteraction)", "set:\(original)"]
                           && stub.interactionAllowed == original,
                           "The legacy UI gate must apply before reading and restore the exact previous state")
                let context = stub.query?[kSecUseAuthenticationContext as String] as? LAContext
                try expect(context?.interactionNotAllowed == !allowInteraction,
                           "LocalAuthentication must enforce the same interaction policy as the legacy UI gate (requested: \(allowInteraction), observed: \(String(describing: context?.interactionNotAllowed)))")
                try expect(stub.query?[kSecAttrService as String] as? String == "Claude Code-credentials"
                           && stub.query?[kSecReturnData as String] as? Bool == true,
                           "The guarded query must still request only the Claude Code credential data")
            }
        }

        let failures: [(OSStatus, ClaudeUsageFailure)] = [
            (errSecItemNotFound, .notSignedIn),
            (errSecInteractionNotAllowed, .permissionRequired),
            (errSecInteractionRequired, .permissionRequired),
            (errSecAuthFailed, .permissionRequired),
            (errSecUserCanceled, .permissionRequired),
            (OSStatus(CSSMERR_CSP_NO_USER_INTERACTION), .permissionRequired),
            (OSStatus(CSSMERR_CSP_IN_DARK_WAKE), .permissionRequired),
            (errSecNotAvailable, .permissionRequired),
            (errSecParam, .connection)
        ]
        for (status, failure) in failures {
            let stub = ClaudeKeychainStub()
            stub.copyStatus = status
            try expectFailure(failure, "Keychain status \(status) must map to the actionable failure") {
                _ = try ClaudeUsageKeychain.read(allowInteraction: false, client: stub.client)
            }
            try expect(stub.events == ["get", "set:false", "copy:false", "set:true"] && stub.interactionAllowed,
                       "A failed Keychain read must restore the previous UI policy before returning")
        }

        for item: CFTypeRef? in [nil, "invalid fixture" as CFString] {
            let stub = ClaudeKeychainStub()
            stub.item = item
            try expectFailure(.notSignedIn, "Missing or non-data Keychain results must not be usable credentials") {
                _ = try ClaudeUsageKeychain.read(allowInteraction: false, client: stub.client)
            }
            try expect(stub.events == ["get", "set:false", "copy:false", "set:true"] && stub.interactionAllowed,
                       "Invalid credential data must not leave the process interaction policy changed")
        }

        let failedGet = ClaudeKeychainStub()
        failedGet.getStatus = errSecNotAvailable
        try expectFailure(.permissionRequired, "An unknown original UI policy must fail closed") {
            _ = try ClaudeUsageKeychain.read(allowInteraction: false, client: failedGet.client)
        }
        try expect(failedGet.events == ["get"] && failedGet.query == nil,
                   "A failed UI policy lookup must neither change policy nor read credentials")

        for allowInteraction in [false, true] {
            let failedSet = ClaudeKeychainStub(interactionAllowed: !allowInteraction)
            failedSet.setStatuses = [errSecNotAvailable]
            failedSet.applyFailedSet = true
            try expectFailure(.permissionRequired, "A failed UI policy change must fail closed") {
                _ = try ClaudeUsageKeychain.read(allowInteraction: allowInteraction, client: failedSet.client)
            }
            try expect(failedSet.events == ["get", "set:\(allowInteraction)", "set:\(!allowInteraction)"]
                       && failedSet.query == nil && failedSet.interactionAllowed == !allowInteraction,
                       "A failed UI policy change must restore even a partially changed policy without reading credentials")
        }

        let failedRestore = ClaudeKeychainStub()
        failedRestore.setStatuses = [errSecSuccess, errSecNotAvailable]
        try expectFailure(.permissionRequired, "A failed UI policy restoration must not return credential data") {
            _ = try ClaudeUsageKeychain.read(allowInteraction: false, client: failedRestore.client)
        }
        try expect(failedRestore.events == ["get", "set:false", "copy:false", "set:true"],
                   "A successful credential read must still attempt restoration before reporting a policy failure")

        try concurrentKeychainChecks()
    }

    static func concurrentKeychainChecks() throws {
        struct State {
            var allowed = false
            var activeReads = 0
            var maximumActiveReads = 0
            var successfulReads = 0
            var policyMismatch = false
        }
        let shared = OSAllocatedUnfairLock(initialState: State())
        let fixture = Data("concurrent-fixture".utf8)
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let allowInteraction = index.isMultiple(of: 2)
            var settingCalls = 0
            let client = ClaudeUsageKeychainClient(
                getInteractionAllowed: { allowed in
                    allowed = shared.withLock {
                        $0.activeReads += 1
                        $0.maximumActiveReads = max($0.maximumActiveReads, $0.activeReads)
                        return $0.allowed
                    }
                    return errSecSuccess
                },
                setInteractionAllowed: { allowed in
                    settingCalls += 1
                    let restoring = settingCalls == 2
                    shared.withLock {
                        $0.allowed = allowed
                        if restoring { $0.activeReads -= 1 }
                    }
                    // Give an unguarded concurrent caller time to change the
                    // process-wide policy between setting it and reading.
                    if settingCalls == 1 { Thread.sleep(forTimeInterval: 0.001) }
                    return errSecSuccess
                },
                copyMatching: { _, result in
                    shared.withLock {
                        if $0.allowed != allowInteraction { $0.policyMismatch = true }
                    }
                    result = fixture as CFData
                    return errSecSuccess
                }
            )
            if (try? ClaudeUsageKeychain.read(allowInteraction: allowInteraction, client: client)) == fixture {
                shared.withLock { $0.successfulReads += 1 }
            }
        }
        let result = shared.withLock { $0 }
        try expect(result.successfulReads == 24 && result.maximumActiveReads == 1 && result.activeReads == 0,
                   "Concurrent Connect and background reads must serialize the complete policy/read/restore operation")
        try expect(!result.policyMismatch && !result.allowed,
                   "An interactive read must never enable UI for a concurrent background read or change the original policy")
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
