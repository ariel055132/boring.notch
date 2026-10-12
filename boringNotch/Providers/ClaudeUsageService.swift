import Foundation

protocol ClaudeUsageServiceProviding: Sendable {
    func fetchUsage(_ request: ClaudeUsageRequest) async throws -> ClaudeUsageResult
}

struct ClaudeUsageService: ClaudeUsageServiceProviding {
    func fetchUsage(_ request: ClaudeUsageRequest) async throws -> ClaudeUsageResult {
        try await XPCHelperClient.shared.fetchClaudeUsage(request)
    }
}
