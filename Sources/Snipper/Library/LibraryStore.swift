import Foundation
import Observation
import SnipperCore

struct ImportSummary: Sendable {
    var added = 0
    var updated = 0
    var unchanged = 0
    var ids: [UUID] = []

    var total: Int { added + updated + unchanged }

    var message: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) new") }
        if updated > 0 { parts.append("\(updated) updated") }
        if unchanged > 0 { parts.append("\(unchanged) already saved") }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: " · ")
    }
}

/// The in-memory library, mirrored to SQLite. All mutations happen on the main actor and
/// are written to disk in order on a background chain.
@MainActor
@Observable
final class LibraryStore {
    /// Newest first.
    private(set) var snips: [Snip] = []
    /// Bumped on every change; cheap to observe.
    private(set) var revision = 0
    private(set) var isLoaded = false
    private(set) var loadError: String? = nil

    @ObservationIgnored let database: SnipDatabase
    @ObservationIgnored let media: MediaStore
    @ObservationIgnored private var position: [UUID: Int] = [:]
    @ObservationIgnored private var byExternalID: [String: UUID] = [:]
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private var listeners: [(LibraryChange) -> Void] = []

    init(database: SnipDatabase, media: MediaStore) {
        self.database = database
        self.media = media
    }

    func load() async {
        do {
            let loaded = try await database.loadAll()
            snips = loaded
            reindex()
            isLoaded = true
            notify(.reloaded)
        } catch {
            loadError = String(describing: error)
            isLoaded = true
            logger.error("Loading the library failed: \(String(describing: error), privacy: .public)")
        }
    }

    func observe(_ listener: @escaping (LibraryChange) -> Void) {
        listeners.append(listener)
    }

    // MARK: Reading

    func snip(_ id: UUID) -> Snip? {
        position[id].map { snips[$0] }
    }

    func snip(externalID: String) -> Snip? {
        byExternalID[externalID].flatMap(snip)
    }

    func contains(externalID: String) -> Bool {
        byExternalID[externalID] != nil
    }

    var tagCounts: [TagCount] {
        var counts: [String: Int] = [:]
        for snip in snips { for tag in snip.tags { counts[tag, default: 0] += 1 } }
        return counts.map { TagCount(tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    func count(of kind: SnipKind) -> Int {
        snips.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    // MARK: Writing

    /// Adds a snip, or merges it into the existing snip with the same external ID.
    @discardableResult
    func add(_ incoming: Snip) -> (snip: Snip, isNew: Bool) {
        if let key = incoming.externalID, let existingID = byExternalID[key], let existing = snip(existingID) {
            let merged = SnipMerger.merge(existing: existing, incoming: incoming)
            if merged != existing { replace(merged) }
            return (merged, false)
        }
        var snip = incoming
        if position[snip.id] != nil { snip.id = UUID() }
        snips.insert(snip, at: insertionIndex(for: snip))
        reindex()
        persist([snip])
        notify(.added([snip.id]))
        return (snip, true)
    }

    /// Adds many snips at once (imports), merging duplicates.
    func addMany(_ incoming: [Snip]) -> ImportSummary {
        var summary = ImportSummary()
        var changed: [Snip] = []
        var newIDs: [UUID] = []

        for item in incoming {
            if let key = item.externalID, let existingID = byExternalID[key], let index = position[existingID] {
                let merged = SnipMerger.merge(existing: snips[index], incoming: item)
                if merged != snips[index] {
                    snips[index] = merged
                    changed.append(merged)
                    summary.updated += 1
                } else {
                    summary.unchanged += 1
                }
                summary.ids.append(existingID)
            } else {
                var snip = item
                if position[snip.id] != nil { snip.id = UUID() }
                snips.append(snip)
                position[snip.id] = snips.count - 1
                // Registered right away so duplicates later in the same batch merge into it.
                if let key = snip.externalID { byExternalID[key] = snip.id }
                changed.append(snip)
                newIDs.append(snip.id)
                summary.added += 1
                summary.ids.append(snip.id)
            }
        }
        guard !changed.isEmpty else { return summary }
        snips.sort { $0.savedAt > $1.savedAt }
        reindex()
        persist(changed)
        notify(newIDs.isEmpty ? .updated(changed.map(\.id)) : .added(newIDs))
        return summary
    }

    func update(_ snip: Snip) {
        guard position[snip.id] != nil else { return }
        var s = snip
        s.updatedAt = Date()
        replace(s)
    }

    /// Applies `body` to the snip with `id` and saves it if anything changed.
    func mutate(_ id: UUID, _ body: (inout Snip) -> Void) {
        guard let index = position[id] else { return }
        var s = snips[index]
        body(&s)
        guard s != snips[index] else { return }
        s.updatedAt = Date()
        replace(s)
    }

    func delete(_ ids: [UUID]) {
        let set = Set(ids)
        let removed = snips.filter { set.contains($0.id) }
        guard !removed.isEmpty else { return }
        snips.removeAll { set.contains($0.id) }
        reindex()
        let removedIDs = removed.map(\.id)
        enqueue { try await $0.delete(ids: removedIDs) }
        let files = removed.flatMap { $0.media.compactMap(\.localFile) }
        let store = media
        Task.detached(priority: .utility) { store.delete(files) }
        for file in files { ImageLoader.shared.evict(localFile: file) }
        notify(.removed(removedIDs))
    }

    /// Waits until all pending writes reached the database.
    func flush() async {
        await writeChain?.value
    }

    // MARK: Internals

    private func replace(_ snip: Snip) {
        guard let index = position[snip.id] else { return }
        let savedAtChanged = snips[index].savedAt != snip.savedAt
        snips[index] = snip
        if savedAtChanged {
            snips.sort { $0.savedAt > $1.savedAt }
        }
        reindex()
        persist([snip])
        notify(.updated([snip.id]))
    }

    private func insertionIndex(for snip: Snip) -> Int {
        snips.firstIndex { $0.savedAt <= snip.savedAt } ?? snips.count
    }

    private func reindex() {
        position.removeAll(keepingCapacity: true)
        byExternalID.removeAll(keepingCapacity: true)
        for (i, s) in snips.enumerated() {
            position[s.id] = i
            if let key = s.externalID { byExternalID[key] = s.id }
        }
        revision &+= 1
    }

    private func persist(_ changed: [Snip]) {
        enqueue { try await $0.upsert(changed) }
    }

    private func enqueue(_ operation: @escaping @Sendable (SnipDatabase) async throws -> Void) {
        let previous = writeChain
        let db = database
        writeChain = Task {
            await previous?.value
            do {
                try await operation(db)
            } catch {
                logger.error("Database write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func notify(_ change: LibraryChange) {
        for listener in listeners { listener(change) }
    }
}

struct TagCount: Identifiable, Hashable {
    let tag: String
    let count: Int
    var id: String { tag }
}

enum LibraryChange {
    case reloaded
    case added([UUID])
    case updated([UUID])
    case removed([UUID])
}
