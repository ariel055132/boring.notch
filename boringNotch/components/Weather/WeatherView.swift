import AppKit
import SwiftUI

struct WeatherView: View {
    @ObservedObject var manager: WeatherManager
    @State private var showDaily: Bool

    init(manager: WeatherManager = .shared, showDaily: Bool = false) {
        self.manager = manager
        _showDaily = State(initialValue: showDaily)
    }

    var body: some View {
        Group {
            if let snapshot = manager.snapshot {
                forecast(snapshot)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { manager.loadIfNeeded() }
    }

    private func forecast(_ snapshot: WeatherSnapshot) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                HStack(alignment: .top, spacing: 16) {
                    currentWeather(snapshot)
                        .frame(width: max(0, geometry.size.width * 0.32), alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            forecastButton("24 hours", selected: !showDaily) { showDaily = false }
                            forecastButton("7 days", selected: showDaily) { showDaily = true }
                            Spacer(minLength: 0)
                            if manager.isLoading { ProgressView().controlSize(.mini) }
                            Button(action: manager.refresh) {
                                Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(manager.canRefresh ? String(localized: "Refresh weather") : String(localized: "Weather updates automatically every 3 minutes."))
                            .accessibilityLabel("Refresh weather")
                            .disabled(!manager.canRefresh)
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                if showDaily {
                                    ForEach(snapshot.daily) { day in
                                        forecastItem(title: snapshot.dayLabel(day.date), condition: day.condition,
                                                     temperature: degrees(day.high), lowTemperature: degrees(day.low),
                                                     rain: day.precipitationProbability)
                                    }
                                } else {
                                    ForEach(snapshot.hourly) { hour in
                                        forecastItem(title: snapshot.hourLabel(hour.time), condition: hour.condition,
                                                     temperature: degrees(hour.temperature), rain: hour.precipitationProbability)
                                    }
                                }
                            }
                            .padding(.bottom, 3)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 6) {
                    attribution
                    Spacer(minLength: 0)
                    if let failure = manager.failure {
                        Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)) · \(failure.localizedDescription)")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(failure.localizedDescription)
                        if failure == .locationDenied {
                            Button("Location Settings", action: openLocationSettings).buttonStyle(.plain)
                        }
                    } else {
                        Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 9))
                .frame(height: 12)
            }
        }
    }

    private func currentWeather(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(manager.placeName, systemImage: "location.fill")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .help(manager.placeName)
            HStack(spacing: 8) {
                Image(systemName: snapshot.current.condition.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 27))
                    .accessibilityHidden(true)
                Text("\(degrees(snapshot.current.temperature))C")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text(snapshot.current.condition.description)
                .font(.system(size: 11))
                .lineLimit(1)
            if let today = snapshot.daily.first {
                Text("H: \(degrees(today.high))  L: \(degrees(today.low))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let apparent = snapshot.current.apparentTemperature {
                Text("Feels like \(degrees(apparent))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func forecastButton(_ label: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? Color.white.opacity(0.15) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : .gray)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func forecastItem(title: String, condition: WeatherCondition, temperature: String, lowTemperature: String? = nil, rain: Double?) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Image(systemName: condition.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
                .frame(height: 24)
                .accessibilityLabel(condition.description)
            VStack(spacing: 1) {
                Text(temperature).font(.system(size: 11, weight: .medium))
                if let lowTemperature {
                    Text(lowTemperature).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text(rain.map { "\(min(100, max(0, $0)).formatted(.number.precision(.fractionLength(0))))%" } ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(.cyan)
                .help("Chance of precipitation")
        }
        .frame(minWidth: 40)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if manager.isLoading && manager.failure == nil {
                ProgressView().controlSize(.small)
                Text("Finding your location and weather…").font(.system(size: 11))
            } else {
                Label(manager.failure == nil ? "Local weather" : "Weather unavailable", systemImage: "cloud.sun.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(manager.failure?.localizedDescription ?? String(localized: "Use your location to see current conditions and forecasts."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button(manager.failure == nil ? "Use current location" : "Try again", action: manager.refresh)
                        .disabled(!manager.canRefresh)
                    if manager.failure == .locationDenied || manager.failure == .locationUnavailable {
                        Button("Location Settings", action: openLocationSettings)
                    }
                }
                .controlSize(.small)
                if manager.failure != nil {
                    HStack(spacing: 5) {
                        if manager.isLoading { ProgressView().controlSize(.mini) }
                        Text("Weather updates automatically every 3 minutes.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            attribution.font(.system(size: 9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attribution: some View {
        Link("Weather data: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
            .foregroundStyle(.secondary)
            .help("Weather data by Open-Meteo, licensed under CC BY 4.0")
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func degrees(_ temperature: Double) -> String {
        "\(temperature.rounded().formatted(.number.precision(.fractionLength(0))))°"
    }
}
