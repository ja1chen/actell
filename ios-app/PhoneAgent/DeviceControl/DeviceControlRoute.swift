// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted developer route; active bridges retain the shared connection and
/// prevent route changes until their run has released it.
enum DeviceControlRoute: String, Sendable {
    case vpnLoopback = "localDevVPN"
    case ncmDeveloper
    case localCaptureUSB
    static let defaultsKey = "deviceControlRoute"
    static var current: Self { load(from: .standard) }
    static func load(from defaults: UserDefaults) -> Self {
        // Retained capture route is not exposed by this setting.
        defaults.string(forKey: defaultsKey) == Self.ncmDeveloper.rawValue ? .ncmDeveloper : .vpnLoopback
    }
    var title: String { self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32 NCM" }
    var connectionName: String { self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32" }
    var controlTitle: String { self == .vpnLoopback ? String(localized: "VPN loopback control") : String(localized: "ESP32 control") }
    var modelContext: String {
        switch self {
        case .ncmDeveloper:
            return "Screenshots and touch input use the authenticated ESP32 NCM developer connection. Background execution needs an active execution source. Device tools wait for a paired connection internally; reconnecting invalidates old frames and action grants, while read tools can bind the new session."
        case .vpnLoopback:
            return "Screenshots and touch input use authenticated CoreDevice services through a local VPN loopback on this phone, without ESP32. A compatible packet-reflection VPN must already be enabled with the configured interface and peer addresses. Device tools verify the paired connection internally; reconnecting invalidates old frames and action grants. Follow actual readiness errors."
        case .localCaptureUSB:
            return "Screenshots use this App's authorized ScreenCaptureKit capture, independently of USB. Touch input uses the retained USB HID route. Follow the tools' actual foreground/background capabilities."
        }
    }
}
