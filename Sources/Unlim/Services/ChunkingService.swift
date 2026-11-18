import Foundation

/// File splitting and joining, mirroring Android
/// StorageServiceImpl.copyTempFile + SyncServiceImpl.uploadToFileByChunk
/// (ANALYSIS-Storage-Sync.md §1).
enum ChunkingService {
    /// StorageServiceImplKt.sizeOfChunk = 2_040_109_465 bytes (~1.9 GB),
    /// just under Telegram's 2 GB per-file limit.
    static let sizeOfChunk: Int64 = 2_040_109_465
    /// Copy buffer size used by Android copyTempFile.
    static let copyBufferSize = 8_192

    static func needsChunking(fileSize: Int64) -> Bool {
        fileSize >= sizeOfChunk
    }

    /// Splits `fileURL` into chunks under `tempDirectory`.
    /// Files at or below the chunk size are returned unchanged (single chunk
    /// = the original file, exactly like Android's branch).
    /// For larger files, chunk 0 keeps the original file name; chunk i
    /// (i >= 1) is named "<i-1><name>" — the first split file is "0<name>",
    /// the second "1<name>", and so on, exactly like Android copyTempFile.
    /// Returns chunk URLs in upload order. Progress is 0...1.
    /// Like Android, a chunk is closed when its length reaches sizeOfChunk
    /// *before* the next block is written, so a chunk can exceed the limit
    /// by at most one buffer (8 KB).
    static func splitFile(
        at fileURL: URL,
        tempDirectory: URL,
        progress: @escaping (Double) -> Void
    ) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let totalSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard totalSize > sizeOfChunk else {
            progress(1)
            return [fileURL]
        }

        let name = fileURL.lastPathComponent
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        var chunks: [URL] = []
        var currentURL = tempDirectory.appendingPathComponent(name)
        var output = try openForWriting(currentURL)
        var currentLength: Int64 = 0
        var splitIndex = 0
        var bytesCopied: Int64 = 0

        while true {
            guard let data = try input.read(upToCount: copyBufferSize), !data.isEmpty else {
                break
            }
            if currentLength >= sizeOfChunk {
                try output.close()
                chunks.append(currentURL)
                currentURL = tempDirectory.appendingPathComponent("\(splitIndex)\(name)")
                output = try openForWriting(currentURL)
                splitIndex += 1
                currentLength = 0
            }
            try output.write(contentsOf: data)
            currentLength += Int64(data.count)
            bytesCopied += Int64(data.count)
            progress(Double(bytesCopied) / Double(totalSize))
        }
        try output.close()
        chunks.append(currentURL)
        return chunks
    }

    /// Joins chunk files (in order) into one file at `destination`.
    /// Used when downloading a chunked file (Android saveChunks).
    static func joinChunks(
        _ chunks: [URL],
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        let total = chunks.reduce(Int64(0)) { sum, url in
            sum + ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let output = try openForWriting(destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        for chunk in chunks {
            let input = try FileHandle(forReadingFrom: chunk)
            defer { try? input.close() }
            while let data = try input.read(upToCount: copyBufferSize), !data.isEmpty {
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                progress(total > 0 ? Double(copied) / Double(total) : 1)
            }
        }
    }

    private static func openForWriting(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return try FileHandle(forWritingTo: url)
    }
}
