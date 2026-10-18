import SwiftUI
import AppIntents
import Darwin

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var background = BackgroundExecutionCoordinator.shared
    @StateObject private var settings = BackgroundSettingsStore.shared
    @StateObject private var model = PhoneAgentRuntime.shared.model
    @StateObject private var statusPiP = BackgroundExecutionCoordinator.shared.media!
    @Environment(\.scenePhase) private var scenePhase
    init() {
        _ = BackgroundSettingsStore.shared // Migrate before runtime/history creation or any UI binding.
        PhoneAgentShortcuts.updateAppShortcutParameters()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--local-vpn-probe") {
            _ = DeviceControlCoordinator.shared.selectRoute(.vpnLoopback)
        }
        #endif
        DeviceControlCoordinator.shared.registerBackgroundTask()
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP, commands: PhoneAgentRuntime.shared.commands)
                .overlay {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--local-vpn-probe") { LocalVPNProbeView() }
                    else if ProcessInfo.processInfo.arguments.contains("--coredevice-video-geometry-probe") { CoreDeviceVideoGeometryProbeView(statusPiP: statusPiP) }
                    else if ProcessInfo.processInfo.arguments.contains("--coredevice-tools-probe") { CoreDeviceToolsProbeView(statusPiP: statusPiP) }
                    #endif
                }
                .onAppIntentExecution(PrepareAgentTaskIntent.self) { _ in
                    // SwiftUI receives the scene handoff; perform() alone owns task submission.
                    model.usbDiagnostics.record("siri.sceneHandoff received=true")
                }
                .preferredColorScheme(testColorScheme)
                // A covered backing layer supplies AVKit without occupying the UI.
                .background(alignment: .bottom) {
                    StatusSampleBufferView(displayLayer: statusPiP.displayLayer)
                        .frame(width: 320, height: 180)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .task {
                    let streamProbe = ProcessInfo.processInfo.arguments.contains("--task-pip-probe") && ProcessInfo.processInfo.arguments.contains("--background-stream-probe")
                    if !streamProbe { DeviceControlCoordinator.shared.restoreConnection() }
                    model.liveActivities.setBackgroundResident(settings.reservesStandbyActivity)
                    statusPiP.observeTasks(in: model)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
                        if streamProbe { background.applySelection([.audio]) }
                        model.start()
                        let startCPU = processCPUSecondsForProbe(), startTime = Date()
                        for step in 0..<(streamProbe ? 10 : 5) {
                            try? await Task.sleep(for: .seconds(10))
                            statusPiP.recordTaskProbe(step: step, running: model.hasBusySessions,
                                liveActivities: model.liveActivities.activeCountForProbe)
                            if streamProbe {
                                BackgroundExecutionTrace.record("streamProbe.cpu wall=\(Date().timeIntervalSince(startTime)) cpu=\(processCPUSecondsForProbe()-startCPU) running=\(model.hasBusySessions)")
                            }
                            if step == 0 { UIApplication.shared.perform(NSSelectorFromString("suspend")) }
                        }
                    } else { await DeviceControlCoordinator.shared.runBackgroundProbeIfRequested() }
                    #endif
                }
                .onChange(of: settings.reservesStandbyActivity) { _, enabled in
                    model.liveActivities.setBackgroundResident(enabled)
                }
                .alert(String(localized: "Enable location for background execution?"), isPresented: Binding(get: { background.locationExplanation && !background.locationExplanationInSettings }, set: { _ in })) {
                    Button(String(localized: "Not now"), role: .cancel) { background.dismissLocationExplanation() }
                    Button(String(localized: "Continue to permission")) { background.acceptLocationExplanation() }
                } message: { Text(BackgroundExecutionCoordinator.locationPurpose) }
                .onChange(of: model.approval?.id) { _, id in
                    #if DEBUG
                    if id != nil { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: true) } }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Return run leases to foreground before stopping PiP revokes its background receipt.
                    model.setScene(phase == .active ? .active : phase == .background ? .background : .inactive)
                    background.setForeground(phase == .active, transitioning: phase == .inactive)
                    if phase == .background { DeviceControlCoordinator.shared.background() }
                    else if phase == .active { DeviceControlCoordinator.shared.resume() }
                    model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
                    PhoneAgentRuntime.shared.museConnection.setScene(active: phase == .active, background: phase == .background)
                    if phase == .active { PhoneAgentRuntime.shared.commands.resumePendingExecutions() }
                    // Inactive is a transition, not a request to show PiP.

                    #if DEBUG
                    if phase == .background { PhoneAgentRuntime.shared.completeBackgroundUIFixtureIfNeeded() }
                    if phase == .active { PhoneAgentRuntime.shared.finishForegroundUIFixtureIfNeeded() }
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    PhoneAgentRuntime.shared.remoteTools.stop()
                    DeviceControlCoordinator.shared.applicationWillTerminate()
                    background.shutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    PhoneAgentRuntime.shared.remoteTools.stop()
                    DeviceControlCoordinator.shared.cancel()
                    background.setProtectedData(false)
                    model.setProtectedDataAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    background.setProtectedData(true)
                    model.setProtectedDataAvailable(true)
                    PhoneAgentRuntime.shared.museConnection.resumeIfEnabled()
                    PhoneAgentRuntime.shared.commands.resumePendingExecutions()
                }
                .onChange(of: model.hasBusySessions) { _, busy in
                    if !busy { PhoneAgentRuntime.shared.museConnection.resumeIfEnabled() }
                }
        }
    }
    private var testColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-dark") { return .dark }
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-light") { return .light }
        #endif
        return nil
    }
}

#if DEBUG
/// Explicit on-device acceptance: one screenshot, one tap on this harmless
/// counter, then another screenshot. No user history or external app is touched.
private struct LocalVPNProbeView: View {
    @State private var count = 0
    @State private var target = CGRect.zero
    @State private var status = String(localized: "Verifying VPN loopback")
    @State private var started = false
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack { Text(String(localized: "VPN loopback tap target")); Text(String(localized: "Actual touches: \(count)")).font(.largeTitle) }
                    .frame(width: 270, height: 160)
            }.buttonStyle(.borderedProminent)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { target = $0 }
            VStack { Text(String(localized: "Device verification without ESP32")).font(.title2); Spacer(); Text(status).font(.footnote).multilineTextAlignment(.center) }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await run() }
    }
    @MainActor private func run() async {
        guard !started else { return }; started = true
        let flow = DeviceControlCoordinator.shared
        let url = URL.documentsDirectory.appending(path: "local-vpn-probe.log")
        var records: [String] = []
        func record(_ line: String) {
            records.append(Date().ISO8601Format() + " " + line)
            try? records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            status = line
        }
        record("start route=\(flow.route.rawValue) paired=\(flow.hasRecord)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        if !flow.ready && !flow.running { flow.verify() }
        while flow.running && !flow.ready && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard flow.ready else { record("connection failed: \(flow.lastFailure ?? flow.message)"); return }
        record("authenticated CoreDevice ready")
        var control: CoreDeviceBridge?
        do {
            let bridge = try CoreDeviceBridge(flow: flow); control = bridge
            let frame = try await bridge.screenshot()
            try frame.png.write(to: URL.documentsDirectory.appending(path: "local-vpn-before.jpg"))
            record("screenshot \(frame.width)x\(frame.height) bytes=\(frame.png.count)")
            guard !target.isEmpty, let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen else {
                throw AppError.invalid(String(localized: "The tap target has not been laid out"))
            }
            let x = Int((target.midX / screen.bounds.width * 65535).rounded())
            let y = Int((target.midY / screen.bounds.height * 65535).rounded())
            let baseline = count
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.tap(x: x, y: y, imageID: frame.id)
            try await Task.sleep(for: .seconds(1))
            record("tap delivered; actual counter \(baseline)->\(count)")
            let after = try await bridge.screenshot()
            try after.png.write(to: URL.documentsDirectory.appending(path: "local-vpn-after.jpg"))
            await bridge.stop(); control = nil
            let released = flow.ready && !flow.running && flow.lastFailure == nil && flow.message == String(localized: "Screen control ended")
            record("media release confirmed=\(released)")
            record(count == baseline + 1 && released ? "PASS screenshot + actual touch + media release" : "FAIL touch or media release not confirmed; input will not replay")
        } catch {
            if let control { await control.stop() }
            record("failed: \(String(describing: error)); \(flow.lastFailure ?? flow.message)")
        }
    }
}

private func processCPUSecondsForProbe() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

/// Explicit read-only screenshot probe. Raw media is saved only for this launch flag.
private struct CoreDeviceVideoGeometryProbeView: View {
    let statusPiP: StatusPiPController
    @State private var status = String(localized: "Video screenshot diagnostics")
    var body: some View {
        VStack(spacing: 20) { Text(String(localized: "Video screenshot diagnostics")).font(.title); Text(status) }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
            .task { await run() }
    }
    @MainActor private func run() async {
        let directory = URL.documentsDirectory
        let log = directory.appending(path: "coredevice-video-geometry-probe.log")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append(Date().ISO8601Format() + " " + value)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            NSLog("CoreDevice video probe %@", value)
        }
        let flow = DeviceControlCoordinator.shared
        let backgroundProbe = ProcessInfo.processInfo.arguments.contains("--coredevice-video-background-probe")
        let repeatedProbe = backgroundProbe || ProcessInfo.processInfo.arguments.contains("--coredevice-video-repeat-probe")
        if backgroundProbe {
            BackgroundExecutionCoordinator.shared.applySelection([.audio])
            statusPiP.setControlProbeRunning(true)
        }
        defer { if backgroundProbe { statusPiP.setControlProbeRunning(false) } }
        record("started backgroundProbe=\(backgroundProbe)")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { status = String(localized: "Connection is not ready"); record(flow.lastFailure ?? flow.statusText); return }
        var bridge: CoreDeviceBridge?
        do {
            let control = try CoreDeviceBridge(flow: flow); bridge = control
            for index in 0..<(repeatedProbe ? 7 : 3) {
                let frame = try await control.screenshot()
                try frame.png.write(to: directory.appending(path: "coredevice-video-probe-\(index).jpg"))
                if let keyframe = await flow.videoDiagnosticKeyframe() {
                    try keyframe.write(to: directory.appending(path: "coredevice-video-probe.hevc"))
                }
                record("screenshot \(index) \(frame.width)x\(frame.height) appState=\(UIApplication.shared.applicationState.rawValue)")
                status = String(localized: "Captured \(index+1)/\(repeatedProbe ? 7 : 3): \(frame.width) × \(frame.height)")
                if backgroundProbe && index == 0 {
                    try await Task.sleep(for: .seconds(3))
                    UIApplication.shared.perform(NSSelectorFromString("suspend"))
                }
                if backgroundProbe && ProcessInfo.processInfo.arguments.contains("--coredevice-static-screen-probe") && (index == 1 || index == 5) {
                    let context = try await control.systemActionContext()
                    try await control.authorizeSystemAction(authorizationID: context, taskScoped: false)
                    try await control.systemAction(name: "launch_app", text: index == 1 ? "com.apple.calculator" : "com.apple.Preferences", arguments: [], imageID: context)
                    record("visible change receiverState=\(UIApplication.shared.applicationState.rawValue)")
                }
                try await Task.sleep(for: .milliseconds(repeatedProbe ? 6000 : 1200))
            }
            record("completed")
        } catch { record("failed \(String(describing: error))"); status = String(localized: "Diagnostics did not finish") }
        if let bridge { await bridge.stop() }
    }
}

/// Explicit real-device fixture, no provider calls or user conversation writes.
private struct CoreDeviceToolsProbeView: View {
    let statusPiP: StatusPiPController
    @State private var status = String(localized: "Preparing verification")
    var body: some View {
        VStack(spacing: 24) {
            Text(String(localized: "ESP32 tool verification")).font(.title)
            Text(status)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
        .task { await run() }
    }
    @MainActor private func run() async {
        let url = URL.documentsDirectory.appending(path: "coredevice-tools-probe.log")
        var records: [String] = []
        func record(_ value: String) { records.append(Date().ISO8601Format() + " " + value); try? records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        let flow = DeviceControlCoordinator.shared
        statusPiP.setControlProbeRunning(true)
        let scheduler = CompositeRunScheduler(primary: ContinuedProcessingScheduler(), allowed: { [.audio, .systemTask] })
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        defer { lease?.complete(success: true); scheduler.cancel(identifier: identifier); statusPiP.setControlProbeRunning(false) }
        var expired = false
        do {
            try scheduler.submit(identifier: identifier, launched: { incoming in
                lease = incoming
                incoming.expirationHandler = { expired = true; record("execution expired") }
            })
        } catch { record("execution unavailable"); return }
        record("start")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { record("connection not ready"); status = String(localized: "Connection is not ready"); return }
        statusPiP.setControlProbeRunning(true)
        do {
            let bridge = try CoreDeviceBridge(flow: flow)
            defer { Task { await bridge.stop() } }
            let data = try await bridge.installedApplications()
            let apps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            record("apps count=\(apps.count) notes=\(apps.contains { $0["bundle_id"] as? String == "com.apple.mobilenotes" })")
            var frame = try await bridge.screenshot()
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "home", text: "", arguments: [], imageID: frame.id)
            record("Home delivery acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            try frame.png.write(to: URL.documentsDirectory.appending(path: "coredevice-tools-home.png"))
            guard !expired else { throw AppError.stopped }
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "launch_app", text: "com.apple.mobilenotes", arguments: [], imageID: frame.id)
            record("Notes launch acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            let screenURL = URL.documentsDirectory.appending(path: "coredevice-tools-screen.png")
            try frame.png.write(to: screenURL)
            record("Notes screenshot ready \(frame.width)x\(frame.height)")
            lease?.report(completed: 3, subtitle: String(localized: "Home, app discovery, and Notes launch returned. Waiting for test actions."))
            // Explicit debug-only command fixture. Never read task history,
            // arbitrary typed text, identities or paths from this command file.
            let commandURL = URL.documentsDirectory.appending(path: "coredevice-tools-command.json")
            try? FileManager.default.removeItem(at: commandURL)
            var lastID = 0
            let testDeadline = ContinuousClock.now.advanced(by: .seconds(600))
            while ContinuousClock.now < testDeadline && !expired {
                try await Task.sleep(for: .milliseconds(200))
                guard let data = try? Data(contentsOf: commandURL), data.count < 4096,
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = command["id"] as? Int, id > lastID,
                      let action = command["action"] as? String else { continue }
                // Commit consumption before dispatch; lost receipts never replay.
                lastID = id
                if action == "finish" { record("finished"); break }
                if action != "screenshot" {
                    try await bridge.authorizeTaskInput(imageID: frame.id)
                    if action == "tap" {
                        guard let x = command["x"] as? Int, let y = command["y"] as? Int else { throw AppError.invalid(String(localized: "Test coordinates are missing")) }
                        try await bridge.tap(x: x, y: y, imageID: frame.id)
                    } else if action == "type_text" {
                        try await bridge.systemAction(name: action, text: "ESP32 direct input", arguments: [], imageID: frame.id)
                    } else { throw AppError.invalid(String(localized: "Unsupported test action")) }
                    try await Task.sleep(for: .seconds(1))
                }
                frame = try await bridge.screenshot()
                try frame.png.write(to: screenURL)
                record("command id=\(id) action=\(action) delivered and screenshot received")
                lease?.report(completed: id + 3, subtitle: String(localized: "Notes verification returned a screenshot"))
            }
            status = String(localized: "Verification complete")
        } catch { status = String(localized: "Verification did not finish"); record("failed: " + String(describing: error)) }
    }
}
#endif
