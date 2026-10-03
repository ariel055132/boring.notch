import Foundation

protocol WeatherServiceProviding: Sendable {
    func forecast(for coordinate: WeatherCoordinate) async throws -> WeatherSnapshot
}

/// Open-Meteo's free endpoint is for non-commercial use. Attribution is in WeatherView.
struct OpenMeteoWeatherService: WeatherServiceProviding {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    static func requestURL(for coordinate: WeatherCoordinate) throws -> URL {
        guard coordinate.isValid else { throw WeatherFailure.locationUnavailable }
        let coordinate = coordinate.approximate
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        guard let result = url.url else { throw WeatherFailure.invalidResponse }
        return result
    }

    func forecast(for coordinate: WeatherCoordinate) async throws -> WeatherSnapshot {
        let request = URLRequest(url: try Self.requestURL(for: coordinate), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeatherFailure.network
        }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw WeatherFailure.serviceUnavailable
        }
        return try Self.decode(data, fetchedAt: Date())
    }

    static func decode(_ data: Data, fetchedAt: Date) throws -> WeatherSnapshot {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw WeatherFailure.invalidResponse }
        guard let temperature = response.current.temperature_2m, temperature.isFinite,
              let zone = TimeZone(identifier: response.timezone) else { throw WeatherFailure.invalidResponse }
        let hours = response.hourly
        let days = response.daily
        guard [hours.temperature_2m.count, hours.precipitation_probability.count, hours.weather_code.count, hours.is_day.count].allSatisfy({ $0 == hours.time.count }),
              [days.temperature_2m_max.count, days.temperature_2m_min.count, days.precipitation_probability_max.count, days.weather_code.count].allSatisfy({ $0 == days.time.count }) else {
            throw WeatherFailure.invalidResponse
        }
        let current = CurrentWeather(
            time: Date(timeIntervalSince1970: response.current.time), temperature: temperature,
            apparentTemperature: response.current.apparent_temperature,
            humidity: response.current.relative_humidity_2m, windSpeed: response.current.wind_speed_10m,
            condition: WeatherCondition(code: response.current.weather_code ?? -1, isDay: response.current.is_day != 0)
        )
        let startHour = floor(response.current.time / 3600) * 3600
        let hourly = hours.time.indices.compactMap { index -> HourlyWeather? in
            guard hours.time[index] >= startHour, hours.time[index] < startHour + 24 * 3600,
                  let temperature = hours.temperature_2m[index], temperature.isFinite else { return nil }
            return HourlyWeather(time: Date(timeIntervalSince1970: hours.time[index]), temperature: temperature,
                                 precipitationProbability: hours.precipitation_probability[index],
                                 condition: WeatherCondition(code: hours.weather_code[index] ?? -1, isDay: hours.is_day[index] != 0))
        }.sorted { $0.time < $1.time }
        let daily = days.time.indices.compactMap { index -> DailyWeather? in
            guard let high = days.temperature_2m_max[index], let low = days.temperature_2m_min[index], high.isFinite, low.isFinite else { return nil }
            return DailyWeather(date: Date(timeIntervalSince1970: days.time[index]), high: high, low: low,
                                precipitationProbability: days.precipitation_probability_max[index],
                                condition: WeatherCondition(code: days.weather_code[index] ?? -1))
        }.sorted { $0.date < $1.date }
        guard !hourly.isEmpty, !daily.isEmpty else { throw WeatherFailure.invalidResponse }
        return WeatherSnapshot(current: current, hourly: Array(hourly.prefix(24)), daily: Array(daily.prefix(7)), timeZone: zone, fetchedAt: fetchedAt)
    }

    private struct Response: Decodable {
        let timezone: String
        let current: Current
        let hourly: Hourly
        let daily: Daily

        struct Current: Decodable {
            let time: Double
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let wind_speed_10m: Double?
            let weather_code: Int?
            let is_day: Int?
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let precipitation_probability: [Double?]
            let weather_code: [Int?]
            let is_day: [Int?]
        }
        struct Daily: Decodable {
            let time: [Double]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Double?]
            let weather_code: [Int?]
        }
    }
}
