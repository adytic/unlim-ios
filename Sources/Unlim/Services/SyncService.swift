import Foundation

/// Sync options, mirroring Android SyncOptions.
enum SyncOption: String, CaseIterable, Sendable {
    case imageLabeling = "ImageLabeling"
    case faceRecognition = "FaceRecognition"
    case autoAlbum = "AutoAlbum"

    var userDefaultsKey: String {
        "SyncOptions.\(rawValue)"
    }
}

/// Mirrors Android SyncService / SyncServiceImpl (ANALYSIS-Storage-Sync.md §4).
/// Queue state lives in SyncStore (JSON); pause/resume/cancel and the
/// "Synced" set mirror the Android SharedPreferences keys
/// ("SyncQueue.Paused", "SyncOptions.FoldersToSync", "Synced").
///
/// NOTE: Android's beginSyncManager was not decompiled, so the drain loop
/// below is the iOS reconstruction: take IN_QUEUE rows FIFO, run
/// syncToFiles / syncToGallery, stop when paused, cancelled, or empty.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var isPaused = false
    @Published private(set) var syncPrompt: [SyncPromptAsset] = []
    @Published private(set) var foldersToSync: Set<String> = []
    @Published private(set) var imageLabelingEnabled = false
    @Published private(set) var faceRecognitionEnabled = false
    @Published private(set) var autoAlbumEnabled = false
    @Published private(set) var queue: [SyncStoreModel] = []

    /// The Saved Messages chat id (== user id), set by AppState after getMe.
    /// Used to ignore updateMessageSendSucceeded events from other chats.
    var storageChatId: Int64?

    private let client: TelegramClient
    private let store: SyncStore
    private let defaults: UserDefaults
    private var drainTask: Task<Void, Never>?
    private var subscribedToStore = false

    init(client: TelegramClient, store: SyncStore = .shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.store = store
        self.defaults = defaults
    }

    func initialize() async {
        await store.load()
        isPaused = defaults.bool(forKey: "SyncQueue.Paused")
        foldersToSync = Set(defaults.stringArray(forKey: "SyncOptions.FoldersToSync") ?? [])
        imageLabelingEnabled = defaults.bool(forKey: SyncOption.imageLabeling.userDefaultsKey)
        faceRecognitionEnabled = defaults.bool(forKey: SyncOption.faceRecognition.userDefaultsKey)
        autoAlbumEnabled = defaults.bool(forKey: SyncOption.autoAlbum.userDefaultsKey)
        queue = await store.getAll()
        if !subscribedToStore {
            subscribedToStore = true
            Task { [weak self] in
                guard let self else { return }
                for await models in await self.store.changes {
                    self.queue = models.filter { FileManager.default.fileExists(atPath: $0.path) }
                }
            }
        }
        await refreshSyncPrompt()
    }

    // MARK: - Controls (mirrors Android pause/resume/cancelAll)

    func pause() {
        isPaused = true
        defaults.set(true, forKey: "SyncQueue.Paused")
        drainTask?.cancel()
    }

    func resume() {
        isPaused = false
        defaults.set(false, forKey: "SyncQueue.Paused")
        startDrain()
    }

    /// Android cancelAll clears the whole SyncQueue preference: every
    /// queued row is dropped.
    func cancelAll() {
        drainTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            for model in await self.store.getAll() {
                await self.store.delete(model)
            }
        }
    }

    func setOption(_ option: SyncOption, enabled: Bool) {
        defaults.set(enabled, forKey: option.userDefaultsKey)
        switch option {
        case .imageLabeling: imageLabelingEnabled = enabled
        case .faceRecognition: faceRecognitionEnabled = enabled
        case .autoAlbum: autoAlbumEnabled = enabled
        }
    }

    func updateFoldersToSync(_ folders: Set<String>) {
        foldersToSync = folders
        defaults.set(Array(folders), forKey: "SyncOptions.FoldersToSync")
        Task { await refreshSyncPrompt() }
    }

    // MARK: - Enqueue

    /// Mirrors Android uploadToFiles: every file becomes an IN_QUEUE row,
    /// then the drain loop picks it up.
    func uploadToFiles(storageId: Int64, files: [URL], toPath: String, toPathReadable: String) async {
        guard !files.isEmpty else { return }
        for file in files {
            let model = SyncStoreModel(
                storageId: storageId,
                type: .file,
                state: .inQueue,
                path: file.path,
                remoteFolderPath: toPath,
                remoteFolderPathReadable: toPathReadable
            )
            await store.store(model)
        }
        startDrain()
    }

    /// Gallery uploads: one IN_QUEUE row per exported file, type .gallery.
    /// The drain loop sends them through syncToGallery.
    func uploadToGallery(storageId: Int64, paths: [String]) async {
        guard !paths.isEmpty else { return }
        for path in paths {
            let model = SyncStoreModel(
                storageId: storageId,
                type: .gallery,
                state: .inQueue,
                path: path,
                remoteFolderPath: "0/",
                remoteFolderPathReadable: "0/"
            )
            await store.store(model)
        }
        startDrain()
    }

    // MARK: - Drain loop

    func startDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    /// Starts the drain loop and waits until it finishes (queue empty,
    /// paused, or cancelled). Used by BackgroundScheduler.
    func drainUntilIdle() async {
        startDrain()
        await drainTask?.value
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            if isPaused { break }
            guard let next = await store.getAll().first(where: { $0.state == .inQueue }) else { break }
            if next.type == .gallery {
                await syncToGallery(next)
            } else {
                await syncToFiles(next)
            }
        }
        drainTask = nil
    }

    // MARK: - Send

    private func syncToFiles(_ model: SyncStoreModel) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value ?? 0
        if ChunkingService.needsChunking(fileSize: size) {
            await uploadToFileByChunk(model)
            return
        }
        var updated = model
        updated.state = .preProcessing
        await store.store(updated)
        do {
            let fileURL = URL(fileURLWithPath: model.path)
            let caption = CaptionBuilder.createFileCaption(path: model.remoteFolderPath, chunkId: "")
            let sent = try await sendDocument(model: updated, fileURL: fileURL, thumbnailSourceURL: fileURL, caption: caption)
            var syncing = updated
            syncing.state = .syncing
            syncing.messageId = sent.id
            await store.store(syncing)
        } catch {
            var failed = updated
            failed.state = .failed
            await store.store(failed)
        }
    }

    /// Gallery files use the same document send for now. Android's
    /// syncToGallery was not decompiled, and its gallery caption needs the
    /// MEDIASEARCHUNIQID constant plus ML labels/face ids (see
    /// CaptionBuilder.galleryFileCaption). Until those are wired, gallery
    /// rows are sent with the plain folder caption so they stay readable
    /// by the Android/web clients.
    private func syncToGallery(_ model: SyncStoreModel) async {
        await syncToFiles(model)
    }

    /// Mirrors Android uploadToFileByChunk: split the file, then send one
    /// message per chunk with the chunk caption.
    private func uploadToFileByChunk(_ model: SyncStoreModel) async {
        let fileURL = URL(fileURLWithPath: model.path)
        var updated = model
        updated.state = .preProcessing
        await store.store(updated)

        let tempDir = AppDirectories.tempFolder(for: .files)
        let chunks: [URL]
        do {
            chunks = try ChunkingService.splitFile(at: fileURL, tempDirectory: tempDir) { _ in }
        } catch {
            var failed = updated
            failed.state = .failed
            await store.store(failed)
            return
        }

        let totalSize = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value ?? 0
        let groupId = UUID().uuidString
        // Android deletes the original row before uploading the chunks.
        await store.delete(updated)

        for (index, chunkURL) in chunks.enumerated() {
            if Task.isCancelled { return }
            let chunkId = chunks.count > 1
                ? CaptionBuilder.chunkCaption(groupId: groupId, index: index, totalSize: totalSize)
                : ""
            // Android stores both folder fields as the *readable* path for
            // chunk rows.
            let chunkModel = SyncStoreModel(
                storageId: model.storageId,
                type: model.type,
                state: .preProcessing,
                path: chunkURL.path,
                remoteFolderPath: model.remoteFolderPathReadable,
                remoteFolderPathReadable: model.remoteFolderPathReadable,
                isChunk: chunks.count > 1
            )
            await store.store(chunkModel)
            do {
                // Caption path comes from the ORIGINAL model (or "0/").
                let caption = CaptionBuilder.createFileCaption(
                    path: model.remoteFolderPath.isEmpty ? "0/" : model.remoteFolderPath,
                    chunkId: chunkId
                )
                let sent = try await sendDocument(
                    model: chunkModel,
                    fileURL: chunkURL,
                    thumbnailSourceURL: fileURL,
                    caption: caption
                )
                var syncing = chunkModel
                syncing.state = .syncing
                syncing.messageId = sent.id
                await store.store(syncing)
            } catch {
                var failed = chunkModel
                failed.state = .failed
                await store.store(failed)
            }
        }
    }

    private func sendDocument(model: SyncStoreModel, fileURL: URL, thumbnailSourceURL: URL, caption: String) async throws -> ChatMessage {
        let mime = ThumbnailService.mimeType(for: fileURL)
        let thumbnail = ThumbnailService.thumbnail(for: thumbnailSourceURL, mimeType: mime, in: AppDirectories.tempFolder(for: .files))
        return try await client.sendDocument(
            chatId: model.storageId,
            threadId: 0,
            localPath: fileURL.path,
            thumbnailPath: thumbnail == thumbnailSourceURL ? nil : thumbnail.path,
            caption: caption
        )
    }

    // MARK: - Send confirmation

    /// Called from AppState when the update bus delivers
    /// `.messageSendSucceeded`. Mirrors Android SyncServiceImpl.onResult:
    /// find the row by local path, then old message id, then final message
    /// id — and mark it SYNCED with the final message id.
    func handleMessageSendSucceeded(oldMessageId: Int64, message: ChatMessage) async {
        if let storageChatId, message.chatId != storageChatId { return }
        guard case .document = message.content else { return }
        var row: SyncStoreModel?
        if case .document(let file, _) = message.content, let localPath = file.localPath {
            row = await store.get(path: localPath)
        }
        row = row ?? await store.get(messageId: oldMessageId) ?? await store.get(messageId: message.id)
        guard var found = row else { return }
        found.state = .synced
        found.messageId = message.id
        await store.store(found)
    }

    // MARK: - Sync prompt

    /// Mirrors Android getNotSyncedGallery(): photos in the chosen folders
    /// minus assets already recorded in the "Synced" set.
    func refreshSyncPrompt() async {
        let synced = Set(defaults.dictionary(forKey: "Synced")?.keys ?? [])
        syncPrompt = await GalleryScanner.notSyncedAssets(folders: foldersToSync, syncedIdentifiers: synced)
    }

    /// Mirrors Android cancelSyncPrompt(): mark every not-yet-synced asset
    /// as synced and clear the prompt.
    func cancelSyncPrompt() {
        var synced = defaults.dictionary(forKey: "Synced") ?? [:]
        for asset in syncPrompt {
            synced[asset.localIdentifier] = true
        }
        defaults.set(synced, forKey: "Synced")
        syncPrompt = []
    }
}
