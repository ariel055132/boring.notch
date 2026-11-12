import Foundation

// Explicit opt-in only. Uses the existing account; never prints tokens, changes
// expiry dates, forces logout, or creates a model conversation.
@main
private struct ClaudeUsageRenewalLiveCheck {
    static func main() async throws {
        guard CommandLine.arguments.dropFirst() == ["--run"] else {
            print("Pass --run to check the installed Claude CLI using your existing sign-in.")
            return
        }
        let before = try ClaudeUsageParser.credential(
            await ClaudeUsageCredentialReader.read(allowInteraction: false), at: Date(), allowExpired: true)
        let expiredBefore = before.isExpired(at: Date())
        print("Before: expired=\(expiredBefore), renewable=\(before.canRenew)")
        if !expiredBefore {
            // Also exercise the production control protocol when today's token
            // is still valid; this does not prove expired-login recovery.
            try await ClaudeUsageRenewalProcess.renew()
            print("CLI control protocol: passed zero model-usage validation")
        }
        let result = await ClaudeUsageProbe().fetch(.init(usage: true))
        let after = try ClaudeUsageParser.credential(
            await ClaudeUsageCredentialReader.read(allowInteraction: false), at: Date(), allowExpired: true)
        print("After: expired=\(after.isExpired(at: Date())), credentialChanged=\(before.account != after.account)")
        print("Usage: \(result.snapshot == nil ? "unavailable" : "available"), issue=\(result.issue?.failure.rawValue ?? "none")")
        if expiredBefore, result.snapshot != nil {
            print("Expired credential recovery: passed")
        } else if !expiredBefore {
            print("Expired credential recovery: not exercised; the real token was already valid")
        }
        if let issue = result.issue { throw issue.failure }
    }
}
