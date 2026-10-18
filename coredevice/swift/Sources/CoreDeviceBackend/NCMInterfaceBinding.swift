// SPDX-License-Identifier: GPL-3.0-or-later
// Selects the concrete USB network interface independently of HID.
import Foundation
import Network
import Darwin

struct NCMInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    let row: NetworkInterfaces.Row
    let interface: NWInterface
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address

    static func select(_ rows: [NetworkInterfaces.Row]) throws -> NetworkInterfaces.Row {
        let matches = rows.filter { $0.address == localIP }
        guard matches.count == 1, let row = matches.first else {
            throw matches.isEmpty ? CoreDeviceError.interfaceUnavailable : CoreDeviceError.interfaceAmbiguous
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw CoreDeviceError.interfaceInvalid
        }
        return row
    }
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw CoreDeviceError.interfaceInvalid
        }
    }
    static func resolve(_ rows: [NetworkInterfaces.Row]) throws -> NCMInterfaceBinding {
        let row = try select(rows)
        // Compatibility workaround: IPv4 %scope parsing is not
        // explicitly guaranteed by Apple documentation. Validate it and fail closed.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw CoreDeviceError.interfaceInvalid
        }
        try validateType(interface.type)
        return NCMInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
}
