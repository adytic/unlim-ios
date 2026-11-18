import Foundation

/// Caption protocol — must be byte-identical to Android or files uploaded
/// from iOS will not be recognised by the Android/web clients (and vice
/// versa). Source: ANALYSIS-Storage-Sync.md §2 (jadx of
/// StorageServiceImpl / SyncHelperKt / ContentServiceImplKt).
enum CaptionBuilder {
    /// ContentServiceImplKt.CHUNKLABEL
    static let chunkLabel = "1hbas621gs"
    /// ContentServiceImplKt.CHUNKTOTALSIZELABEL
    static let chunkTotalSizeLabel = "28f7sdn2gh3r"
    /// ContentServiceImplKt.FAVORITE
    static let favoriteLabel = "u7n5l1i9m4c2l0o3u1d5"
    /// ContentServiceImplKt.CREATENEWALBUM
    static let createNewAlbumKey = "CREATENEWALBUMKEY"
    /// ContentServiceImplKt.LABELPREFIXANDSUFFIX
    static let labelPrefixAndSuffix = "--lbl--"
    /// ContentServiceImplKt.GEO
    static let geoPrefix = "--latlng["

    /// SyncHelperKt.createFileCaption(path, chunkId) = "dir--<path>--/dir <chunkId>"
    static func createFileCaption(path: String, chunkId: String) -> String {
        "dir--\(path)--/dir \(chunkId)"
    }

    /// Chunk id embedded in the caption for a multi-chunk file:
    /// CHUNKLABEL + uuid + "[i]" + CHUNKLABEL + CHUNKTOTALSIZELABEL
    /// + totalBytes + CHUNKTOTALSIZELABEL.
    static func chunkCaption(groupId: String, index: Int, totalSize: Int64) -> String {
        "\(chunkLabel)\(groupId)[\(index)]\(chunkLabel)\(chunkTotalSizeLabel)\(totalSize)\(chunkTotalSizeLabel)"
    }

    /// Parses "dir--<path>--/dir <chunkId>" back into its parts.
    /// Returns nil when the caption is not a file caption at all.
    static func parseFileCaption(_ caption: String) -> (path: String, chunkId: String)? {
        guard caption.hasPrefix("dir--"),
              let separator = caption.range(of: "--/dir ")
        else { return nil }
        let path = String(caption[caption.index(caption.startIndex, offsetBy: 5)..<separator.lowerBound])
        let chunkId = String(caption[separator.upperBound...])
        return (path, chunkId)
    }

    /// Parses a chunk id into group UUID, chunk index and total file size.
    /// Layout: <label><uuid>[<i>]<label><totalLabel><total><totalLabel>
    static func parseChunkCaption(_ chunkId: String) -> ChunkInfo? {
        guard chunkId.hasPrefix(chunkLabel) else { return nil }
        var rest = chunkId.dropFirst(chunkLabel.count)
        guard let open = rest.firstIndex(of: "["),
              let close = rest.firstIndex(of: "]"),
              let index = Int(rest[rest.index(after: open)..<close])
        else { return nil }
        let groupId = String(rest[..<open])
        rest = rest[rest.index(after: close)...]
        guard rest.hasPrefix(chunkLabel) else { return nil }
        rest = rest.dropFirst(chunkLabel.count)
        guard rest.hasPrefix(chunkTotalSizeLabel) else { return nil }
        rest = rest.dropFirst(chunkTotalSizeLabel.count)
        guard rest.hasSuffix(chunkTotalSizeLabel) else { return nil }
        rest = rest.dropLast(chunkTotalSizeLabel.count)
        guard let total = Int64(rest) else { return nil }
        return ChunkInfo(groupId: groupId, index: index, totalSize: total)
    }

    /// Gallery caption (SyncHelperKt.getGalleryFileCaption):
    /// " -u-t-s-<originalDate>-e-n-d-  <hash>  <uniqueId> <duration>
    ///  <labels> <faceIds> <albumId> <location>"
    /// - Video duration: " -dr-<ms>-drn-"
    /// - Location: "--latlng[<lat>,<lon>]--"
    /// - Labels are wrapped in "--lbl--" (see labelPrefixAndSuffix).
    /// TODO: the MEDIASEARCHUNIQID constant value was not captured in the
    /// jadx pass — read it from ContentServiceImplKt and pass it here.
    /// Until then, gallery uploads use createFileCaption instead (see
    /// SyncService.syncToGallery).
    static func galleryFileCaption(
        originalDate: Int64,
        fileHash: Int,
        mediaSearchUniqueId: String,
        durationMs: Int64?,
        labels: String,
        faceIds: String,
        albumId: String,
        latitude: Double?,
        longitude: Double?
    ) -> String {
        var caption = " -u-t-s-\(originalDate)-e-n-d-  \(fileHash)  \(mediaSearchUniqueId) "
        if let durationMs {
            caption += " -dr-\(durationMs)-drn-"
        }
        caption += " \(labels) \(faceIds) \(albumId) "
        if let latitude, let longitude {
            caption += "--latlng[\(latitude),\(longitude)]--"
        }
        return caption
    }

    /// Splits a list of messages into chunk groups and single files.
    /// A message belongs to a group when its caption carries a chunk id.
    static func groupMessages(_ messages: [ChatMessage]) -> (groups: [ChunkGroup], singles: [ChatMessage]) {
        var byGroup: [String: (totalSize: Int64, chunks: [(Int, ChatMessage)])] = [:]
        var singles: [ChatMessage] = []
        for message in messages {
            guard case .document(_, let caption) = message.content,
                  let parsed = parseFileCaption(caption),
                  let info = parseChunkCaption(parsed.chunkId)
            else {
                singles.append(message)
                continue
            }
            byGroup[info.groupId, default: (info.totalSize, [])].chunks.append((info.index, message))
        }
        let groups = byGroup.map { groupId, value in
            ChunkGroup(
                groupId: groupId,
                totalSize: value.totalSize,
                chunks: value.chunks.sorted { $0.0 < $1.0 }.map { $0.1 }
            )
        }.sorted { $0.groupId < $1.groupId }
        return (groups, singles)
    }
}

struct ChunkInfo: Equatable, Sendable {
    let groupId: String
    let index: Int
    let totalSize: Int64
}

/// One logical file reassembled from its chunk messages, ordered by index.
struct ChunkGroup: Sendable {
    let groupId: String
    let totalSize: Int64
    let chunks: [ChatMessage]
}
