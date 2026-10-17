import Foundation

@MainActor final class TaskStore {
    private let file: URL
    init() throws {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var f = folder; try f.setResourceValues(resource)
        file = folder.appendingPathComponent("tasks.json")
    }
    func load() throws -> [TaskRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var records = try JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: file))
        for i in records.indices where records[i].phase == .running || records[i].phase == .awaitingApproval {
            records[i].phase = .interrupted; records[i].log(String(localized: "The previous run was interrupted. Queued actions will not be resumed."))
        }
        return Array(records.prefix(20))
    }
    func save(_ records: [TaskRecord]) throws {
        let data = try JSONEncoder().encode(Array(records.prefix(20)))
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
