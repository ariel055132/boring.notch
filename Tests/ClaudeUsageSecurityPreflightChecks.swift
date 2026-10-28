import Foundation
import Security

// Pure metadata fixtures: never reads credentials or calls the live inspector.
@main
private struct ClaudeUsageSecurityPreflightChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "ClaudeSecurityPreflightChecks", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func hexPlist(_ object: Any) throws -> String {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                .map { String(format: "%02x", $0) }.joined()
        }
        let allowedPartition = try hexPlist(["Partitions": ["apple-tool:", "apple:"]])
        let security = Data("/usr/bin/security\0".utf8)
        func fixture(service: String = "Claude Code-credentials", account: String = "fixture-user",
                     path: String = "/tmp/fixture.keychain-db", status: UInt32 = 3,
                     applications: [Data]? = [security], selector: UInt16 = 0,
                     decrypt: Bool = true, partition: String? = allowedPartition,
                     partitionCount: Int = 1) -> ClaudeUsageSecurityMetadata {
            var entries: [ClaudeUsageSecurityACLEntry] = []
            if decrypt {
                entries.append(.init(authorizations: [kSecACLAuthorizationDecrypt as String],
                                     trustedApplicationData: applications, promptSelector: selector,
                                     description: "fixture"))
            }
            for _ in 0..<partitionCount {
                entries.append(.init(authorizations: [kSecACLAuthorizationPartitionID as String],
                                     trustedApplicationData: nil, promptSelector: 0, description: partition))
            }
            return .init(service: service, account: account, keychainPath: path,
                         keychainStatus: status, entries: entries)
        }
        func reject(_ metadata: ClaudeUsageSecurityMetadata, _ message: String) throws {
            do {
                _ = try ClaudeUsageSecurityPreflight.evaluate(metadata)
                try expect(false, message)
            } catch let failure as ClaudeUsageFailure {
                try expect(failure == .permissionRequired, message)
            }
        }
        let target = try ClaudeUsageSecurityPreflight.evaluate(fixture())
        try expect(target == .init(account: "fixture-user", keychainPath: "/tmp/fixture.keychain-db"),
                   "Valid metadata must bind the CLI to the inspected account and keychain")
        try expect(try ClaudeUsageSecurityPreflight.partitionIDs(allowedPartition.uppercased())
            == ["apple-tool:", "apple:"], "Hex decoding must support either hex case")
        for ids in [["apple:"], ["cdhash:fixture"], ["apple-tool:evil"], ["prefix-apple-tool:"], []] {
            try reject(fixture(partition: try hexPlist(["Partitions": ids])), "Only the exact Apple tool partition is eligible")
        }
        for status: UInt32 in [0, 1, 2, 4, 5, 6] {
            try reject(fixture(status: status), "Both unlocked and read permission are required")
        }
        try reject(fixture(decrypt: false), "A partition alone does not authorize decryption")
        try reject(fixture(applications: nil), "Unrestricted ACLs are outside the explicit tool policy")
        try reject(fixture(applications: []), "Empty app lists are not authorization")
        for bytes in ["/usr/bin/security", "/usr/bin/security-other\0", "/tmp/security\0", "/usr/bin/security\0extra"] {
            try reject(fixture(applications: [Data(bytes.utf8)]), "Only the exact terminated tool path is eligible")
        }
        for selector: UInt16 in [1, 16, 32, 64, 128, UInt16.max] {
            try reject(fixture(selector: selector), "Prompt selectors must fail closed")
        }
        for partition in [nil, "", "0", "zz", "6162", allowedPartition + "z0", String(repeating: "00", count: 65_537)] as [String?] {
            try reject(fixture(partition: partition), "Missing, malformed, or oversized partition data must fail closed")
        }
        for object: Any in [["Other": ["apple-tool:"]], ["Partitions": "apple-tool:"],
                            ["Partitions": [1]], ["apple-tool:"]] {
            try reject(fixture(partition: try hexPlist(object)), "Partition plist shape must be validated")
        }
        try reject(fixture(partitionCount: 0), "Missing partition ACLs must fail closed")
        try reject(fixture(partitionCount: 2), "Ambiguous partition ACLs must fail closed")
        try reject(fixture(service: "Other-credentials"), "The fixed service must match inspected metadata")
        for account in ["", "user\0suffix", String(repeating: "a", count: 1025)] {
            try reject(fixture(account: account), "Invalid account metadata must fail closed")
        }
        for path in ["relative.keychain", "", "/tmp/keychain\0suffix"] {
            try reject(fixture(path: path), "Invalid keychain paths must fail closed")
        }
        print("Claude usage security preflight checks passed: \(checks)")
    }
}
