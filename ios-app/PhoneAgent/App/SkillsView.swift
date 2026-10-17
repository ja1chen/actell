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
                        NavigationLink { SkillDetailView(skill: skill) } label: {
                            VStack(alignment: .leading) { Text(skill.name); Text(skill.summary).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if store.packages.isEmpty {
                ContentUnavailableView(String(localized: "No local skills yet"), systemImage: "books.vertical")
            } else {
                Section(String(localized: "Local skills")) {
                    ForEach(store.packages) { skill in
                        Group {
                            NavigationLink { SkillDetailView(skill: skill) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(skill.name, systemImage: "book.closed").font(.headline)
                                    Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    Text(String(localized: "Version \(skill.displayVersion) · \(skill.revision.prefix(8))")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Text(String(localized: "Enable"))
                                Spacer()
                                Toggle(String(localized: "Enable"), isOn: Binding(get: { skill.enabled }, set: { value in perform { try store.setEnabled(value, id: skill.id) } }))
                                    .labelsHidden().fixedSize().accessibilityLabel(String(localized: "Enable \(skill.name)"))
                                    .accessibilityIdentifier("enableSkill-" + skill.id.uuidString)
                                Button(String(localized: "Delete"), role: .destructive) { deleting = skill }.buttonStyle(.borderless)
                                    .accessibilityIdentifier("deleteSkill-" + skill.id.uuidString)
                            }.disabled(model.hasBusySessions)
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
        .alert(String(localized: "Delete this skill version?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(String(localized: "Cancel"), role: .cancel) { deleting = nil }
            Button(String(localized: "Delete"), role: .destructive) { if let deleting { perform { try store.remove(deleting.id) } }; deleting = nil }
        } message: { Text(String(localized: "Only this version's copy in the app will be deleted. Original import files and other versions are kept. You can import it again later.")) }
    }
    private func perform(_ operation: () throws -> Void) {
        guard !model.hasBusySessions else { status = String(localized: "Stop the current task before changing skills"); return }
        do { try operation() }
        catch { status = error.localizedDescription }
    }
}

private struct SkillDetailView: View {
    let skill: SkillPackage
    @State private var resource = "SKILL.md"
    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Document"), selection: $resource) {
                ForEach(skill.resources, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).padding(.horizontal)
            ScrollView {
                Text(skill.documents[resource] ?? String(localized: "This version does not contain this document")).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.accessibilityIdentifier("skillDocument")
        }.navigationTitle(skill.name).navigationBarTitleDisplayMode(.inline)
    }
}
