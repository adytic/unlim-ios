import Foundation

/// On-disk locations. Mirrors Android's layout where it has an iOS meaning:
/// temp chunks live under Application Support/temp/<Gallery|Files>, saved
/// downloads under Documents/Unlim/<Media|Files> (Android used
/// Download/Unlim/Media|Files via MediaStore; iOS has no public Downloads
/// folder, Documents/Unlim is visible in the Files app instead).
enum TempFileType: String, Sendable {
    case gallery = "Gallery"
    case files = "Files"
}

enum StorageLocation: Sendable {
    case media
    case files

    var directoryName: String {
        switch self {
        case .media: return "Media"
        case .files: return "Files"
        }
    }
}

enum AppDirectories {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Mirrors Android StorageServiceImpl.tempFolder(type):
    /// filesDir/temp/<Gallery|Files>.
    static func tempFolder(for type: TempFileType) -> URL {
        applicationSupport
            .appendingPathComponent("temp")
            .appendingPathComponent(type.rawValue)
    }

    /// Thumbnails for video uploads (Android: filesDir/temp/thumbnails).
    static var thumbnailsDirectory: URL {
        applicationSupport
            .appendingPathComponent("temp")
            .appendingPathComponent("thumbnails")
    }

    /// Where downloaded files are saved for the user to find in Files.
    static func savedFilesDirectory(for location: StorageLocation) -> URL {
        documents
            .appendingPathComponent("Unlim")
            .appendingPathComponent(location.directoryName)
    }
}
