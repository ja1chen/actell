// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct DeviceConnectionSection: View {
    @State private var flow = DeviceControlCoordinator.shared
    let showTouchTest: () -> Void
    private var stateText: String {
        if flow.pairingActive { return String(localized: "Pairing") }
        if flow.ready { return String(localized: "Connected") }
        if flow.running { return String(localized: "Connecting") }
        return flow.hasRecord ? String(localized: "Not connected") : String(localized: "Not paired")
    }
    private var showsDetail: Bool {
        (flow.running && !flow.ready) ||
        (!flow.hasRecord && flow.message != String(localized: "Complete system pairing first"))
    }
    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(stateText).foregroundStyle(flow.ready ? .green : .secondary)
                        if flow.running && !flow.ready { ProgressView().controlSize(.small) }
                    }
                    if showsDetail {
                        Text(flow.lastFailure ?? flow.statusText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pairingResult")
                    }
                    if let pin = flow.pin {
                        Text(pin).font(.title.monospacedDigit())
                            .accessibilityIdentifier("pairingPIN")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if !flow.ready && !flow.running && !flow.agentReserved {
                        Button(flow.hasRecord ? String(localized: "Connect") : String(localized: "Pair")) {
                            if flow.hasRecord { flow.verify() }
                            else { flow.startPairing() }
                        }.disabled(flow.running || flow.agentReserved)
                    }
                    if !flow.ready && flow.hasRecord && !flow.running && !flow.agentReserved {
                        Button(String(localized: "Pair again")) { flow.pairAgain() }
                            .accessibilityIdentifier("pairAgain")
                    }
                    if flow.running || flow.ready || flow.agentReserved {
                        Button(String(localized: "Stop")) { flow.cancel() }
                    }
                }
                .buttonStyle(.bordered)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        if flow.ready {
            Section(String(localized: "Service verification")) {
                Button { flow.capture() } label: {
                    HStack {
                        Text(flow.capturing ? String(localized: "Taking a screenshot") : String(localized: "Take screenshot"))
                        if flow.capturing { ProgressView().controlSize(.small) }
                    }
                }.disabled(flow.running || flow.agentReserved)
                Button(String(localized: "Verify tap"), action: showTouchTest).disabled(flow.running || flow.agentReserved)
            }
            if let image = flow.image {
                Section {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(String(localized: "Phone screenshot"))
                } header: {
                    HStack {
                        Text(String(localized: "Screenshot"))
                        Spacer()
                        if let data = flow.screenshotData {
                            SaveScreenshotButton(data: data).disabled(flow.capturing)
                        }
                    }
                }
            }
        }
    }
}
