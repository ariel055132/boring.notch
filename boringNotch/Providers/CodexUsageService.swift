import Foundation

protocol CodexUsageServiceProviding: Sendable {
    func fetchUsage(_ request: CodexUsageRequest) async throws -> CodexUsageResult
}

struct CodexUsageService: CodexUsageServiceProviding {
    func fetchUsage(_ request: CodexUsageRequest) async throws -> CodexUsageResult {
        try await XPCHelperClient.shared.fetchCodexUsage(request)
    }
}
