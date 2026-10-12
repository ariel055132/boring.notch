import SwiftUI

enum AIUsageProvider: String, CaseIterable {
    case codex, claude
}

struct AIUsageView: View {
    @AppStorage("aiUsageProvider") private var provider = AIUsageProvider.codex

    var body: some View {
        switch provider {
        case .codex: CodexUsageView(provider: $provider)
        case .claude: ClaudeUsageView(provider: $provider)
        }
    }
}

struct AIUsageProviderPicker: View {
    @Binding var selection: AIUsageProvider

    var body: some View {
        Picker("AI usage provider", selection: $selection) {
            Text("Codex").tag(AIUsageProvider.codex)
            Text("Claude").tag(AIUsageProvider.claude)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 145)
    }
}
