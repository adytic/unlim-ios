import Foundation
import Photos

/// Photo-library scanning, the iOS equivalent of Android's listImages() /
/// getNotSyncedGallery().
///
/// Android scans DCIM folders on disk. iOS has no DCIM folders, so a
/// "folder to sync" here is a Photos album name chosen by the user, and a
/// "file" is a PHAsset. The "Synced" set is keyed by the asset's
/// localIdentifier (Android keyed it by file path).
struct SyncPromptAsset: Identifiable, Sendable {
    let asset: PHAsset

    var id: String { asset.localIdentifier }
    var localIdentifier: String { asset.localIdentifier }
    var creationDate: Date? { asset.creationDate }
    var isVideo: Bool { asset.mediaType == .video }
    var pixelSize: String { "\(asset.pixelWidth)×\(asset.pixelHeight)" }
}

enum GalleryScanner {
    /// Assets (photos + videos) in the named albums, newest first.
    static func assets(inAlbums albumNames: Set<String>) -> [PHAsset] {
        guard !albumNames.isEmpty else { return [] }
        var result: [PHAsset] = []
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let name = collection.localizedTitle, albumNames.contains(name) else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            assets.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video {
                    result.append(asset)
                }
            }
        }
        return result
    }

    /// Assets in the chosen albums that are not in the synced set.
    static func notSyncedAssets(folders: Set<String>, syncedIdentifiers: Set<String>) -> [SyncPromptAsset] {
        assets(inAlbums: folders)
            .filter { !syncedIdentifiers.contains($0.localIdentifier) }
            .map { SyncPromptAsset(asset: $0) }
    }

    /// Exports an asset's original resource data to a temp file for upload.
    /// Prefers the photo/video resource; falls back to the first resource
    /// (e.g. Live Photo stills are not paired here — first pass only).
    static func exportAsset(_ asset: PHAsset, to directory: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto })
            ?? resources.first
        else {
            throw NSError(domain: "GalleryScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "No exportable resource for this asset."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(resource.originalFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: nil
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
