import SwiftUI

struct ClaudeUsageView: View {
    @ObservedObject var manager: ClaudeUsageManager
    @Binding var provider: AIUsageProvider

    init(manager: ClaudeUsageManager = .shared, provider: Binding<AIUsageProvider> = .constant(.claude)) {
        self.manager = manager
        _provider = provider
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                AIUsageProviderPicker(selection: $provider)
                Text("Remaining").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let retry = manager.retryAt {
                    Text("Checks paused until \(retry.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                        .help(retry.formatted())
                }
            }
            Group {
                if let snapshot = manager.snapshot { usage(snapshot) }
                else { emptyState }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.loadIfNeeded() }
    }

    private func usage(_ snapshot: ClaudeUsageSnapshot) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 3) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Claude", systemImage: "sparkle")
                            .font(.system(size: 15, weight: .semibold))
                        if let plan = snapshot.account.plan {
                            Text(plan.capitalized)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        Text("Subscription usage").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: max(0, geometry.size.width * 0.28), alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView(.vertical) {
                            VStack(spacing: 5) {
                                ForEach(snapshot.windows) { window in
                                    windowRow(window, at: context.date)
                                }
                            }
                            .padding(.trailing, 3)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 8) {
                    if let failure = manager.failure {
                        Label("Last known usage", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).help(failure.localizedDescription)
                    } else {
                        Text("Plan usage").foregroundStyle(.secondary)
                    }
                    if manager.cacheUnavailable {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange).help("Could not save usage data and cooldowns on this Mac.")
                    }
                    Spacer(minLength: 0)
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(manager.failure == nil ? Color.secondary : Color.orange)
                        .help(snapshot.fetchedAt.formatted())
                    dashboardLink
                    refreshButton
                }
                .font(.system(size: 9)).frame(height: 18)
            }
        }
    }

    private func windowRow(_ window: ClaudeUsageWindow, at date: Date) -> some View {
        let remaining = window.isCurrent(at: date) ? window.remainingPercent : nil
        let tint: Color = remaining.map { $0 <= 10 ? .red : ($0 <= 25 ? .orange : .green) } ?? .gray
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(window.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(remaining.map { String(localized: "\($0.formatted(.number.precision(.fractionLength(0))))% left") }
                     ?? String(localized: "Unavailable"))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(remaining == nil ? .secondary : .primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let remaining {
                        Capsule().fill(tint).frame(width: geometry.size.width * CGFloat(remaining / 100))
                    }
                }
            }
            .frame(height: 5).accessibilityHidden(true)
            Group {
                if !window.isCurrent(at: date) { Text("Reset time passed · waiting for an update") }
                else if let reset = window.resetsAt {
                    Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                } else { Text("Reset time unavailable") }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Label("Claude usage", systemImage: "sparkle").font(.system(size: 14, weight: .semibold))
            if manager.isLoading {
                ProgressView().controlSize(.small)
                Text("Checking your Claude usage…").font(.system(size: 11))
            } else {
                Text(manager.failure?.localizedDescription ?? String(localized: "See the remaining usage for your Claude subscription."))
                    .font(.system(size: 11))
                    .foregroundStyle(manager.failure == .expiredLogin ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                HStack(spacing: 12) {
                    dashboardLink
                    if manager.failure?.needsConnection == true || manager.account == nil {
                        Button(action: manager.connect) {
                            if manager.failure == .expiredLogin { Text("Retry connection") }
                            else { Text("Connect Claude Code") }
                        }
                        .buttonStyle(.borderless)
                    } else { refreshButton }
                }
                .font(.system(size: 11))
                if manager.failure == .expiredLogin {
                    Text("Retry checks your existing sign-in. Renew it in Claude Code first.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let next = manager.nextRefreshAt, manager.failure?.needsConnection != true {
                    Text("Next check \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(.secondary).help(next.formatted())
                } else {
                    Text("Updates automatically every 5 minutes.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 440, maxHeight: .infinity)
    }

    private var refreshButton: some View {
        HStack(spacing: 4) {
            if manager.isLoading { ProgressView().controlSize(.mini) }
            Button(action: manager.refresh) {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 18)
            }
            .buttonStyle(.plain).disabled(!manager.canRefresh)
            .accessibilityLabel("Refresh Claude usage")
            .help(manager.canRefresh ? String(localized: "Refresh Claude usage")
                  : String(localized: "Usage checks are limited to once every 5 minutes, with a longer wait if Claude requests it."))
        }
    }

    private var dashboardLink: some View {
        Link("Open Claude", destination: URL(string: "https://claude.ai/settings/usage")!)
            .foregroundStyle(.secondary)
    }
}
