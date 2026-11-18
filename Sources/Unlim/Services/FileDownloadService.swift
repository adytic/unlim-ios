import Foundation

/// Downloads, mirroring Android FileServiceImpl +
/// StorageServiceImpl.downloadFile / saveChunks.
/// Downloads run through TDLib (downloadFile + updateFile progress), never
/// plain HTTP. Chunked files are re-joined with ChunkingService, then saved
/// under Documents/Unlim/Media or Documents/Unlim/Files (Android used
/// Download/Unlim/Media|Files via MediaStore).
actor FileDownloadService {
    private let client: TelegramClient
    private let bus: UpdateBus

    init(client: TelegramClient, bus: UpdateBus) {
        self.client = client
        self.bus = bus
    }

    enum DownloadError: LocalizedError {
        case noDocument
        case incomplete
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noDocument: return "This message has no downloadable document."
            case .incomplete: return "The download finished but the file is not complete on disk."
            case .cancelled: return "The download was cancelled."
            }
        }
    }

    /// Downloads the document of one message into TDLib's files directory
    /// and returns the TDLib-local file URL. Progress (0...1) is delivered
    /// from updateFile while the download runs; it is called off the main
    /// actor, so the caller must hop to the main actor to touch UI.
    func downloadDocument(_ message: ChatMessage, progress: @escaping (Double) -> Void) async throws -> URL {
        guard case .document(let file, _) = message.content else { throw DownloadError.noDocument }
        if file.isDownloadingCompleted, let path = file.localPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let stream = bus.subscribe()
        let progressTask = Task {
            for await update in stream {
                guard case .fileUpdated(let updated) = update, updated.id == file.id else { continue }
                progress(Double(updated.downloadedSize) / Double(max(updated.size, 1)))
                if updated.isDownloadingCompleted { break }
            }
        }
        defer { progressTask.cancel() }
        _ = try await client.downloadFile(fileId: file.id)
        let final = try await client.getFile(fileId: file.id)
        guard final.isDownloadingCompleted, let path = final.localPath, !path.isEmpty else {
            throw DownloadError.incomplete
        }
        return URL(fileURLWithPath: path)
    }

    /// Downloads one message; if it belongs to a chunk group (see
    /// CaptionBuilder.groupMessages), downloads every sibling chunk from
    /// `allMessages` and joins them into one file, then saves it.
    /// Returns the saved file URL under Documents/Unlim.
    func downloadMessage(_ message: ChatMessage, allMessages: [ChatMessage], progress: @escaping (Double) -> Void) async throws -> URL {
        let (groups, _) = CaptionBuilder.groupMessages(allMessages)
        if let group = groups.first(where: { $0.chunks.contains(where: { $0.id == message.id }) }) {
            return try await downloadChunkGroup(group, progress: progress)
        }
        let localURL = try await downloadDocument(message, progress: progress)
        let fileName = fileName(of: message) ?? localURL.lastPathComponent
        return try saveDownloadedFile(localURL, fileName: fileName, to: .files)
    }

    private func downloadChunkGroup(_ group: ChunkGroup, progress: @escaping (Double) -> Void) async throws -> URL {
        let total = group.chunks.count
        var downloaded: [URL] = []
        for (index, chunkMessage) in group.chunks.enumerated() {
            if Task.isCancelled { throw DownloadError.cancelled }
            let url = try await downloadDocument(chunkMessage) { fraction in
                progress((Double(index) + fraction) / Double(max(total, 1)))
            }
            downloaded.append(url)
        }
        // Chunk 0 keeps the original file name (see ChunkingService).
        let fileName = fileName(of: group.chunks.first) ?? "download"
        let joinedURL = AppDirectories.tempFolder(for: .files).appendingPathComponent(fileName)
        try ChunkingService.joinChunks(downloaded, to: joinedURL) { fraction in
            progress(fraction)
        }
        return try saveDownloadedFile(joinedURL, fileName: fileName, to: .files)
    }

    private func fileName(of message: ChatMessage?) -> String? {
        guard let message, case .document(let file, _) = message.content else { return nil }
        return file.fileName
    }

    /// Copies a downloaded file into Documents/Unlim/<Media|Files>, which
    /// the Files app shows. Overwrites an existing file with the same name.
    func saveDownloadedFile(_ url: URL, fileName: String, to location: StorageLocation) throws -> URL {
        let dir = AppDirectories.savedFilesDirectory(for: location)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
