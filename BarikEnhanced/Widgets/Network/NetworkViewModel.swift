import CoreLocation
import CoreWLAN
import Darwin
import Foundation
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

/// Unified view model for monitoring network and Wi‑Fi status, plus the
/// nearby-network scan/join/power actions the redesigned widget adds.
///
/// Two independent activity levels:
/// - The lightweight "current connection" monitor (`NWPathMonitor` + a
///   periodic CoreWLAN detail read) mirrors the old behaviour and is gated by
///   `ConditionallyActivatableWidget`, exactly like `BatteryManager` — it only
///   runs while the widget is actually displayed in the bar.
/// - Nearby-network scanning is heavier (a blocking CoreWLAN scan that can
///   take a couple of seconds) and is gated separately, by popup visibility:
///   it only runs while the popup is open, never in the background.
final class NetworkStatusViewModel: NSObject, ObservableObject,
    CLLocationManagerDelegate, ConditionallyActivatableWidget
{
    static let shared = NetworkStatusViewModel()

    let widgetId = "default.network"

    // States for Wi‑Fi and Ethernet obtained via NWPathMonitor.
    @Published var wifiState: NetworkState = .disconnected
    @Published var ethernetState: NetworkState = .disconnected

    // Wi‑Fi details for the currently associated network, obtained via CoreWLAN.
    @Published var ssid: String = "Not connected"
    @Published var rssi: Int = 0
    @Published var noise: Int = 0
    @Published var channel: String = "N/A"
    @Published var currentSecurity: CWSecurity = .unknown
    @Published var ipAddress: String = "—"
    @Published var frequencyLabel: String = "—"
    @Published private(set) var isWifiPowered: Bool = true
    /// True as long as a Wi‑Fi interface exists at all — independent of
    /// `isWifiPowered`. Distinguishes "no Wi‑Fi hardware" from "Wi‑Fi is off",
    /// which look identical to `NWPathMonitor` but should render differently.
    @Published private(set) var hasWifiHardware: Bool = true

    // Nearby networks ("Other Networks" list).
    @Published var availableNetworks: [WiFiNetwork] = []
    @Published var listState: NetworkListState = .idle
    @Published var isRefreshingList: Bool = false
    /// SSIDs already in the system's preferred-networks list, i.e. macOS has
    /// a password saved for them. Backs `WiFiNetwork.isKnown`, unioned with
    /// `appRememberedSSIDs` below.
    @Published private(set) var knownNetworkSSIDs: Set<String> = []
    /// SSIDs this app has itself successfully joined with "remember" checked.
    /// Some networks — notably an iPhone's Personal Hotspot, which macOS
    /// treats as a Continuity/Instant-Hotspot session rather than a normal
    /// remembered router — never show up in `networksetup
    /// -listpreferredwirelessnetworks` even though the password *is* saved
    /// to the keychain. Tracking this ourselves means "should we try a
    /// silent rejoin" no longer depends entirely on that system list.
    @Published private(set) var appRememberedSSIDs: Set<String>
    private static let rememberedSSIDsDefaultsKey = "NetworkWidget.rememberedSSIDs"

    // Join-a-network flow.
    @Published var joinState: WifiJoinState = .idle

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

    var signalBars: Int { WiFiNetwork.signalBars(forRSSI: rssi) }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    /// Serializes CoreWLAN reads and `networksetup` invocations off the main
    /// thread — both are IPC/process calls that must never block the UI.
    private let actionQueue = DispatchQueue(label: "NetworkActions", qos: .utility)

    private var timer: Timer?
    private var currentInterval: TimeInterval = 15.0
    private let locationManager = CLLocationManager()
    private var isActive = false

    /// Bumped every time a scan is kicked off; async scan results are dropped
    /// if the generation has moved on (popup closed/reopened quickly) so a
    /// stale scan can never clobber fresher state.
    private var scanGeneration = 0

    private override init() {
        let remembered = UserDefaults.standard.stringArray(forKey: Self.rememberedSSIDsDefaultsKey) ?? []
        appRememberedSSIDs = Set(remembered)
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        setupNotifications()
        // For now, always activate to ensure the widget works; deactivated
        // below if it turns out not to be displayed.
        activate()
    }

    private func rememberJoinedNetwork(_ ssid: String) {
        guard !appRememberedSSIDs.contains(ssid) else { return }
        appRememberedSSIDs.insert(ssid)
        UserDefaults.standard.set(Array(appRememberedSSIDs), forKey: Self.rememberedSSIDsDefaultsKey)
    }

    private func forgetRememberedNetwork(_ ssid: String) {
        guard appRememberedSSIDs.remove(ssid) != nil else { return }
        UserDefaults.standard.set(Array(appRememberedSSIDs), forKey: Self.rememberedSSIDsDefaultsKey)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        deactivate()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PerformanceModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let intervals = notification.object as? [String: TimeInterval],
               let newInterval = intervals["network"] {
                self?.updateTimerInterval(newInterval)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("WidgetActivationChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let activeWidgets = notification.object as? Set<String> {
                if activeWidgets.contains(self.widgetId) {
                    self.activate()
                } else {
                    self.deactivate()
                }
            }
        }
    }

    // MARK: — ConditionallyActivatableWidget

    func activate() {
        guard !isActive else { return }
        isActive = true

        let performanceManager = PerformanceModeManager.shared
        let intervals = performanceManager.getTimerIntervals(for: performanceManager.currentMode)
        currentInterval = intervals["network"] ?? 15.0

        startNetworkMonitoring()
        startWiFiMonitoring()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopNetworkMonitoring()
        stopWiFiMonitoring()
    }

    private func updateTimerInterval(_ newInterval: TimeInterval) {
        guard isActive else { return }
        currentInterval = newInterval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) {
            [weak self] _ in
            self?.updateWiFiInfo()
        }
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
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) {
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
        let security: CWSecurity
        let frequencyLabel: String
        let ipAddress: String
        let powered: Bool
        /// False only when there's no Wi‑Fi interface at all — distinct from
        /// `powered`, which is false when the hardware exists but is off.
        let hasHardware: Bool

        /// No Wi‑Fi interface present on this Mac at all.
        static let unavailable = WiFiInfo(
            ssid: "No interface", rssi: 0, noise: 0, channel: "N/A",
            security: .unknown, frequencyLabel: "—", ipAddress: "—", powered: false, hasHardware: false)
    }

    /// Reads the current Wi‑Fi state off the main thread and publishes on it.
    ///
    /// `CWWiFiClient` accessors are IPC to `airportd`; running them inline on the
    /// main thread stalls it for the duration of the round-trip on every tick.
    private func updateWiFiInfo() {
        actionQueue.async { [weak self] in
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
        guard interface.powerOn() else {
            return WiFiInfo(
                ssid: "No interface", rssi: 0, noise: 0, channel: "N/A",
                security: .unknown, frequencyLabel: "—", ipAddress: "—", powered: false, hasHardware: true)
        }

        let (channelText, frequencyText) = describeChannel(interface.wlanChannel())
        let ipAddress = currentIPv4Address(interfaceName: interface.interfaceName) ?? "—"

        return WiFiInfo(
            ssid: interface.ssid() ?? "Not connected",
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: channelText,
            security: interface.security(),
            frequencyLabel: frequencyText,
            ipAddress: ipAddress,
            powered: true,
            hasHardware: true
        )
    }

    private static func describeChannel(_ wlanChannel: CWChannel?) -> (channel: String, frequency: String) {
        guard let wlanChannel else { return ("N/A", "—") }
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
        let frequency: String
        switch wlanChannel.channelBand {
        case .band2GHz: frequency = "2.4 GHz"
        case .band5GHz: frequency = "5 GHz"
        case .band6GHz: frequency = "6 GHz"
        default: frequency = "—"
        }
        return ("\(wlanChannel.channelNumber) (\(band))", frequency)
    }

    private func applyWiFiInfo(_ info: WiFiInfo) {
        // Only update if changed to avoid unnecessary SwiftUI redraws
        if info.ssid != ssid { ssid = info.ssid }
        if info.rssi != rssi { rssi = info.rssi }
        if info.noise != noise { noise = info.noise }
        if info.channel != channel { channel = info.channel }
        if info.security != currentSecurity { currentSecurity = info.security }
        if info.frequencyLabel != frequencyLabel { frequencyLabel = info.frequencyLabel }
        if info.ipAddress != ipAddress { ipAddress = info.ipAddress }
        if info.powered != isWifiPowered { isWifiPowered = info.powered }
        if info.hasHardware != hasWifiHardware { hasWifiHardware = info.hasHardware }
    }

    // MARK: — IPv4 lookup

    private static func currentIPv4Address(interfaceName: String?) -> String? {
        guard let interfaceName else { return nil }
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            let entry = current.pointee
            let name = String(cString: entry.ifa_name)
            if name == interfaceName, let socketAddress = entry.ifa_addr,
                socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            {
                var addr = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer)
            }
            pointer = entry.ifa_next
        }
        return nil
    }

    // MARK: — Popup lifecycle (drives nearby-network scanning)

    /// Called when the popup appears. Scans immediately — scanning otherwise
    /// never runs in the background, per the "avoid excessive continuous
    /// scanning" requirement.
    func popupDidAppear() {
        updateWiFiInfo()
        if isWifiPowered {
            refreshNetworks()
        }
    }

    /// Called when the popup disappears. Invalidates any in-flight scan so
    /// its result is dropped instead of updating state nobody can see.
    func popupDidDisappear() {
        scanGeneration += 1
        joinState = .idle
    }

    // MARK: — Nearby network scanning

    func refreshNetworks() {
        guard isWifiPowered else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isRefreshingList = true
        if availableNetworks.isEmpty {
            listState = .scanning
        }
        // Snapshot on the main thread — read from the background scan closure
        // below instead of touching the live `@Published` set off-thread.
        let appRemembered = appRememberedSSIDs

        actionQueue.async { [weak self] in
            guard let self else { return }
            guard let interface = CWWiFiClient.shared().interface() else {
                self.finishScan(generation: generation, result: .failure(NSError(domain: "Network", code: -1)), known: [])
                return
            }
            let knownSSIDs = (interface.interfaceName.map(Self.fetchKnownNetworks) ?? []).union(appRemembered)
            do {
                let results = try interface.scanForNetworks(withSSID: nil)
                let currentSSID = interface.ssid()
                var bestBySSID: [String: WiFiNetwork] = [:]
                for network in results {
                    guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                    if ssid == currentSSID { continue }
                    let security = Self.strongestSupportedSecurity(network)
                    let candidate = WiFiNetwork(
                        ssid: ssid, rssi: network.rssiValue, security: security, isCurrent: false,
                        isKnown: knownSSIDs.contains(ssid))
                    if let existing = bestBySSID[ssid], existing.rssi >= candidate.rssi {
                        continue
                    }
                    bestBySSID[ssid] = candidate
                }
                let sorted = bestBySSID.values.sorted { $0.rssi > $1.rssi }
                self.finishScan(generation: generation, result: .success(sorted), known: knownSSIDs)
            } catch {
                self.finishScan(generation: generation, result: .failure(error), known: knownSSIDs)
            }
        }
    }

    private func finishScan(generation: Int, result: Result<[WiFiNetwork], Error>, known: Set<String>) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.scanGeneration else { return }
            self.isRefreshingList = false
            self.knownNetworkSSIDs = known
            switch result {
            case .success(let networks):
                self.availableNetworks = networks
                self.listState = networks.isEmpty ? .empty : .loaded
            case .failure:
                // Keep whatever is already on screen — don't let a transient
                // scan failure blank out a perfectly good, if stale, list.
                if self.availableNetworks.isEmpty {
                    self.listState = .error("Unable to scan for networks.")
                }
            }
        }
    }

    /// Parses `networksetup -listpreferredwirelessnetworks <device>` — one
    /// SSID per line, after a header line naming the device.
    private static func fetchKnownNetworks(device: String) -> Set<String> {
        let output = runNetworksetup(["-listpreferredwirelessnetworks", device])
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Drop the "Preferred networks on <device>:" header line.
        return Set(lines.dropFirst().filter { !$0.isEmpty })
    }

    /// Networks only expose which security types they *support*, not a single
    /// definitive type — pick the strongest one so the row shows the type a
    /// user would actually authenticate with.
    private static func strongestSupportedSecurity(_ network: CWNetwork) -> CWSecurity {
        let priority: [CWSecurity] = [
            .wpa3Enterprise, .wpa3Personal, .wpa3Transition,
            .wpa2Enterprise, .enterprise, .wpa2Personal, .personal,
            .wpaEnterpriseMixed, .wpaEnterprise,
            .wpaPersonalMixed, .wpaPersonal,
            .dynamicWEP, .WEP,
            .OWE, .oweTransition,
        ]
        for security in priority where network.supportsSecurity(security) {
            return security
        }
        return .none
    }

    // MARK: — Wi‑Fi power

    func setWifiPower(_ on: Bool) {
        // Optimistic UI update — networksetup can take a moment.
        isWifiPowered = on
        if !on {
            availableNetworks = []
            listState = .idle
        }

        actionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = CWWiFiClient.shared().interface()?.interfaceName else { return }
            _ = Self.runNetworksetup(["-setairportpower", device, on ? "on" : "off"])
            // Give the driver a moment to settle, then reconcile with reality.
            Thread.sleep(forTimeInterval: 1.0)
            let info = Self.readWiFiInfo()
            DispatchQueue.main.async {
                self.applyWiFiInfo(info)
                if on && info.powered {
                    self.refreshNetworks()
                }
            }
        }
    }

    // MARK: — Join / forget a network

    func join(network: WiFiNetwork, password: String?, remember: Bool) {
        joinState = .connecting(ssid: network.ssid)

        actionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = CWWiFiClient.shared().interface()?.interfaceName else {
                self.finishJoin(ssid: network.ssid, outcome: .failed(ssid: network.ssid, reason: .unknown), remember: remember)
                return
            }

            var arguments = ["-setairportnetwork", device, network.ssid]
            if let password, !password.isEmpty {
                arguments.append(password)
            }
            let output = Self.runNetworksetup(arguments)

            // `networksetup` returns exit code 0 even when it fails outright
            // (e.g. an unreachable SSID) — the only reliable signal is
            // polling actual association state afterwards.
            var joinedSSID: String?
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.8)
                joinedSSID = CWWiFiClient.shared().interface()?.ssid()
                if joinedSSID == network.ssid { break }
            }

            if joinedSSID == network.ssid {
                if !remember, password != nil {
                    _ = Self.runNetworksetup(["-removepreferredwirelessnetwork", device, network.ssid])
                }
                self.finishJoin(ssid: network.ssid, outcome: .success(ssid: network.ssid), remember: remember)
            } else if password == nil && network.isSecured {
                // Silent rejoin of an already-known network didn't stick (saved
                // password stale, router changed, etc.) — ask for it instead of
                // reporting an opaque failure.
                self.finishJoin(ssid: network.ssid, outcome: .needsPassword(ssid: network.ssid), remember: remember)
            } else {
                let reason: JoinFailureReason
                if output.localizedCaseInsensitiveContains("could not find network") {
                    reason = .unavailable
                } else if password != nil {
                    reason = .incorrectPassword
                } else {
                    reason = .unavailable
                }
                self.finishJoin(ssid: network.ssid, outcome: .failed(ssid: network.ssid, reason: reason), remember: remember)
            }
        }
    }

    private func finishJoin(ssid: String, outcome: WifiJoinState, remember: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.joinState = outcome
            if case .success = outcome {
                // Track this ourselves regardless of whether `networksetup`
                // also lists it as a "preferred network" — some network types
                // (Personal Hotspot) never show up there even though the
                // password is genuinely saved to the keychain.
                if remember {
                    self.rememberJoinedNetwork(ssid)
                } else {
                    self.forgetRememberedNetwork(ssid)
                }
                self.updateWiFiInfo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.refreshNetworks()
                }
            }
        }
    }

    func dismissJoinResult() {
        joinState = .idle
    }

    func forget(ssid: String) {
        forgetRememberedNetwork(ssid)
        actionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = CWWiFiClient.shared().interface()?.interfaceName else { return }
            _ = Self.runNetworksetup(["-removepreferredwirelessnetwork", device, ssid])
            self.updateWiFiInfo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refreshNetworks()
            }
        }
    }

    @discardableResult
    private static func runNetworksetup(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Error launching networksetup: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: — Settings shortcut

    func openSystemWifiSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: — CLLocationManagerDelegate.

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        updateWiFiInfo()
    }
}
