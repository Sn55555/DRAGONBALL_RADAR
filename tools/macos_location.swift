import CoreLocation
import Foundation

final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var didFinish = false
    private let outputPath: String?

    init(outputPath: String?) {
        self.outputPath = outputPath

        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let age = -location.timestamp.timeIntervalSinceNow
        guard location.horizontalAccuracy >= 0, age <= 180 else { return }
        writeResult(String(
            format: "LOCATION_OK lat=%.8f lon=%.8f hacc=%.1f age=%.1f",
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.horizontalAccuracy,
            age
        ))
        finish()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        writeResult("LOCATION_ERROR \(error)")
        finish(exitCode: 2)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if #available(macOS 11.0, *) {
            let status = manager.authorizationStatus
            if status == .denied || status == .restricted {
                writeResult("LOCATION_DENIED status=\(status.rawValue)")
                finish(exitCode: 3)
            }
        }
    }

    func writeResult(_ result: String) {
        print(result)
        guard let outputPath else { return }
        try? result.appending("\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    private func finish(exitCode: Int32 = 0) {
        guard !didFinish else { return }
        didFinish = true
        manager.stopUpdatingLocation()
        DispatchQueue.main.async {
            exit(exitCode)
        }
    }
}

let outputPath = CommandLine.arguments.dropFirst().first
let delegate = LocationDelegate(outputPath: outputPath)
delegate.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    delegate.writeResult("LOCATION_TIMEOUT")
    exit(4)
}

RunLoop.main.run()
