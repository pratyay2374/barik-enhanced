import CoreLocation
import CoreWLAN
import Network
import SwiftUI

enum NetworkState: String {
    case connected = "Connected"
    case connectedWithoutInternet = "No Internet"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case disabled = "Disabled"
    case notSupported = "Not Supported"
}

enum WifiSignalStrength: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case unknown = "Unknown"
}

/// Unified view model for monitoring network and Wi‑Fi status.
final class NetworkStatusViewModel: NSObject, ObservableObject,
    CLLocationManagerDelegate
{
    static let shared = NetworkStatusViewModel()

    // States for Wi‑Fi and Ethernet obtained via NWPathMonitor.
    @Published var wifiState: NetworkState = .disconnected
    @Published var ethernetState: NetworkState = .disconnected

    // Wi‑Fi details obtained via CoreWLAN.
    @Published var ssid: String = "Not connected"
    @Published var rssi: Int = 0
    @Published var noise: Int = 0
    @Published var channel: String = "N/A"

    /// Computed property for signal strength.
    var wifiSignalStrength: WifiSignalStrength {
        // If Wi‑Fi is not connected or the interface is missing – return unknown.
        if ssid == "Not connected" || ssid == "No interface" {
            return .unknown
        }
        if rssi >= -50 {
            return .high
        } else if rssi >= -70 {
            return .medium
        } else {
            return .low
        }
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    private var timer: Timer?
    private let locationManager = CLLocationManager()

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        startNetworkMonitoring()
        startWiFiMonitoring()
    }

    deinit {
        stopNetworkMonitoring()
        stopWiFiMonitoring()
    }

    // MARK: — NWPathMonitor for overall network status.

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // Wi‑Fi
                if path.availableInterfaces.contains(where: { $0.type == .wifi }
                ) {
                    if path.usesInterfaceType(.wifi) {
                        switch path.status {
                        case .satisfied:
                            self.wifiState = .connected
                        case .requiresConnection:
                            self.wifiState = .connecting
                        default:
                            self.wifiState = .connectedWithoutInternet
                        }
                    } else {
                        // If the Wi‑Fi interface is available but not in use – consider it enabled but not connected.
                        self.wifiState = .disconnected
                    }
                } else {
                    self.wifiState = .notSupported
                }

                // Ethernet
                if path.availableInterfaces.contains(where: {
                    $0.type == .wiredEthernet
                }) {
                    if path.usesInterfaceType(.wiredEthernet) {
                        switch path.status {
                        case .satisfied:
                            self.ethernetState = .connected
                        case .requiresConnection:
                            self.ethernetState = .connecting
                        default:
                            self.ethernetState = .disconnected
                        }
                    } else {
                        self.ethernetState = .disconnected
                    }
                } else {
                    self.ethernetState = .notSupported
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func stopNetworkMonitoring() {
        monitor.cancel()
    }

    // MARK: — Updating Wi‑Fi information via CoreWLAN.

    private func startWiFiMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) {
            [weak self] _ in
            self?.updateWiFiInfo()
        }
        updateWiFiInfo()
    }

    private func stopWiFiMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Snapshot of the Wi‑Fi fields we publish, so the CoreWLAN reads and the
    /// `@Published` writes can happen on different threads.
    private struct WiFiInfo {
        let ssid: String
        let rssi: Int
        let noise: Int
        let channel: String

        /// Wi‑Fi off / no interface.
        static let unavailable = WiFiInfo(
            ssid: "No interface", rssi: 0, noise: 0, channel: "N/A")
    }

    /// Reads the current Wi‑Fi state off the main thread and publishes on it.
    ///
    /// `CWWiFiClient` accessors are IPC to `airportd`; running them inline on the
    /// main thread stalls it for the duration of the round-trip on every tick.
    private func updateWiFiInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = Self.readWiFiInfo()
            DispatchQueue.main.async {
                self?.applyWiFiInfo(info)
            }
        }
    }

    private static func readWiFiInfo() -> WiFiInfo {
        guard let interface = CWWiFiClient.shared().interface() else {
            return .unavailable
        }
        let channel: String
        if let wlanChannel = interface.wlanChannel() {
            let band: String
            switch wlanChannel.channelBand {
            case .bandUnknown:
                band = "unknown"
            case .band2GHz:
                band = "2GHz"
            case .band5GHz:
                band = "5GHz"
            case .band6GHz:
                band = "6GHz"
            @unknown default:
                band = "unknown"
            }
            channel = "\(wlanChannel.channelNumber) (\(band))"
        } else {
            channel = "N/A"
        }
        return WiFiInfo(
            ssid: interface.ssid() ?? "Not connected",
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: channel
        )
    }

    private func applyWiFiInfo(_ info: WiFiInfo) {
        // Only update if changed to avoid unnecessary SwiftUI redraws
        if info.ssid != ssid { ssid = info.ssid }
        if info.rssi != rssi { rssi = info.rssi }
        if info.noise != noise { noise = info.noise }
        if info.channel != channel { channel = info.channel }
    }

    // MARK: — CLLocationManagerDelegate.

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        updateWiFiInfo()
    }
}
