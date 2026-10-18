// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Network
import Darwin
@testable import CoreDeviceBackend

final class DiagnosticTests: XCTestCase {
    static let status = "{\"protocol\":\"ND1\",\"layer\":\"ncm\",\"result\":\"diagnostic-only\",\"authenticated\":false,\"screenCaptured\":false,\"inputExecuted\":false}\n"
    func testDiagnosticNeverGrantsCapabilities() throws {
        let reply = try DiagnosticReply.decode(Data(Self.status.utf8))
        XCTAssertFalse(reply.authenticated)
        for key in ["authenticated", "screenCaptured", "inputExecuted"] {
            XCTAssertThrowsError(try DiagnosticReply.decode(Data(Self.status.replacingOccurrences(of: "\"\(key)\":false", with: "\"\(key)\":true").utf8)))
        }
    }
    func testReplyBoundsAndSchema() throws {
        for invalid in [String(Self.status.dropLast()), Self.status + "\n", Self.status + Self.status,
                        Self.status.replacingOccurrences(of: "ND1", with: "PA3"), Self.status.replacingOccurrences(of: "diagnostic-only", with: "executed"), String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try DiagnosticReply.decode(Data(invalid.utf8)))
        }
        let json = "{\"protocol\":\"ND1\",\"layer\":\"discovery\",\"result\":\"candidates\",\"authenticated\":false,\"generation\":23,\"endpoints\":[{\"index\":0,\"service\":\"remotepairing\",\"family\":6,\"port\":54321}]}\n"
        XCTAssertEqual(try DiagnosticReply.decode(Data(json.utf8)).endpoints?.first?.port, 54321)
        for invalid in [json.replacingOccurrences(of: "54321", with: "0"), json.replacingOccurrences(of: "\"family\":6", with: "\"family\":8"), json.replacingOccurrences(of: "\"generation\":23", with: "\"generation\":0")] {
            XCTAssertThrowsError(try DiagnosticReply.decode(Data(invalid.utf8)))
        }
    }
    func testCommandsCannotEncodePairOrInput() {
        XCTAssertEqual(DiagnosticCommand.probe(generation: 12, index: 0).wire, "PROBE 12 0\n")
        XCTAssertEqual(DiagnosticCommand.lockdownQueryType.wire, "LOCKDOWN\n")
    }
    func testBindingRejectsAmbiguityAndVPN() throws {
        let good = NetworkInterfaces.Row(name: "test77", index: 77, address: "192.168.7.2", mask: "255.255.255.0", flags: UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST), linkType: UInt8(IFT_ETHER))
        XCTAssertEqual(try NCMInterfaceBinding.select([good]), good)
        XCTAssertThrowsError(try NCMInterfaceBinding.select([]))
        XCTAssertThrowsError(try NCMInterfaceBinding.select([good,good]))
        let vpn = NetworkInterfaces.Row(name: "utun77", index: 77, address: good.address, mask: good.mask, flags: good.flags | UInt32(IFF_POINTOPOINT), linkType: good.linkType)
        XCTAssertThrowsError(try NCMInterfaceBinding.select([vpn]))
        XCTAssertThrowsError(try NCMInterfaceBinding.validateType(.wifi))
        XCTAssertThrowsError(try NCMInterfaceBinding.validateType(.cellular))
    }
    @MainActor func testUnavailableBackendHasNoFakeSuccess() async {
        let backend = UnavailableDeveloperServices()
        do { _ = try await backend.listServices(); XCTFail() } catch { XCTAssertEqual(error as? CoreDeviceError, .unavailableBackend) }
        do { _ = try await backend.capturePNG(); XCTFail() } catch { XCTAssertEqual(error as? CoreDeviceError, .unavailableBackend) }
        do { try await backend.tap(x: 1, y: 2); XCTFail() } catch { XCTAssertEqual(error as? CoreDeviceError, .unavailableBackend) }
    }
}

@MainActor final class TransportTests: XCTestCase {
    private func peer(reply: Data?, chunks: Bool = false) async throws -> (NWListener, NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                if let reply {
                    if chunks {
                        connection.send(content: reply.prefix(7), completion: .contentProcessed { _ in
                            connection.send(content: reply.dropFirst(7), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                        })
                    } else {
                        connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else {
                    // Keep synthetic peer alive until client cancellation/timeout.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, _, _ in connection.cancel() }
                }
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        return (listener, port)
    }
    func testLoopbackFragmentedReply() async throws {
        let (listener, port) = try await peer(reply: Data(DiagnosticTests.status.utf8), chunks: true)
        defer { listener.cancel() }
        let client = NCMDiagnosticClient()
        let reply = try await client.exchange(.status, connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
        XCTAssertEqual(reply.result, "diagnostic-only")
    }
    func testLoopbackMalformedReply() async throws {
        let (listener, port) = try await peer(reply: Data("PA3 READY 1\n".utf8))
        defer { listener.cancel() }
        do { _ = try await NCMDiagnosticClient().exchange(.status, connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)); XCTFail() }
        catch { XCTAssertEqual(error as? CoreDeviceError, .malformedReply) }
    }
    func testTimeoutReleasesOwner() async throws {
        let (listener, port) = try await peer(reply: nil)
        defer { listener.cancel() }
        let client = NCMDiagnosticClient()
        for _ in 0..<2 {
            do { _ = try await client.exchange(.status, connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp), timeout: .milliseconds(70)); XCTFail() }
            catch { XCTAssertEqual(error as? CoreDeviceError, .timeout) }
        }
    }
    func testCancellationAndBusy() async throws {
        let (listener, port) = try await peer(reply: nil)
        defer { listener.cancel() }
        let client = NCMDiagnosticClient()
        let running = Task { try await client.exchange(.status, connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)) }
        try await Task.sleep(for: .milliseconds(40))
        do { _ = try await client.request(.status); XCTFail() } catch { XCTAssertEqual(error as? CoreDeviceError, .busy) }
        running.cancel()
        do { _ = try await running.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
