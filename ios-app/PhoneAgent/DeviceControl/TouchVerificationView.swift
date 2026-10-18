// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The counter is changed only by UIKit/SwiftUI delivering a real button action,
/// never by an HID send acknowledgement. Keep this page foreground during test.
struct TouchVerificationView: View {
    let flow: DeviceControlCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0
    @State private var baseline = 0
    @State private var testing = false
    @State private var result = String(localized: "Do not touch the center button during the test")
    @State private var task: Task<Void, Never>?
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack {
                    Text(String(localized: "Center touch target")).font(.title2)
                    Text(String(localized: "Touches received: \(count)")).font(.title.monospacedDigit())
                }.frame(width: 260, height: 160)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("touchVerificationTarget")
            VStack {
                HStack { Text(String(localized: "Verify actual taps")).font(.headline); Spacer(); Button(String(localized: "Close")) { dismiss() }.disabled(testing) }
                Spacer()
                Text(result).multilineTextAlignment(.center).accessibilityIdentifier("touchVerificationResult")
                Text(flow.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !flow.ready {
                    Button(String(localized: "Reconnect to \(flow.route.connectionName)")) { flow.verify() }.disabled(flow.running || flow.agentReserved)
                }
                if testing { ProgressView() }
                Button(String(localized: "Tap the center target through \(flow.route.connectionName)")) { test() }.buttonStyle(.bordered).disabled(testing || !flow.ready || flow.running || flow.agentReserved)
                Text(String(localized: "Keep this page open. An increased count confirms that the screen received the tap. A successful send alone does not confirm delivery."))
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .interactiveDismissDisabled()
        .onDisappear { task?.cancel(); if testing { flow.cancel() } }
    }
    private func test() {
        baseline = count; testing = true; result = String(localized: "Preparing the video session and sending one center tap. Do not touch the screen.")
        task = Task { @MainActor in
            defer { testing = false; task = nil }
            flow.tapCenter()
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if !flow.running {
                        try await Task.sleep(for: .milliseconds(500))
                        result = count > baseline ? String(localized: "Verified: the test page received a tap and the count increased") : String(localized: "Tap not confirmed: the count did not change.\n\(flow.message)")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                flow.cancel()
                result = String(localized: "Timed out without confirming a tap. It will not be resent automatically.")
            } catch { result = String(localized: "Test stopped") }
        }
    }
}
