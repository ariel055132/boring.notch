import Foundation

struct WeatherCoordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    // Weather forecasts do not need a precise street-level location.
    var approximate: WeatherCoordinate {
        WeatherCoordinate(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
    }
}

struct WeatherCondition: Sendable, Equatable, Codable {
    let code: Int
    var isDay = true

    var symbol: String {
        switch code {
        case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 97: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud"
        }
    }

    var description: String {
        switch code {
        case 0: return String(localized: "Clear")
        case 1: return String(localized: "Mostly clear")
        case 2: return String(localized: "Partly cloudy")
        case 3: return String(localized: "Overcast")
        case 45, 48: return String(localized: "Fog")
        case 51, 53, 55: return String(localized: "Drizzle")
        case 56, 57, 66, 67: return String(localized: "Freezing rain")
        case 61, 63: return String(localized: "Rain")
        case 65: return String(localized: "Heavy rain")
        case 71, 73, 75, 77: return String(localized: "Snow")
        case 80, 81, 82: return String(localized: "Rain showers")
        case 85, 86: return String(localized: "Snow showers")
        case 95, 97: return String(localized: "Thunderstorm")
        case 96, 99: return String(localized: "Thunderstorm with hail")
        default: return String(localized: "Weather unavailable")
        }
    }
}

struct CurrentWeather: Sendable, Codable {
    let time: Date
    let temperature: Double
    let apparentTemperature: Double?
    let humidity: Double?
    let windSpeed: Double?
    let condition: WeatherCondition
}

struct HourlyWeather: Identifiable, Sendable, Codable {
    var id: Date { time }
    let time: Date
    let temperature: Double
    let precipitationProbability: Double?
    let condition: WeatherCondition
}

struct DailyWeather: Identifiable, Sendable, Codable {
    var id: Date { date }
    let date: Date
    let high: Double
    let low: Double
    let precipitationProbability: Double?
    let condition: WeatherCondition
}

struct WeatherSnapshot: Sendable, Codable {
    let current: CurrentWeather
    let hourly: [HourlyWeather]
    let daily: [DailyWeather]
    let timeZone: TimeZone
    let fetchedAt: Date

    func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func dayLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: current.time) { return String(localized: "Today") }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

enum WeatherFailure: Error, LocalizedError, Equatable {
    case locationDenied, locationUnavailable, locationTimedOut, invalidResponse, network, serviceUnavailable, dataExpired

    var errorDescription: String? {
        switch self {
        case .locationDenied: return String(localized: "Allow location access in System Settings to see local weather.")
        case .locationUnavailable: return String(localized: "Your location is unavailable. Check Location Services and try again.")
        case .locationTimedOut: return String(localized: "Finding your location took too long. Please try again.")
        case .invalidResponse: return String(localized: "Weather data is incomplete. Please try again later.")
        case .network: return String(localized: "Could not update weather. Check your internet connection.")
        case .serviceUnavailable: return String(localized: "The weather service is unavailable. Please try again later.")
        case .dataExpired: return String(localized: "Weather is currently unavailable. Updates will retry automatically.")
        }
    }
}
