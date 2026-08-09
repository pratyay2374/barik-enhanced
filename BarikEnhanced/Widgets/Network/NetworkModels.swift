import CoreWLAN
import Foundation

/// A nearby Wi‑Fi network discovered via `CWInterface.scanForNetworks`, plus the
/// small amount of derived UI state (signal bars, security label) rows need.
struct WiFiNetwork: Identifiable, Equatable {
    var id: String { ssid }

    let ssid: String
    let rssi: Int
    let security: CWSecurity
    /// True when this row represents the network the interface is currently
    /// associated with (used to pin/mark it inside the "Other Networks" list
    /// if it ever needs to be shown there — the primary UI instead surfaces
    /// the current network in its own section).
    let isCurrent: Bool
    /// True when this SSID is already in the system's preferred-networks list
    /// (i.e. macOS already has a password for it in the keychain — the same
    /// thing the native Wi‑Fi menu calls a "Known Network"). Selecting a known
    /// network re-joins silently instead of asking for a password again.
    let isKnown: Bool

    var isSecured: Bool {
        security != .none
    }

    /// 0...4 bars, matching the native macOS Wi‑Fi glyph steps.
    var signalBars: Int {
        WiFiNetwork.signalBars(forRSSI: rssi)
    }

    static func signalBars(forRSSI rssi: Int) -> Int {
        switch rssi {
        case ..<(-80): return 1
        case ..<(-70): return 2
        case ..<(-60): return 3
        default: return 4
        }
    }

    /// Short label for the security type, e.g. "WPA2", "WPA3", "Open".
    /// Mirrors the wording used by the native Wi‑Fi menu.
    var securityLabel: String {
        WiFiNetwork.securityLabel(for: security)
    }

    static func securityLabel(for security: CWSecurity) -> String {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal, .personal: return "WPA2"
        case .wpa3Personal: return "WPA3"
        case .wpa3Transition: return "WPA3"
        case .dynamicWEP: return "WEP"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE, .oweTransition: return "Enhanced Open"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    /// Longer label for the network-details screen, e.g. "WPA2 Personal".
    static func detailedSecurityLabel(for security: CWSecurity) -> String {
        switch security {
        case .none: return "None"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        case .OWE: return "Enhanced Open"
        case .oweTransition: return "Enhanced Open Transition"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

/// State of the "Other Networks" list. Kept separate from `isRefreshing` so a
/// background re-scan never has to clear (and re-populate) an already-loaded
/// list — avoids the UI "jumping" while the popup is open.
enum NetworkListState: Equatable {
    case idle
    case scanning
    case loaded
    case empty
    case error(String)
}

/// Outcome of a join attempt, surfaced inline in the popup rather than via a
/// system alert.
enum WifiJoinState: Equatable {
    case idle
    case connecting(ssid: String)
    case success(ssid: String)
    case failed(ssid: String, reason: JoinFailureReason)
    /// A silent rejoin attempt for an already-known network didn't stick
    /// (saved password changed on the router, network forgotten on macOS's
    /// side, etc.) — the UI should fall back to asking for a password rather
    /// than reporting an opaque failure.
    case needsPassword(ssid: String)
}

enum JoinFailureReason: Equatable {
    case incorrectPassword
    case unavailable
    case timeout
    case unknown

    var message: String {
        switch self {
        case .incorrectPassword: return "The password may be incorrect."
        case .unavailable: return "This network is no longer available."
        case .timeout: return "Connection timed out."
        case .unknown: return "Something went wrong."
        }
    }
}
