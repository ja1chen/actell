import Foundation
import ProviderCore
@testable import PhoneAgent

final class AdmissionInspectionProvider: ModelProvider, @unchecked Sendable {
    static let name = "admission-inspection"
    let configuration = DemoProvider().configuration
    private let lock = NSLock()
    private var captured: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { captured } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(text: "Chat completed", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.terminal(ModelResponse(text: "Chat completed", finishReason: .stop, request: request, providerName: Self.name)))
            continuation.finish()
        }
    }
}
