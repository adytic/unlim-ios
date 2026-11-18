import Foundation

/// Mirrors Android SyncStorage: one JSON record per queued file, keyed by
/// local path. Android uses SharedPreferences; here it is a single JSON file
/// in Application Support, written atomically. `getAll()` only returns rows
/// whose local file still exists on disk, like Android.
actor SyncStore {
    static let shared = SyncStore()

    private let fileURL: URL
    private var models: [String: SyncStoreModel] = [:]
    private var continuations: [UUID: AsyncStream<[SyncStoreModel]>.Continuation] = [:]
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SyncQueue.json")
        }
    }

    /// Load the persisted queue into memory. Call once at startup;
    /// later calls are no-ops.
    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SyncStoreModel].self, from: data)
        else { return }
        models = decoded
    }

    /// A stream of the current queue snapshot after every change
    /// (Android's publishChanges / SharedPreferences listener).
    var changes: AsyncStream<[SyncStoreModel]> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            Task { await self?.addContinuation(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func store(_ model: SyncStoreModel) {
        models[model.path] = model
        persist()
        publish()
    }

    func delete(_ model: SyncStoreModel) {
        models.removeValue(forKey: model.path)
        persist()
        publish()
    }

    func get(path: String) -> SyncStoreModel? {
        models[path]
    }

    func get(messageId: Int64) -> SyncStoreModel? {
        models.values.first { $0.messageId == messageId }
    }

    func getAll() -> [SyncStoreModel] {
        models.values.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addContinuation(id: UUID, continuation: AsyncStream<[SyncStoreModel]>.Continuation) {
        continuations[id] = continuation
        continuation.yield(Array(models.values))
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(models) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func publish() {
        let snapshot = Array(models.values)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
