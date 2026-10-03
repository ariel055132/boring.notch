import CoreLocation
import MapKit

enum WeatherLocationAuthorization { case notDetermined, allowed, denied }

@MainActor
protocol WeatherLocationProviding: AnyObject {
    var authorization: WeatherLocationAuthorization { get }
    func locate() async throws -> WeatherCoordinate
    func placeName(for coordinate: WeatherCoordinate) async -> String?
}

@MainActor
final class WeatherLocationService: NSObject, WeatherLocationProviding, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<WeatherCoordinate, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isRequestingLocation = false

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
    }

    isolated deinit {
        timeoutTask?.cancel()
        manager.stopUpdatingLocation()
        continuation?.resume(throwing: CancellationError())
    }

    var authorization: WeatherLocationAuthorization {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func locate() async throws -> WeatherCoordinate {
        guard continuation == nil else { throw WeatherFailure.locationUnavailable }
        guard CLLocationManager.locationServicesEnabled() else { throw WeatherFailure.locationUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch authorization {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .allowed: requestLocation()
            case .denied: finish(.failure(WeatherFailure.locationDenied))
            }
        }
    }

    private func requestLocation() {
        guard continuation != nil, !isRequestingLocation else { return }
        isRequestingLocation = true
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.finish(.failure(WeatherFailure.locationTimedOut))
        }
        manager.requestLocation()
    }

    private func finish(_ result: Result<WeatherCoordinate, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        isRequestingLocation = false
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch authorization {
        case .allowed: requestLocation()
        case .denied: finish(.failure(WeatherFailure.locationDenied))
        case .notDetermined: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard continuation != nil,
              let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 120 }) else { return }
        let coordinate = WeatherCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        guard coordinate.isValid else { return }
        finish(.success(coordinate.approximate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .locationUnknown { return }
        finish(.failure(authorization == .denied ? WeatherFailure.locationDenied : WeatherFailure.locationUnavailable))
    }

    func placeName(for coordinate: WeatherCoordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            return item.addressRepresentations?.cityName ?? item.addressRepresentations?.regionName
        } else {
            guard let place = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            return place.locality ?? place.subAdministrativeArea ?? place.administrativeArea
        }
    }
}
