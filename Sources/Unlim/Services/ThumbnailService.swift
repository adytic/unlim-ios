import AVFoundation
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Thumbnails for uploads, mirroring Android SyncHelperKt.getThumbnailFromFile:
/// videos get a JPEG thumbnail (quality 0.6) written under temp/thumbnails;
/// any other file is returned unchanged — TDLib then uses the file itself
/// as the thumbnail, exactly like Android does.
enum ThumbnailService {
    static func thumbnail(for fileURL: URL, mimeType: String, in tempDirectory: URL) -> URL {
        guard mimeType.hasPrefix("video/") else { return fileURL }
        let thumbnailsDir = tempDirectory.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        let outURL = thumbnailsDir
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("jpg")
        let asset = AVAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let image = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            if let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.6) {
                try data.write(to: outURL, options: .atomic)
                return outURL
            }
        } catch {
            // Fall through: Android returns the file itself on failure too.
        }
        return fileURL
    }

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType
        {
            return mime
        }
        return "application/octet-stream"
    }
}
