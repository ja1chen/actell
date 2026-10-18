// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum LocalVPNError: Error, Equatable {
    case inactive, ambiguousInterface, serviceNotFound, ambiguousService, discoveryDenied, invalidConfiguration
}

/// Addresses belong to the externally configured packet-reflection VPN.
public struct VPNLoopbackConfiguration: Equatable, Sendable {
    public let localAddress: String
    public let peerAddress: String
    let localIPv4: UInt32
    let peerIPv4: UInt32
    public static let defaults = try! Self(localAddress: "10.7.1.1", peerAddress: "10.7.0.1")
    public init(localAddress: String, peerAddress: String) throws {
        func parse(_ input: String) throws -> (String, UInt32) {
            let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw LocalVPNError.invalidConfiguration }
            let octets = try parts.map { part -> UInt8 in
                guard let value = UInt8(part), String(value) == part else { throw LocalVPNError.invalidConfiguration }
                return value
            }
            guard octets[0] != 0, octets[0] != 127, octets[0] < 224 else { throw LocalVPNError.invalidConfiguration }
            return (address, octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        let local = try parse(localAddress), peer = try parse(peerAddress)
        guard local.1 != peer.1 else { throw LocalVPNError.invalidConfiguration }
        self.localAddress = local.0; self.peerAddress = peer.0
        self.localIPv4 = local.1; self.peerIPv4 = peer.1
    }
}

/// Discovery identifies this phone by its own addresses; authentication still pins
/// the stored peer key. A nearby phone's Bonjour port is never a candidate.
@MainActor public final class LocalVPNDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var requestID: UUID?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var ports: [ObjectIdentifier: UInt16] = [:]
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var timeout: Task<Void, Never>?
    public override init() { super.init() }

    static func selectInterface(_ rows: [NetworkInterfaces.Row], configuration: VPNLoopbackConfiguration = .defaults) throws -> NetworkInterfaces.Row {
        let matches = rows.filter { $0.name.hasPrefix("utun") && $0.address == configuration.localAddress }
        guard matches.count == 1, let row = matches.first else {
            throw matches.isEmpty ? LocalVPNError.inactive : LocalVPNError.ambiguousInterface
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)
        guard row.index > 0, row.flags & required == required, row.flags & UInt32(IFF_LOOPBACK) == 0 else { throw LocalVPNError.inactive }
        return row
    }
    static func selectPort(_ ports: [UInt16]) throws -> UInt16 {
        let unique = Set(ports.filter { $0 != 0 })
        guard unique.count == 1, let port = unique.first else {
            throw unique.isEmpty ? LocalVPNError.serviceNotFound : LocalVPNError.ambiguousService
        }
        return port
    }
    public func discoverPort(configuration: VPNLoopbackConfiguration = .defaults) async throws -> UInt16 {
        try Task.checkCancellation()
        _ = try Self.selectInterface(NetworkInterfaces.inventory(), configuration: configuration)
        guard continuation == nil else { throw NativeBackendError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.requestID = id
                self.continuation = continuation
                let browser = NetServiceBrowser(); self.browser = browser
                browser.delegate = self
                browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self, requestID == id else { return }
                    finish(Result { try Self.selectPort(Array(self.ports.values)) })
                }
            }
        } onCancel: { Task { @MainActor in if self.requestID == id { self.cancel() } } }
    }
    public func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<UInt16, Error>) {
        let pending = continuation; continuation = nil; requestID = nil
        timeout?.cancel(); timeout = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services { service.delegate = nil; service.stop() }
        services.removeAll(); ports.removeAll()
        pending?.resume(with: result)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser, services.count < 64 else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 3)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        let removed = services.filter { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
        for item in removed { ports.removeValue(forKey: ObjectIdentifier(item)); item.delegate = nil; item.stop() }
        services.removeAll { removed.contains($0) }
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }; finish(.failure(LocalVPNError.discoveryDenied))
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }), (1...65535).contains(sender.port) else { return }
        let own = Self.ownAddresses()
        let local = (sender.addresses ?? []).contains { data in
            data.withUnsafeBytes { bytes in
                guard bytes.count >= MemoryLayout<sockaddr>.size, let base = bytes.baseAddress else { return false }
                return Self.addressKey(base.assumingMemoryBound(to: sockaddr.self), size: bytes.count).map { own.contains($0) } ?? false
            }
        }
        if local { ports[ObjectIdentifier(sender)] = UInt16(sender.port) }
    }
    // Compare address bytes, excluding port and IPv6 scope, for all local interfaces.
    private static func addressKey(_ address: UnsafePointer<sockaddr>, size: Int) -> Data? {
        if address.pointee.sa_family == UInt8(AF_INET), size >= MemoryLayout<sockaddr_in>.size {
            var value = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in.self).sin_addr
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        if address.pointee.sa_family == UInt8(AF_INET6), size >= MemoryLayout<sockaddr_in6>.size {
            var value = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in6.self).sin6_addr
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        return nil
    }
    private static func ownAddresses() -> Set<Data> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var current = head, result: Set<Data> = []
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            if let address = entry.pointee.ifa_addr,
               let key = addressKey(UnsafePointer(address), size: Int(address.pointee.sa_len)) { result.insert(key) }
        }
        return result
    }
}
