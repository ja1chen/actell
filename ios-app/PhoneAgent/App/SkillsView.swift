import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var store: SkillStore
    @State private var importing = false
    @State private var deleting: SkillPackage?
    @State private var status: String?
    var body: some View {
        List {
            if status != nil || store.warning != nil {
                Section {
                    if let status { Text(status).font(.caption).accessibilityIdentifier("skillStatus") }
                    if let warning = store.warning { Text(warning).foregroundStyle(.orange) }
                }
            }
            if !store.builtinPackages.isEmpty {
                Section(String(localized: "Built-in skills")) {
                    ForEach(store.builtinPackages) { skill in
                        skillLink(skill)
                    }
                }
            }
            if store.packages.isEmpty {
                ContentUnavailableView(String(localized: "No user skills yet"), systemImage: "books.vertical")
            } else {
                Section(String(localized: "User skills")) {
                    ForEach(store.packages) { skill in
                        skillLink(skill)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(String(localized: "Delete"), role: .destructive) { deleting = skill }
                                .accessibilityIdentifier("deleteSkill-" + skill.id.uuidString)
                                .disabled(model.hasBusySessions)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Skill")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Import"), systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(model.hasBusySessions).accessibilityIdentifier("importSkill")
            }
        }
        .task {
            while !Task.isCancelled {
                store.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            switch result {
            case .success(let url): perform {
                let before = store.packages.count
                let imported = try store.importPackage(url)
                status = before == store.packages.count ? String(localized: "This version already exists and was not imported again: \(imported.name)") : String(localized: "Imported: \(imported.name). Previous versions with the same name are kept and can be enabled or deleted separately.")
            }
            case .failure: status = String(localized: "Import did not finish. The original skill was kept. Select the file again.")
            }
        }
        .alert(String(localized: "Delete this skill?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(String(localized: "Cancel"), role: .cancel) { deleting = nil }
            Button(String(localized: "Delete"), role: .destructive) { if let deleting { perform { try store.remove(deleting.id) } }; deleting = nil }
        } message: { Text(String(localized: "This cannot be undone.")) }
    }
    private func skillLink(_ skill: SkillPackage) -> some View {
        NavigationLink { SkillDetailView(skill: skill, model: model, store: store) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(skill.name).font(.headline).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let version = skill.displayVersion { Text(version) }
                        if !skill.enabled { Text(String(localized: "(Not enabled)")) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .accessibilityIdentifier("skill-" + skill.id.uuidString)
    }
    private func perform(_ operation: () throws -> Void) {
        guard !model.hasBusySessions else { status = String(localized: "Stop the current task before changing skills"); return }
        do { try operation() }
        catch { status = error.localizedDescription }
    }
}

private struct SkillDetailView: View {
    let skill: SkillPackage
    @ObservedObject var model: AgentViewModel
    @ObservedObject var store: SkillStore
    @State private var status: String?
    @State private var resource = "SKILL.md"
    var body: some View {
        VStack(spacing: 0) {
            if let current = store.packages.first(where: { $0.id == skill.id }) {
                Toggle(String(localized: "Enable"), isOn: Binding(get: { current.enabled }, set: setEnabled))
                    .accessibilityLabel(String(localized: "Enable \(skill.name)"))
                    .accessibilityIdentifier("enableSkill-" + skill.id.uuidString)
                    .disabled(model.hasBusySessions)
                    .padding()
            }
            if let status { Text(status).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            Picker(String(localized: "Document"), selection: $resource) {
                ForEach(skill.resources, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).padding(.horizontal)
            ScrollView {
                Text(skill.documents[resource] ?? String(localized: "This version does not contain this document")).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.accessibilityIdentifier("skillDocument")
        }.navigationTitle(skill.name).navigationBarTitleDisplayMode(.inline)
    }
    private func setEnabled(_ enabled: Bool) {
        guard !model.hasBusySessions else { status = String(localized: "Stop the current task before changing skills"); return }
        do { try store.setEnabled(enabled, id: skill.id); status = nil }
        catch { status = error.localizedDescription }
    }

}
