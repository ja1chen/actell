import XCTest
import Combine
import ActivityKit
@testable import PhoneAgent

@MainActor final class ApprovalRecordTests: XCTestCase {
    private let run = RunIdentity(conversationID: UUID(), runID: UUID())
    private func request() throws -> Approval {
        Approval(tool: "tap", detail: "Sensitive purpose", imageID: "private-screen", callID: "call-1",
                 parametersDigest: try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 3, "y": 7, "purpose": "Sensitive purpose"]))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testApprovalIsAtomicSingleUseAndAcceptanceIsNotExecution() throws {
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        try store.resolve(request, run: run, approved: true)
        XCTAssertEqual(store.record(id: request.id)?.state, .accepted)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: false))
        try store.claimExecution(callID: "call-1", run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .executing)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        try store.finish(callID: "call-1", run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .finished)
    }
    func testTaskGrantIsRecordedAndCannotBeReusedAfterCancellationOrRestart() throws {
        let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
        try store.register(request, run: run, authorizationMode: .task)
        try store.resolve(request, run: run, approved: true)
        XCTAssertEqual(store.record(id: request.id)?.authorizationMode, .task)
        try store.claimExecution(callID: "call-1", run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        let restored = ApprovalRecordStore(directory: dir)
        XCTAssertEqual(restored.record(id: request.id)?.authorizationMode, .task)
        XCTAssertEqual(restored.record(id: request.id)?.state, .interrupted)
        XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
        try store.invalidate(run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testWrongRunParametersVersionAndExpiryCannotAuthorize() throws {
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run)
        XCTAssertThrowsError(try store.resolve(request, run: RunIdentity(conversationID: run.conversationID, runID: UUID()), approved: true))
        XCTAssertThrowsError(try store.resolve(request, run: RunIdentity(conversationID: UUID(), runID: run.runID), approved: true))
        var changed = request; changed.parametersDigest = "different"
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        changed = request; changed.version = 2
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        changed = request; changed.expiresAt = request.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        XCTAssertTrue(store.isPending(request, run: run))
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true, now: request.expiresAt))
        XCTAssertEqual(store.record(id: request.id)?.state, .expired)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testDeniedCancelledAndRelaunchedRecordsCannotResume() throws {
        for approved in [false, true] {
            let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
            try store.register(request, run: run)
            try store.resolve(request, run: run, approved: approved)
            if !approved { XCTAssertEqual(store.record(id: request.id)?.state, .denied) }
            let restored = ApprovalRecordStore(directory: dir)
            XCTAssertEqual(restored.record(id: request.id)?.state, approved ? .interrupted : .denied)
            XCTAssertThrowsError(try restored.resolve(request, run: run, approved: true))
            XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
        }
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run); try store.invalidate(run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .cancelled)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
    }
    func testPendingAndExecutingRecordsAreInvalidatedOnProcessRestart() throws {
        for execute in [false, true] {
            let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
            try store.register(request, run: run)
            if execute { try store.resolve(request, run: run, approved: true); try store.claimExecution(callID: "call-1", run: run) }
            let restored = ApprovalRecordStore(directory: dir)
            XCTAssertEqual(restored.record(id: request.id)?.state, .interrupted)
            XCTAssertFalse(restored.isPending(request, run: run))
            XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
            let text = try String(contentsOf: dir.appendingPathComponent("approvals-v1.json"))
            XCTAssertFalse(text.contains("Sensitive purpose")); XCTAssertFalse(text.contains("private-screen"))
        }
    }
    func testCorruptAuthorityFailsClosedAndPreservesFile() throws {
        let dir = try directory(), file = dir.appendingPathComponent("approvals-v1.json"), data = Data("preserve corruption".utf8)
        try data.write(to: file)
        let store = ApprovalRecordStore(directory: dir)
        XCTAssertThrowsError(try store.register(request(), run: run))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testPersistenceFailureNeverReleasesApproval() throws {
        let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
        try store.register(request, run: run)
        // Replace the directory with a regular file, making the atomic write fail.
        try FileManager.default.removeItem(at: dir); try Data().write(to: dir)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
        XCTAssertEqual(store.record(id: request.id)?.state, .pending)
        XCTAssertFalse(store.isPending(request, run: run))
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testParameterDigestIsStableAndBindsActualParameters() throws {
        let a = try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 1, "y": 2])
        XCTAssertEqual(a, try ApprovalRecordStore.digest(tool: "tap", parameters: ["y": 2, "x": 1]))
        XCTAssertNotEqual(a, try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 2, "y": 2]))
        XCTAssertNotEqual(a, try ApprovalRecordStore.digest(tool: "drag", parameters: ["x": 1, "y": 2]))
    }
}

@MainActor final class LiveActivityTests: XCTestCase {
    private func snapshot(_ phase: AgentActivityAttributes.Phase, run: UUID) -> AgentActivitySnapshot {
        .init(attributes: .init(sessionID: UUID(), runID: run, isDemo: true),
              state: .init(phase: phase, completedTools: 3, updatedAt: Date()), staleDate: Date().addingTimeInterval(30))
    }
    func testResidentCreatesStandbyInForegroundAndReusesItForBackgroundTasks() async throws {
        let handle = RecordingActivityHandle()
        var created: [AgentActivitySnapshot] = []
        let controller = AgentLiveActivityController(createActivity: { snapshot in
            created.append(snapshot); return handle
        })
        let store = ConversationStore(inMemory: true)
        _ = AgentViewModel(sessions: store, loadPersistentState: false, sharedActivities: controller)
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(created.count, 1)
        let standby = try XCTUnwrap(created.first)
        XCTAssertEqual(standby.state.phase, .standby)
        XCTAssertNil(standby.state.route(attributes: standby.attributes))
        XCTAssertTrue(store.conversations.isEmpty)
        controller.setForeground(false)
        let run = snapshot(.awaitingApproval, run: UUID())
        controller.submit(run)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(created.count, 1, "background submission must only update the reserved activity")
        let state = try XCTUnwrap(handle.states.last)
        XCTAssertEqual(state.phase, .awaitingApproval)
        XCTAssertEqual(handle.alerts, 1, "the first background task update requests expansion")
        XCTAssertEqual(state.route(attributes: standby.attributes),
            AgentActivityRoute(sessionID: run.attributes.sessionID, runID: run.attributes.runID, approvalID: run.state.approvalID))
        controller.submit(snapshot(.completed, run: run.attributes.runID))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 2, "task start and completion each alert once")
        XCTAssertTrue(handle.ended.isEmpty)
        let next = snapshot(.thinking, run: UUID())
        controller.submit(next)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(handle.states.last?.runID, next.attributes.runID)
        controller.setForeground(true)
        controller.submit(snapshot(.completed, run: next.attributes.runID))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.states.last?.phase, .standby)
        XCTAssertNil(handle.states.last?.runID)
        XCTAssertNil(handle.staleDates.last!)
        controller.setBackgroundResident(false)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.ended.count, 1)
    }
    func testDisablingStandbyPreservesRunningActivityAndEndsItAfterCompletion() async {
        let handle = RecordingActivityHandle()
        var requests = 0
        let controller = AgentLiveActivityController(createActivity: { _ in requests += 1; return handle })
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        let run = UUID()
        controller.submit(snapshot(.thinking, run: run))
        await controller.waitForPendingUpdates()
        controller.setBackgroundResident(false)
        await controller.waitForPendingUpdates()
        XCTAssertTrue(handle.ended.isEmpty)
        controller.submit(snapshot(.executing, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.states.last?.phase, .executing)
        controller.submit(snapshot(.completed, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.ended.count, 1)
        XCTAssertEqual(requests, 1)
    }
    func testResidentDoesNotRequestStandbyInBackgroundOrAfterDisable() async {
        var requests = 0
        let controller = AgentLiveActivityController(createActivity: { _ in requests += 1; return RecordingActivityHandle() })
        controller.setForeground(false)
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(requests, 0)
        controller.setForeground(true)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(requests, 1)
        controller.setBackgroundResident(false)
        await controller.waitForPendingUpdates()
        controller.setBackgroundResident(true)
        controller.setBackgroundResident(false)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(requests, 1, "a superseded enable cannot create an idle activity")
    }
    func testBackgroundExecutionExpansionIsOncePerRunAndNeverForIdleOrForeground() async {
        let handle = RecordingActivityHandle()
        let controller = AgentLiveActivityController(createActivity: { _ in handle })
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 0)
        let run = UUID()
        controller.submit(snapshot(.thinking, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 0)
        controller.setForeground(false)
        let working = snapshot(.working, run: run)
        controller.submit(working)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 0, "moving a foreground-started task to the background must not expand")
        controller.submit(working)
        controller.submit(snapshot(.executing, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 0)
        controller.submit(snapshot(.stopped, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 0)
        let backgroundRun = UUID()
        controller.submit(snapshot(.thinking, run: backgroundRun))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 1, "the next task started in the background gets its own expansion")
        let progress = snapshot(.working, run: backgroundRun)
        controller.submit(progress); controller.submit(progress)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.alerts, 1, "duplicate and progress updates cannot repeatedly expand")
    }
    func testForegroundRunStaysSilentWhenItsFirstWriteWaitsUntilBackground() async {
        for resident in [false, true] {
            let handle = RecordingActivityHandle()
            let controller = AgentLiveActivityController(createActivity: { _ in handle })
            controller.setBackgroundResident(resident)
            await controller.waitForPendingUpdates()
            let run = UUID()
            controller.submit(snapshot(.thinking, run: run))
            // The scene changes and progress supersedes the first snapshot
            // before ActivityKit gets to process either queued write.
            controller.setForeground(false)
            controller.submit(snapshot(.working, run: run))
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.alerts, 0)
            controller.submit(snapshot(.executing, run: run))
            await controller.waitForPendingUpdates()
            let completed = snapshot(.completed, run: run)
            controller.submit(completed); controller.submit(completed)
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.states.last?.phase, .completed, "silent tasks must still update their status")
            XCTAssertEqual(handle.alerts, 0, "foreground-origin execution and completion remain silent for both handle types")
            XCTAssertTrue(handle.ended.isEmpty)
        }
    }
    func testBackgroundRunKeepsItsOriginAcrossQueuedForegroundWrites() async {
        for resident in [false, true] {
            let handle = RecordingActivityHandle()
            let controller = AgentLiveActivityController(createActivity: { _ in handle })
            controller.setBackgroundResident(resident)
            await controller.waitForPendingUpdates()
            controller.setForeground(false)
            let run = UUID()
            controller.submit(snapshot(.thinking, run: run))
            controller.setForeground(true)
            controller.submit(snapshot(.working, run: run))
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.alerts, 0, "background-origin tasks do not alert while the app is visible")
            controller.setForeground(false)
            controller.submit(snapshot(.executing, run: run))
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.alerts, 1, "the first submission determines origin despite queued scene changes")
            controller.submit(snapshot(.working, run: run))
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.alerts, 1)
            let completed = snapshot(.completed, run: run)
            controller.submit(completed); controller.submit(completed)
            await controller.waitForPendingUpdates()
            XCTAssertEqual(handle.alerts, 2, "background-origin start and completion each alert once")
        }
    }
    func testResidentSkipsIdenticalProgressButRefreshesExpiryAndApprovalChanges() async {
        let handle = RecordingActivityHandle()
        let controller = AgentLiveActivityController(createActivity: { _ in handle })
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        controller.setForeground(false)
        let initial = snapshot(.working, run: UUID())
        var state = initial.state
        var staleDate = initial.staleDate
        func progress() -> AgentActivitySnapshot {
            .init(attributes: initial.attributes, state: state, staleDate: staleDate)
        }
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        let count = handle.updates.count
        state.updatedAt += 1
        staleDate += 1
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.updates.count, count)
        state.updatedAt += 15
        staleDate += 15
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.updates.count, count + 1, "unchanged processing still refreshes stale deadline")
        state.completedTools += 1
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.states.last?.completedTools, state.completedTools)
        state.phase = .awaitingApproval
        state.approvalID = UUID()
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        let approvalCount = handle.updates.count
        staleDate += 1
        controller.submit(progress())
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.updates.count, approvalCount + 1, "approval expiry changes cannot be deferred")
        XCTAssertEqual(handle.alerts, 1)
    }
    func testBurstProgressIsCoalescedWithoutLosingApprovalOrStop() async throws {
        let handle = RecordingActivityHandle()
        let controller = AgentLiveActivityController(createActivity: { _ in handle })
        let initial = snapshot(.thinking, run: UUID())
        controller.submit(initial)
        await controller.waitForPendingUpdates()
        let progress = AgentActivitySnapshot(attributes: initial.attributes,
            state: .init(phase: .working, completedTools: 3, updatedAt: Date()), staleDate: initial.staleDate)
        controller.submit(progress)
        try await Task.sleep(for: .milliseconds(50))
        let approval = AgentActivitySnapshot(attributes: initial.attributes,
            state: .init(phase: .awaitingApproval, completedTools: 3, approvalID: UUID(), updatedAt: Date()),
            staleDate: initial.staleDate)
        controller.submit(approval)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.updates, [.awaitingApproval])
        XCTAssertEqual(handle.states.last?.approvalID, approval.state.approvalID)
        controller.submit(.init(attributes: initial.attributes,
            state: .init(phase: .stopped, completedTools: 3, updatedAt: Date()), staleDate: initial.staleDate))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.ended, [.stopped])
    }
    func testDisablingResidentKeepsCurrentRunAndOldCompletionCannotReplaceNewRun() async {
        let handle = RecordingActivityHandle()
        var requests = 0
        let controller = AgentLiveActivityController(createActivity: { _ in requests += 1; return handle })
        controller.setBackgroundResident(true)
        await controller.waitForPendingUpdates()
        controller.setForeground(false)
        let a = snapshot(.working, run: UUID()), b = snapshot(.thinking, run: UUID())
        controller.submit(a); controller.submit(b)
        await controller.waitForPendingUpdates()
        controller.submit(snapshot(.stopped, run: a.attributes.runID))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.states.last?.runID, b.attributes.runID)
        XCTAssertEqual(handle.states.last?.phase, .thinking)
        controller.setBackgroundResident(false)
        await controller.waitForPendingUpdates()
        XCTAssertTrue(handle.ended.isEmpty)
        controller.submit(snapshot(.stopped, run: b.attributes.runID))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.ended, [.stopped])
        XCTAssertEqual(requests, 1)
    }
    func testStandbyContentAndLegacyContentDecodeWithoutMutableRunIdentity() throws {
        let attributes = AgentActivityAttributes(sessionID: UUID(), runID: UUID(), isDemo: true)
        let old = AgentActivityAttributes.ContentState(phase: .thinking, completedTools: 0, updatedAt: Date())
        let decoded = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.route(attributes: attributes), AgentActivityRoute(sessionID: attributes.sessionID, runID: attributes.runID))
        var standby = decoded; standby.phase = .standby
        XCTAssertNil(standby.route(attributes: attributes))
        XCTAssertEqual(standby.title, "等待任务")
        XCTAssertEqual(standby.compactTitle, "待命")
    }
    func testBackgroundCompletionAlertsOnceAndRemainsUntilForeground() async throws {
        let handle = RecordingActivityHandle()
        var created = 0
        let controller = AgentLiveActivityController(createActivity: { _ in created += 1; return handle })
        let run = UUID()
        controller.setForeground(false)
        controller.submit(snapshot(.working, run: run))
        await controller.waitForPendingUpdates()
        XCTAssertEqual(created, 1)
        XCTAssertEqual(handle.alerts, 1)
        let completed = snapshot(.completed, run: run)
        controller.submit(completed); controller.submit(completed)
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handle.updates.count, 3)
        XCTAssertEqual(handle.alerts, 2)
        XCTAssertEqual(handle.updates.last, .completed)
        XCTAssertTrue(handle.ended.isEmpty, "Ending immediately would hide the completion island")
        controller.setForeground(true)
        try await waitUntil { handle.ended.count == 1 }
        XCTAssertEqual(handle.ended, [.completed])
        XCTAssertEqual(handle.alerts, 2)
    }
    func testNextRunDismissesCompletedIslandWithoutEndingAnotherActiveRun() async throws {
        var handles: [UUID: RecordingActivityHandle] = [:]
        let controller = AgentLiveActivityController(createActivity: { snapshot in
            let handle = RecordingActivityHandle(); handles[snapshot.attributes.runID] = handle; return handle
        })
        let a = UUID(), b = UUID(), c = UUID()
        controller.submit(snapshot(.working, run: a))
        try await waitUntil { handles[a] != nil }
        controller.submit(snapshot(.working, run: b))
        try await waitUntil { handles[b] != nil }
        controller.setForeground(false)
        controller.submit(snapshot(.completed, run: a))
        try await waitUntil { handles[a]?.updates.last == .completed }
        XCTAssertEqual(handles[a]?.alerts, 0)
        controller.submit(snapshot(.thinking, run: b))
        try await waitUntil { handles[b]?.updates.last == .thinking }
        XCTAssertTrue(handles[a]?.ended.isEmpty == true)
        controller.submit(snapshot(.working, run: c))
        try await waitUntil { handles[c] != nil }
        await controller.waitForPendingUpdates()
        XCTAssertEqual(handles[a]?.ended, [.completed])
        XCTAssertTrue(handles[b]?.ended.isEmpty == true)
        XCTAssertEqual(handles[b]?.alerts, 0, "another active foreground-origin run stays silent")
        XCTAssertEqual(handles[c]?.alerts, 1, "a new background-origin run alerts independently")
    }
    func testRunKeepsExecutionUntilCompletionActivityUpdateReturns() async throws {
        let handle = RecordingActivityHandle()
        handle.holdCompletion = true
        let activities = AgentLiveActivityController(createActivity: { _ in handle })
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                   sharedActivities: activities)
        defer { handle.releaseCompletion(); model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("completion ordering", in: id))
        try await waitUntil { model.approval != nil }
        activities.setForeground(false)
        model.approve(true)
        try await waitUntil { handle.completionPending }
        XCTAssertTrue(model.running, "Media playback must remain owned while ActivityKit is still updating")
        XCTAssertEqual(model.lifecycle.checkpoint?.phase, .running, "Do not release the execution lease before the completion update")
        handle.releaseCompletion()
        try await waitUntil { !model.running }
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        // A foreground-origin completion stays silent, but its ActivityKit
        // update still has to finish before releasing the execution lease.
        XCTAssertEqual(handle.alerts, 0)
        XCTAssertTrue(handle.ended.isEmpty)
    }
    func testSiriSubmissionWaitsForActivityCreationBehindAnOlderWrite() async throws {
        let oldHandle = RecordingActivityHandle()
        oldHandle.holdCompletion = true
        let oldRun = UUID()
        var createdRuns: [UUID] = []
        let activities = AgentLiveActivityController(createActivity: { snapshot in
            createdRuns.append(snapshot.attributes.runID)
            return snapshot.attributes.runID == oldRun ? oldHandle : RecordingActivityHandle()
        })
        activities.submit(snapshot(.working, run: oldRun))
        await activities.waitForPendingUpdates()
        activities.setForeground(false)
        activities.submit(snapshot(.completed, run: oldRun))
        try await waitUntil { oldHandle.completionPending }
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
                                   runServices: .init(provider: DemoProvider(), bridge: DemoBridge()), sharedActivities: activities)
        defer { oldHandle.releaseCompletion(); model.stop() }
        // Synthetic demo remains offline and stops at its existing approval gate.
        let service = SessionCommandService(sessions: store, runner: model)
        let command = SessionCommand(.execute("Siri activity ordering"))
        var returned = false
        let submission = Task { @MainActor in
            try await PrepareAgentTaskIntent().submit(command, using: service, activities: activities)
            returned = true
        }
        try await waitUntil { model.hasBusySessions }
        XCTAssertFalse(returned)
        oldHandle.releaseCompletion()
        try await submission.value
        let run = try XCTUnwrap(store.conversations.first(where: { $0.entry?.commandID == command.commandID })?.entry?.runID)
        XCTAssertTrue(createdRuns.contains(run), "Create the new activity before the intent returns")
        try await PrepareAgentTaskIntent().submit(command, using: service, activities: activities)
        XCTAssertEqual(createdRuns.filter { $0 == run }.count, 1, "A command retry must not create another activity")
    }

    func testSiriActivityDenialDoesNotRetryTheTask() async throws {
        var requests = 0
        let activities = AgentLiveActivityController(createActivity: { _ in
            requests += 1
            throw AppError.unavailable("Synthetic activity denial")
        })
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
                                   runServices: .init(provider: DemoProvider(), bridge: DemoBridge()), sharedActivities: activities)
        defer { model.stop() }
        let service = SessionCommandService(sessions: store, runner: model)
        let command = SessionCommand(.execute("Siri denied activity"))
        try await PrepareAgentTaskIntent().submit(command, using: service, activities: activities)
        XCTAssertGreaterThan(requests, 0)
        XCTAssertNotNil(activities.notice)
        let run = try XCTUnwrap(store.conversations.first?.entry?.runID)
        try await PrepareAgentTaskIntent().submit(command, using: service, activities: activities)
        XCTAssertEqual(store.conversations.first?.entry?.runID, run)
        XCTAssertEqual(store.conversations.count, 1)
    }
    func testStopWhileCompletionUpdateWaitsCannotRestoreCompletedRun() async throws {
        let handle = RecordingActivityHandle()
        handle.holdCompletion = true
        let activities = AgentLiveActivityController(createActivity: { _ in handle })
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                   sharedActivities: activities)
        defer { handle.releaseCompletion(); model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("stop during completion", in: id))
        try await waitUntil { model.approval != nil }
        activities.setForeground(false)
        model.approve(true)
        try await waitUntil { handle.completionPending }
        model.stop()
        handle.releaseCompletion()
        try await waitUntil { !model.stopping && handle.ended.last == .stopped }
        XCTAssertEqual(model.activitySnapshot?.state.phase, .stopped)
        XCTAssertEqual(model.sessions.conversation(id)?.phase, .stopped)
        XCTAssertNil(model.activityNavigation, "A cancelled completion must not navigate back")
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Offline runtime timed out"); throw AppError.timeout
    }
    private func pendingDemo() async throws -> AgentViewModel {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("Secret goal 123", in: id))
        try await waitUntil { model.approval != nil }
        return model
    }
    func testOperationIconsMatchConversationAndTerminalPhaseOverridesOldTool() throws {
        for name in ["screenshot", "list_apps", "tap", "drag", "home", "launch_app", "type_text", "load_skill"] {
            let tool = ToolStep(callID: "test", name: name, state: .running, detail: "")
            var state = AgentActivityAttributes.ContentState(phase: .working, completedTools: 0, updatedAt: Date(), operation: .tool(name))
            XCTAssertEqual(state.symbol, tool.symbol)
            XCTAssertEqual(state.title, state.operation?.title)
            XCTAssertEqual(state.compactTitle, state.operation?.compactTitle)
            for phase in [AgentActivityAttributes.Phase.completed, .stopped, .interrupted, .blocked] {
                state.phase = phase
                XCTAssertEqual(state.symbol, phase.symbol)
                XCTAssertEqual(state.title, phase.title)
            }
        }
        let old = AgentActivityAttributes.ContentState(phase: .thinking, completedTools: 0, updatedAt: Date())
        let data = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: data).symbol, "brain")
        XCTAssertEqual(AgentActivityAttributes.Phase.working.symbol, "gearshape")
    }
    func testStrictRouteRoundTripRejectsActionAndMalformedParameters() throws {
        let route = AgentActivityRoute(sessionID: UUID(), runID: UUID(), approvalID: UUID())
        XCTAssertEqual(AgentActivityRoute(url: route.url), route)
        for suffix in ["&approve=true", "&approval=" + UUID().uuidString, "#fragment"] {
            XCTAssertNil(AgentActivityRoute(url: try XCTUnwrap(URL(string: route.url.absoluteString + suffix))))
        }
        XCTAssertNil(AgentActivityRoute(url: URL(string: "phoneagent://activity/session/nope/run/nope")!))
        XCTAssertNil(AgentActivityRoute(url: URL(string: route.url.absoluteString.replacingOccurrences(of: "phoneagent:", with: "https:"))!))
    }
    func testRealEventsProjectSafeStatusApprovalAcceptanceExecutionAndCompletion() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let waiting = try XCTUnwrap(model.activitySnapshot), request = try XCTUnwrap(model.approval)
        XCTAssertEqual(waiting.state.phase, .awaitingApproval)
        XCTAssertEqual(waiting.state.symbol, "pointer.arrow.ipad")
        XCTAssertEqual(waiting.state.approvalID, request.id)
        XCTAssertEqual(waiting.attributes.runID, model.currentRun?.runID)
        let encoded = String(data: try JSONEncoder().encode(waiting.state), encoding: .utf8)!
        for privateValue in ["Secret goal", request.detail, request.imageID, request.parametersDigest, request.callID!] { XCTAssertFalse(encoded.contains(privateValue)) }
        var phases: [AgentActivityAttributes.Phase] = []
        let subscription = model.$activitySnapshot.compactMap { $0?.state.phase }.sink { phases.append($0) }
        model.approve(true)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .approved)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        try await waitUntil { !model.running }
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        XCTAssertEqual(model.activitySnapshot?.state.symbol, "checkmark.circle")
        XCTAssertNil(model.activitySnapshot?.state.operation)
        XCTAssertEqual(model.activitySnapshot?.state.completedTools, 4)
        XCTAssertTrue(phases.contains(.executing))
        XCTAssertLessThan(try XCTUnwrap(phases.firstIndex(of: .approved)), try XCTUnwrap(phases.firstIndex(of: .executing)))
        subscription.cancel()
    }
    func testDeepLinkOnlyNavigatesAndCannotCrossNewRunOrSession() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let run = try XCTUnwrap(model.currentRun), request = try XCTUnwrap(model.approval)
        let route = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: request.id)
        XCTAssertTrue(model.openActivityURL(route.url))
        XCTAssertEqual(model.approval?.id, request.id)
        XCTAssertEqual(model.activityNavigation?.messageID, model.sessions.conversation(run.conversationID)?.messages.first { $0.tool?.callID == request.callID }?.id)
        XCTAssertEqual(model.approvalRecords.record(id: request.id)?.state, .pending)
        XCTAssertFalse(model.openActivityURL(AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: UUID()).url))
        model.stop(); try await waitUntil { !model.stopping }
        XCTAssertTrue(model.openActivityURL(route.url))
        XCTAssertEqual(model.activityNavigation?.route, route)
        XCTAssertEqual(model.activityNavigation?.messageID, model.sessions.conversation(run.conversationID)?.messages.first { $0.tool?.callID == request.callID }?.id)
        XCTAssertNil(model.approval)
        XCTAssertTrue(model.send("new run", in: run.conversationID))
        try await waitUntil { model.approval != nil }
        let next = model.approval?.id
        XCTAssertFalse(model.openActivityURL(route.url))
        XCTAssertEqual(model.approval?.id, next)
        XCTAssertTrue(model.running)
        model.stop(); try await waitUntil { !model.stopping }
        let other = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("other session", in: other))
        XCTAssertTrue(model.openActivityURL(route.url))
        XCTAssertEqual(model.selectedConversationID, other)
        XCTAssertTrue(model.isRunning(in: other))
        let otherRun = try XCTUnwrap(model.executionModel(for: other).ownedRun)
        XCTAssertTrue(model.stop(run: otherRun))
        try await waitUntil { !model.executionModel(for: other).stopping }
    }
    func testBackgroundStopsAndClearsAllActionAuthority() async throws {
        let model = try await pendingDemo()
        let request = try XCTUnwrap(model.approval)
        model.setForeground(false)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .interrupted)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        XCTAssertEqual(model.approvalRecords.record(id: request.id)?.state, .cancelled)
        model.approve(true)
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.currentRun); XCTAssertNil(model.approval)
        XCTAssertFalse(model.sessions.conversations.flatMap(\.messages).contains { $0.tool?.name == "tap" && $0.tool?.state == .succeeded })
    }
    func testOldActionLinkCannotExposeDifferentApprovalWithinSameRun() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let run = try XCTUnwrap(model.currentRun), old = try XCTUnwrap(model.approval)
        let route = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: old.id)
        model.approval = Approval(tool: "drag", detail: "different action", imageID: "different", callID: "next-action")
        XCTAssertFalse(model.openActivityURL(route.url))
        XCTAssertNil(model.activityNavigation)
        XCTAssertEqual(model.approval?.callID, "next-action")
        XCTAssertEqual(model.approvalRecords.record(id: old.id)?.state, .pending)
    }
    func testOldScreenshotDoesNotExpireApprovalAndCanCompleteAfterConfirmation() async throws {
        let bridge = OldScreenshotBridge()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: AgentRunServices(provider: DemoProvider(), bridge: bridge))
        defer { model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("old screenshot", in: id))
        try await waitUntil { model.approval != nil }
        XCTAssertGreaterThan(try XCTUnwrap(model.approval).expiresAt.timeIntervalSinceNow, 40)
        model.approve(true)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertNil(model.approval)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        let taps = await bridge.taps
        XCTAssertEqual(taps, 1)
    }
    func testDenyAndStopRemainDistinctTerminalStates() async throws {
        let denied = try await pendingDemo(), stopped = try await pendingDemo()
        denied.approve(false); stopped.stop()
        XCTAssertEqual(denied.activitySnapshot?.state.phase, .blocked)
        XCTAssertEqual(stopped.activitySnapshot?.state.phase, .stopped)
        try await waitUntil { !denied.stopping && !stopped.stopping }
    }
}

@MainActor private final class RecordingActivityHandle: AgentActivityHandle {
    var isActive = true
    var updates: [AgentActivityAttributes.Phase] = []
    var states: [AgentActivityAttributes.ContentState] = []
    var staleDates: [Date?] = []
    var ended: [AgentActivityAttributes.Phase] = []
    var alerts = 0
    var holdCompletion = false
    private var completion: CheckedContinuation<Void, Never>?
    var completionPending: Bool { completion != nil }
    func releaseCompletion() {
        let pending = completion; completion = nil; holdCompletion = false
        pending?.resume()
    }
    func update(_ content: ActivityContent<AgentActivityAttributes.ContentState>, alert: AlertConfiguration?) async {
        updates.append(content.state.phase); states.append(content.state); staleDates.append(content.staleDate)
        if alert != nil { alerts += 1 }
        if content.state.phase == .completed, holdCompletion {
            await withCheckedContinuation { completion = $0 }
        }
    }
    func end(_ content: ActivityContent<AgentActivityAttributes.ContentState>, dismissAt: Date) async {
        ended.append(content.state.phase); isActive = false
    }
}

private actor OldScreenshotBridge: DeviceBridge {
    private let demo = DemoBridge()
    private(set) var taps = 0
    func screenshot() async throws -> FrameImage {
        let frame = try await demo.screenshot()
        return FrameImage(id: frame.id, png: frame.png, width: frame.width, height: frame.height,
                          capturedAt: Date().addingTimeInterval(-3_600), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1 }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { XCTFail("Unexpected drag") }
    func stop() async { await demo.stop() }
}
