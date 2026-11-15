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
}
