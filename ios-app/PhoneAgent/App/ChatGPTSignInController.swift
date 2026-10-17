import SwiftUI
import AuthenticationServices
import Network

/// Browser and listener only own a pending attempt. Account activation is delegated
/// to the verifier/vault, after a one-time callback and completed code exchange.
@MainActor final class ChatGPTSignInController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var accounts: [ChatGPTAccountSummary] = []
    @Published private(set) var selected: String?
    private let manager: ChatGPTAccountManager
    private var browser: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var attempt: ChatGPTPendingAuthorization?
    private var work: Task<Void, Never>?, timeout: Task<Void, Never>?
    private var epoch = UUID()
    private let queue = DispatchQueue(label: "actell.chatgpt.callback")
    init(manager: ChatGPTAccountManager = .shared) { self.manager = manager }
    func reload(profileID: UUID) async {
        do { accounts = try await manager.summaries(); selected = try await manager.selectedAccount(profileID: profileID) }
        catch { message = String(localized: "Could not read the ChatGPT connection. Unlock and try again.") }
    }
    func start(profileID: UUID, onConnected: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        busy = true; message = String(localized: "Waiting for ChatGPT browser authorization"); epoch = UUID()
        let current = epoch
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: parameters); listener = l
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.epoch == current, self.busy else { return }
                    switch state {
                    case .ready:
                        guard self.attempt == nil, let port = self.listener?.port else { return }
                        self.work = Task {
                            do {
                                let p = try await self.manager.begin(profileID: profileID, redirect: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                                guard self.epoch == current, self.busy, !Task.isCancelled else { await self.manager.cancel(p.id); return }
                                self.attempt = p
                                let url = p.attempt.authorizationURL(hostID: p.hostID)
                                #if DEBUG
                                if ProcessInfo.processInfo.arguments.contains("--ui-test-chatgpt-auth") {
                                    ChatGPTOAuthUIFixture.open(url: url)
                                    return
                                }
                                // Ordinary UI tests never initiate live authorization.
                                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { self.end(String(localized: "Real authorization is disabled in local tests"), current: current); return }
                                #endif
                                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
                                    Task { @MainActor in self?.end(String(localized: "ChatGPT sign-in cancelled"), current: current) }
                                }
                                session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true
                                self.browser = session
                                if !session.start() { self.end(String(localized: "Could not open system authorization"), current: current) }
                            } catch { self.end(Self.safe(error), current: current) }
                        }
                    case .failed: self.end(String(localized: "Could not start the local authorization callback"), current: current)
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection, data: Data(), current: current, profileID: profileID, onConnected: onConnected) }
            }
            l.start(queue: queue)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                self?.end(String(localized: "ChatGPT sign-in timed out. Start again."), current: current)
            }
        } catch { end(String(localized: "Could not start the local authorization callback"), current: current) }
    }
    private func receive(_ connection: NWConnection, data: Data, current: UUID, profileID: UUID, onConnected: @escaping @MainActor () -> Void) {
        guard busy, epoch == current else { connection.cancel(); return }
        if data.isEmpty { guard connections.count < 8 else { connection.cancel(); return }; connections.append(connection); connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] next, _, complete, error in
            Task { @MainActor in
                guard let self, self.busy, self.epoch == current else { connection.cancel(); return }
                let all = data + (next ?? Data())
                guard all.count < 8192 else { connection.cancel(); return }
                if all.range(of: Data("\r\n\r\n".utf8)) == nil {
                    if !complete && error == nil { self.receive(connection, data: all, current: current, profileID: profileID, onConnected: onConnected) }
                    else { connection.cancel() }; return
                }
                guard let p = self.attempt, let text = String(data: all, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else { connection.cancel(); return }
                let words = first.split(separator: " ")
                guard words.count == 3, words[0] == "GET", words[1].hasPrefix("/auth/callback?"), words[2] == "HTTP/1.1",
                      let callback = URL(string: "http://127.0.0.1:\(p.attempt.redirect.port!)" + words[1]) else { connection.cancel(); return }
                self.attempt = nil // No second callback can exchange this code.
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 26\r\nConnection: close\r\n\r\nReturn to Actell to finish.".utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.listener?.cancel(); self.listener = nil
                self.browser?.cancel(); self.browser = nil
                // Advance epoch before cancelling browser so its late completion
                // cannot cancel the validated callback's token exchange.
                let exchangeEpoch = UUID(); self.epoch = exchangeEpoch
                self.work = Task {
                    do {
                        try await self.manager.finish(p.id, callback: callback)
                        guard self.epoch == exchangeEpoch, !Task.isCancelled else { return }
                        await self.reload(profileID: profileID)
                        self.end(nil, current: exchangeEpoch)
                        onConnected()
                    } catch { self.end(Self.safe(error), current: exchangeEpoch) }
                }
            }
        }
    }
    func cancel() { end(String(localized: "ChatGPT sign-in canceled"), current: epoch) }
    private func end(_ text: String?, current: UUID) {
        guard epoch == current else { return }
        epoch = UUID(); busy = false; message = text
        if let p = attempt { Task { await manager.cancel(p.id) } }; attempt = nil
        timeout?.cancel(); timeout = nil; work?.cancel(); work = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
    }
    func disconnect(profileID: UUID) async {
        cancel()
        do { let confirmed = try await manager.disconnect(profileID: profileID); message = confirmed ? String(localized: "Signed out. The server confirmed this refresh session was ended.") : String(localized: "Signed out on this device. Server revocation was not confirmed. You can disconnect the app in ChatGPT settings."); await reload(profileID: profileID) }
        catch { message = Self.safe(error) }
    }
    func select(_ account: String, profileID: UUID) async {
        cancel()
        do { try await manager.select(account, profileID: profileID); await reload(profileID: profileID) }
        catch { message = Self.safe(error) }
    }
    private static func safe(_ error: Error) -> String {
        if error is CancellationError { return String(localized: "ChatGPT sign-in canceled") }
        return (error as? ChatGPTAuthError)?.localizedDescription ?? (error as? AppError)?.localizedDescription ?? String(localized: "ChatGPT sign-in failed. An unverified identity was not saved.")
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? UIWindow()
    }
}
