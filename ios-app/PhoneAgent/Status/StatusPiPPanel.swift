import SwiftUI
import AVFoundation
import UIKit

struct StatusPiPPanel: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var controller: StatusPiPController
    private var snapshot: AgentStatusSnapshot {
        .make(mode: model.mode, phase: model.activeRecord?.phase, running: model.running, awaitingApproval: model.approval != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(String(localized: "Preview compact status card"), isOn: Binding(get: { controller.previewEnabled }, set: { controller.setPreviewEnabled($0) }))
            if controller.previewEnabled {
                StatusSampleBufferView(displayLayer: controller.displayLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text(verbatim: [snapshot.title, snapshot.phase.title, snapshot.detail].joined(separator: ", ")))
                HStack {
                    Button { controller.start() } label: { Label(String(localized: "Enable Picture in Picture (experimental)"), systemImage: "pip.enter") }
                        .disabled(!controller.supported || !controller.backgroundModeConfigured || controller.active)
                    if controller.active { Button(String(localized: "Close Picture in Picture")) { controller.stop() } }
                }.buttonStyle(.bordered)
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
                Text(String(localized: "Shows only the task category, phase, and confirmation status. Task content, screenshots, and keys stay hidden. Actions cannot be confirmed in Picture in Picture."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: snapshot, initial: true) { _, next in controller.update(next) }
    }
}

struct StatusSampleBufferView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> StatusLayerView { StatusLayerView(displayLayer: displayLayer) }
    func updateUIView(_ view: StatusLayerView, context: Context) { view.setNeedsLayout() }
}
final class StatusLayerView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
