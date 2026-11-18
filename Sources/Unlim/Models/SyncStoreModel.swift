import Foundation

/// Mirrors Android `SyncStoreModel` (com.kratosle.unlim.core.services.sync).
/// One row = one file (or one chunk) waiting to be, or being, uploaded.
/// Persisted as JSON by `SyncStore`, keyed by local `path`.
enum SyncStoreState: String, Codable, CaseIterable, Sendable {
    case inQueue = "IN_QUEUE"
    case preProcessing = "PRE_PROCESSING"
    case syncing = "SYNCING"
    case synced = "SYNCED"
    /// Local-only extension: Android has no FAILED state. A row lands here
    /// after a terminal send error so the queue can surface it instead of
    /// retrying forever. (Android's beginSyncManager was not decompiled.)
    case failed = "FAILED"
}

enum SyncStoreType: String, Codable, Sendable {
    case file = "FILE"
    case gallery = "GALLERY"
}

struct SyncStoreModel: Codable, Identifiable, Equatable, Sendable {
    var storageId: Int64
    var type: SyncStoreType
    var state: SyncStoreState
    var path: String
    var remoteFolderPath: String
    var remoteFolderPathReadable: String
    var messageId: Int64?
    var time: Int64
    var isChunk: Bool

    var id: String { path }

    init(
        storageId: Int64,
        type: SyncStoreType,
        state: SyncStoreState,
        path: String,
        remoteFolderPath: String,
        remoteFolderPathReadable: String,
        messageId: Int64? = nil,
        time: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        isChunk: Bool = false
    ) {
        self.storageId = storageId
        self.type = type
        self.state = state
        self.path = path
        self.remoteFolderPath = remoteFolderPath
        self.remoteFolderPathReadable = remoteFolderPathReadable
        self.messageId = messageId
        self.time = time
        self.isChunk = isChunk
    }
}
