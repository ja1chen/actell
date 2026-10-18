// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CoreDeviceError: String, Error, LocalizedError {
    case interfaceUnavailable, interfaceAmbiguous, interfaceInvalid, interfaceScopeUnsupported
    case busy, timeout, disconnected, network, malformedReply, unavailableBackend
    public var errorDescription: String? { rawValue }
}
public enum DiagnosticCommand: Equatable, Sendable {
    case status, discoverIPv4, discoverIPv6, lockdownQueryType, probe(generation: UInt32, index: UInt8)
    public var wire: String {
        switch self {
        case .status: return "STATUS\n"
        case .discoverIPv4: return "DISCOVER4\n"
        case .discoverIPv6: return "DISCOVER6\n"
        case .lockdownQueryType: return "LOCKDOWN\n"
        case let .probe(generation, index): return "PROBE \(generation) \(index)\n"
        }
    }
}
public struct DiagnosticReply: Decodable, Sendable {
    public struct Endpoint: Decodable, Identifiable, Sendable {
        public let index: UInt8
        public let service: String
        public let family: Int
        public let port: UInt16
        public var id: UInt8 { index }
    }
    public let layer: String
    public let result: String
    public let generation: UInt32?
    public let endpoints: [Endpoint]?
    public let osError: Int?
    public let tcpConnected: Bool?
    public let wireVersion: UInt32?
    public let authenticated: Bool
    public let screenCaptured: Bool?
    public let inputExecuted: Bool?
    private let protocolVersion: String
    enum CodingKeys: String, CodingKey {
        case layer, result, generation, endpoints, osError, tcpConnected, wireVersion, authenticated, screenCaptured, inputExecuted
        case protocolVersion = "protocol"
    }
    /// Only consumes diagnostic metadata. A diagnostic peer can never grant developer capabilities.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096, data.last == 10, data.dropLast().firstIndex(of: 10) == nil else { throw CoreDeviceError.malformedReply }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw CoreDeviceError.malformedReply }
        let layers = ["ncm", "discovery", "tcp", "greeting", "lockdown-querytype", "command", "pairing", "authentication"]
        let results = ["diagnostic-only", "backend-not-implemented", "candidates", "no-candidates", "unsupported", "stale-candidate", "authorization-required", "ok", "argument", "io", "eof", "timeout", "limit", "format", "type", "not_found"]
        guard value.protocolVersion == "ND1", layers.contains(value.layer), results.contains(value.result), !value.authenticated,
              value.screenCaptured != true, value.inputExecuted != true else { throw CoreDeviceError.malformedReply }
        if let endpoints = value.endpoints {
            guard value.layer == "discovery", let generation = value.generation, generation > 0, endpoints.count <= 16,
                  Set(endpoints.map(\.index)).count == endpoints.count,
                  endpoints.allSatisfy({ $0.index < 16 && [4,6].contains($0.family) && $0.port > 0 && ["remotepairing","lockdown","pairable-host"].contains($0.service) }) else { throw CoreDeviceError.malformedReply }
        }
        return value
    }
}

/// Deliberately separate from diagnostic results. Implementations must own an
/// authenticated generation, negotiated IPv6/RSD endpoint, DDI checks, and media.
/// NativeDeveloperServices links the real backend; no device access happens until
/// explicitly connected with an authorized identity and permissions.
@MainActor public protocol DeveloperServices {
    func listServices() async throws -> [String]
    func capturePNG() async throws -> Data
    /// Must hold an authenticated DisplayService media session; never USB HID.
    /// A transport ACK alone must not be reported as visible input success.
    func tap(x: UInt16, y: UInt16) async throws
}
@MainActor public struct UnavailableDeveloperServices: DeveloperServices {
    public init() {}
    public func listServices() async throws -> [String] { throw CoreDeviceError.unavailableBackend }
    public func capturePNG() async throws -> Data { throw CoreDeviceError.unavailableBackend }
    public func tap(x: UInt16, y: UInt16) async throws { throw CoreDeviceError.unavailableBackend }
}
