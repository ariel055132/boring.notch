import SwiftUI

enum CodexUsageSection: String, CaseIterable {
    case overview, history
}

struct CodexUsageView: View {
    @ObservedObject var manager: CodexUsageManager
    @State private var section: CodexUsageSection
    @State private var selectedDay: String?

    init(manager: CodexUsageManager = .shared, section: CodexUsageSection = .overview) {
        self.manager = manager
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Picker("Codex usage view", selection: $section) {
                    Text("Remaining").tag(CodexUsageSection.overview)
                    Text("Last 7 days").tag(CodexUsageSection.history)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer(minLength: 0)
                if let retry = manager.retryAt {
                    Text("Checks paused until \(retry.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                        .help(retry.formatted())
                }
            }
            Group {
                if section == .history {
                    if let history = manager.history { historyView(history) }
                    else { historyEmptyState }
                } else if let snapshot = manager.snapshot {
                    usage(snapshot)
                } else {
                    emptyState
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.loadIfNeeded() }
    }

    private func usage(_ snapshot: CodexUsageSnapshot) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 3) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Codex", systemImage: "chart.bar.xaxis")
                            .font(.system(size: 15, weight: .semibold))
                        if let plan = snapshot.plan {
                            Text(plan.capitalized)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        if let email = snapshot.accountEmail {
                            Text(email)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(email)
                        }
                        if snapshot.unlimitedCredits {
                            Text("Unlimited credits").font(.system(size: 10))
                        } else if let credits = snapshot.credits {
                            Text("\(credits.formatted(.number.precision(.fractionLength(0...1)))) credits")
                                .font(.system(size: 10)).monospacedDigit()
                        }
                    }
                    .frame(width: max(0, geometry.size.width * 0.28), alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView(.vertical) {
                            VStack(spacing: 4) {
                                ForEach(snapshot.windows) { window in
                                    windowRow(window, at: context.date)
                                }
                                if snapshot.windows.isEmpty {
                                    Text("No percentage limits reported")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.trailing, 3)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                HStack(alignment: .bottom, spacing: 6) {
                    HStack(spacing: 6) {
                        if let failure = manager.failure {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("Last known usage")
                                .foregroundStyle(.orange)
                                .help(failure.localizedDescription)
                        } else {
                            Text("Plan usage").foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 18)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        dashboardLink.font(.system(size: 10))
                        Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(manager.failure == nil ? Color.secondary : Color.orange)
                            .help(snapshot.fetchedAt.formatted())
                            .frame(height: 18)
                    }
                    refreshButton
                }
                .font(.system(size: 9))
            }
        }
    }

    private func historyView(_ history: CodexUsageHistory) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let days = history.recentDays(at: context.date)
            let selected = days.first(where: { $0.id == selectedDay })
                ?? days.last(where: { $0.tokens != nil }) ?? days.last!
            let total = CodexUsageHistory.reportedTotal(days)
            GeometryReader { geometry in
                VStack(spacing: 5) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex · 7 days").font(.system(size: 12, weight: .semibold))
                                .help(manager.account?.email ?? "Codex")
                            Text(total.map(compactTokens) ?? "—")
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                .help(total.map { $0.formatted() + " tokens" } ?? String(localized: "No reported data"))
                            Text("tokens reported").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("\(days.filter { $0.tokens != nil }.count) of 7 days reported")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(width: max(0, geometry.size.width * 0.28), alignment: .leading)
                        VStack(spacing: 4) {
                            HStack {
                                Text(selected.date.formatted(.dateTime.month(.abbreviated).day()))
                                Spacer(minLength: 4)
                                Text(selected.tokens.map { String(localized: "\($0.formatted()) tokens") }
                                     ?? String(localized: "Not reported"))
                                    .foregroundStyle(selected.tokens == nil ? .secondary : .primary)
                            }
                            .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                            tokenChart(days, selected: selected.id)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    HStack(spacing: 5) {
                        if manager.historyFailure != nil || context.date.timeIntervalSince(history.fetchedAt) >= CodexUsageManager.historyRefreshInterval {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                                .help(manager.historyFailure?.localizedDescription ?? String(localized: "Showing the last successful update."))
                        }
                        if let date = history.latestReportedDate {
                            Text("Data through \(date)")
                                .help("Dates are reported by Codex. Missing days are not counted as zero.")
                        } else { Text("No reported data") }
                        Spacer(minLength: 0)
                        if manager.cacheUnavailable {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                                .foregroundStyle(.orange).help("Could not save usage data and cooldowns on this Mac.")
                        }
                        Text("Updated \(history.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .help(history.fetchedAt.formatted())
                        refreshButton
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 18)
                }
            }
        }
    }

    private func tokenChart(_ days: [CodexUsageDay], selected: String) -> some View {
        let maximum = max(1, days.compactMap(\.tokens).max() ?? 1)
        return GeometryReader { geometry in
            let barHeight = max(0, geometry.size.height - 17)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { day in
                    let fraction = Double(day.tokens ?? 0) / Double(maximum)
                    let height: CGFloat = day.tokens == 0 ? 2 : max(3, barHeight * CGFloat(fraction))
                    let tint: Color = day.id == selected ? .accentColor : .accentColor.opacity(0.45)
                    let dateLabel = String(day.id.suffix(5)).replacingOccurrences(of: "-", with: "/")
                    let description = day.id + ": " + (day.tokens.map { $0.formatted() + " tokens" } ?? String(localized: "Not reported"))
                    Button {
                        selectedDay = day.id
                    } label: {
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(day.id == selected ? 0.09 : 0.03))
                                if day.tokens != nil {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(tint)
                                        .frame(height: height)
                                } else {
                                    Text("—").font(.system(size: 10)).foregroundStyle(.secondary)
                                        .padding(.bottom, 2)
                                }
                            }
                            .frame(height: barHeight)
                            Text(dateLabel)
                                .font(.system(size: 8)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(day.id == selected ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(description)
                    .accessibilityLabel(description)
                    .accessibilityAddTraits(day.id == selected ? .isSelected : [])
                }
            }
        }
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private var historyEmptyState: some View {
        VStack(spacing: 6) {
            Label("Daily token usage", systemImage: "chart.bar.xaxis")
                .font(.system(size: 14, weight: .semibold))
            if manager.isLoading { ProgressView().controlSize(.small) }
            Text(manager.historyFailure?.localizedDescription ?? (manager.isLoading || manager.account == nil
                 ? String(localized: "Checking your Codex account and reported token usage…")
                 : String(localized: "Daily usage is waiting for the next scheduled check.")))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
            HStack(spacing: 8) {
                Text("Checks at most once an hour.").font(.system(size: 9)).foregroundStyle(.secondary)
                refreshButton
            }
        }
        .frame(maxWidth: 440, maxHeight: .infinity)
    }

    private func windowRow(_ window: CodexUsageWindow, at date: Date) -> some View {
        let remaining = window.isCurrent(at: date) ? window.remainingPercent : nil
        let tint: Color = remaining.map { $0 <= 10 ? .red : ($0 <= 25 ? .orange : .green) } ?? .gray
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(window.bucketName.map { "\($0) · \(window.durationLabel)" } ?? window.durationLabel)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(remaining.map { String(localized: "\($0.formatted(.number.precision(.fractionLength(0))))% left") }
                     ?? String(localized: "Unavailable"))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit().foregroundStyle(remaining == nil ? .secondary : .primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let remaining {
                        Capsule().fill(tint)
                            .frame(width: max(0, geometry.size.width * remaining / 100))
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Group {
                if !window.isCurrent(at: date) {
                    Text("Reset time passed · waiting for an update")
                } else if let reset = window.resetsAt {
                    Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Reset time unavailable")
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Label("Codex usage", systemImage: "chart.bar.xaxis")
                .font(.system(size: 15, weight: .semibold))
            if manager.isLoading && manager.failure == nil {
                ProgressView().controlSize(.small)
                Text("Checking your Codex usage…").font(.system(size: 11))
            } else {
                Text(manager.failure?.localizedDescription ?? String(localized: "See the remaining usage for your Codex plan."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                HStack(spacing: 12) {
                    dashboardLink
                    refreshButton
                }
                .font(.system(size: 11))
                Text(manager.failure == .rateLimited ? "Updates will retry after a cooldown." : "Updates automatically every 3 minutes.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
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
            .buttonStyle(.plain)
            .disabled(section == .history ? !manager.canRefreshHistory : !manager.canRefresh)
            .accessibilityLabel("Refresh Codex usage")
            .help(section == .history ? String(localized: "Daily token checks are limited to once an hour. Switching dates uses cached data.")
                  : manager.canRefresh ? String(localized: "Refresh Codex usage")
                  : String(localized: "Usage checks are limited to once every 3 minutes, with a longer wait if Codex requests it."))
        }
    }

    private var dashboardLink: some View {
        Link("Open Codex", destination: URL(string: "https://chatgpt.com/codex")!)
            .foregroundStyle(.secondary)
    }
}
