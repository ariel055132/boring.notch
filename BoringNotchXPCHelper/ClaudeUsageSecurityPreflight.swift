import Foundation
import Security

struct ClaudeUsageSecurityTarget: Equatable, Sendable {
    let account: String
    let keychainPath: String
}

// Metadata only. This type never contains the credential's password data.
struct ClaudeUsageSecurityMetadata: Sendable {
    let service: String
    let account: String
    let keychainPath: String
    let keychainStatus: UInt32
    let entries: [ClaudeUsageSecurityACLEntry]
}

struct ClaudeUsageSecurityACLEntry: Sendable {
    let authorizations: [String]
    let trustedApplicationData: [Data]?
    let promptSelector: UInt16
    let description: String?
}

enum ClaudeUsageSecurityPreflight {
    static let service = "Claude Code-credentials"
    static let executable = "/usr/bin/security"

    // The caller must hold ClaudeUsageKeychain's process-wide interaction lock
    // with interaction disabled throughout this inspection. This is a preflight,
    // not an atomic authorization: another process can change the ACL or lock
    // the keychain before the subsequent security CLI read.
    #if compiler(>=6.4)
    @diagnose(DeprecatedDeclaration, as: ignored)
    #endif
    static func inspect() throws -> ClaudeUsageSecurityTarget {
        var interaction = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess,
              !interaction.boolValue else { throw ClaudeUsageFailure.permissionRequired }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ClaudeUsageFailure.notSignedIn }
        guard status == errSecSuccess,
              let records = result as? [[String: Any]], records.count == 1,
              let record = records.first,
              let actualService = record[kSecAttrService as String] as? String,
              let account = record[kSecAttrAccount as String] as? String,
              let value = record[kSecValueRef as String],
              CFGetTypeID(value as CFTypeRef) == SecKeychainItemGetTypeID() else {
            throw ClaudeUsageFailure.permissionRequired
        }
        let item = value as! SecKeychainItem
        var keychain: SecKeychain?
        var keychainStatus: SecKeychainStatus = 0
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess,
              let keychain,
              SecKeychainGetStatus(keychain, &keychainStatus) == errSecSuccess else {
            throw ClaudeUsageFailure.permissionRequired
        }
        var pathBytes = [CChar](repeating: 0, count: 4096)
        var pathLength = UInt32(pathBytes.count)
        guard SecKeychainGetPath(keychain, &pathLength, &pathBytes) == errSecSuccess,
              pathLength <= pathBytes.count,
              let terminator = pathBytes.firstIndex(of: 0), terminator > 0,
              let path = String(bytes: pathBytes[..<terminator].map { UInt8(bitPattern: $0) },
                                encoding: .utf8) else {
            throw ClaudeUsageFailure.permissionRequired
        }

        var access: SecAccess?
        var aclList: CFArray?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess,
              let access,
              SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let entries = aclList as? [SecACL], entries.count <= 64 else {
            throw ClaudeUsageFailure.permissionRequired
        }
        var metadata: [ClaudeUsageSecurityACLEntry] = []
        for acl in entries {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String] else {
                throw ClaudeUsageFailure.permissionRequired
            }
            guard authorizations.contains(kSecACLAuthorizationDecrypt as String)
                    || authorizations.contains(kSecACLAuthorizationPartitionID as String) else { continue }
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(acl, &applications, &description, &selector) == errSecSuccess else {
                throw ClaudeUsageFailure.permissionRequired
            }
            var applicationData: [Data]?
            if let applications {
                guard let trusted = applications as? [SecTrustedApplication], trusted.count <= 64 else {
                    throw ClaudeUsageFailure.permissionRequired
                }
                applicationData = try trusted.map { application in
                    var data: CFData?
                    guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess,
                          let data, CFDataGetLength(data) <= 4096 else {
                        throw ClaudeUsageFailure.permissionRequired
                    }
                    return data as Data
                }
            }
            metadata.append(.init(authorizations: authorizations,
                                  trustedApplicationData: applicationData,
                                  promptSelector: selector.rawValue,
                                  description: description as String?))
        }
        return try evaluate(.init(service: actualService, account: account,
                                  keychainPath: path, keychainStatus: keychainStatus,
                                  entries: metadata))
    }

    static func evaluate(_ metadata: ClaudeUsageSecurityMetadata) throws -> ClaudeUsageSecurityTarget {
        let requiredStatus = UInt32(kSecUnlockStateStatus | kSecReadPermStatus)
        guard metadata.service == service,
              !metadata.account.isEmpty, metadata.account.utf8.count <= 1024,
              !metadata.account.utf8.contains(0),
              metadata.keychainPath.hasPrefix("/"), metadata.keychainPath.utf8.count <= 4096,
              !metadata.keychainPath.utf8.contains(0),
              metadata.keychainStatus & requiredStatus == requiredStatus,
              metadata.entries.count <= 64 else { throw ClaudeUsageFailure.permissionRequired }

        let decryptAllowed = metadata.entries.contains { entry in
            entry.authorizations.contains(kSecACLAuthorizationDecrypt as String)
                && entry.promptSelector == 0
                && entry.trustedApplicationData?.contains(where: isSecurityApplication) == true
        }
        let partitions = metadata.entries.filter {
            $0.authorizations.contains(kSecACLAuthorizationPartitionID as String)
        }
        guard decryptAllowed, partitions.count == 1,
              let description = partitions.first?.description,
              try partitionIDs(description).contains("apple-tool:") else {
            throw ClaudeUsageFailure.permissionRequired
        }
        return .init(account: metadata.account, keychainPath: metadata.keychainPath)
    }

    static func isSecurityApplication(_ data: Data) -> Bool {
        // CopyData contains only a NUL-terminated path, not its signing
        // requirement. Keep this conservative and do not accept path prefixes.
        data == Data((executable + "\0").utf8)
    }

    static func partitionIDs(_ description: String) throws -> [String] {
        let bytes = Array(description.utf8)
        guard !bytes.isEmpty, bytes.count <= 131_072, bytes.count.isMultiple(of: 2) else {
            throw ClaudeUsageFailure.permissionRequired
        }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                throw ClaudeUsageFailure.permissionRequired
            }
            data.append(high * 16 + low)
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let partitions = dictionary["Partitions"] as? [String],
              !partitions.isEmpty, partitions.count <= 64,
              partitions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.utf8.contains(0) }) else {
            throw ClaudeUsageFailure.permissionRequired
        }
        return partitions
    }
}
