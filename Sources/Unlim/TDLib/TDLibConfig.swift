import Foundation

/// TDLib credentials, loaded from `Sources/Unlim/Resources/TelegramConfig.plist`
/// in the app bundle. That file is gitignored; copy
/// `TelegramConfig.example.plist` there and fill in YOUR OWN keys from
/// https://my.telegram.org — never commit the real file, and never reuse
/// UnLim's (or anyone else's) keys.
struct TDLibConfig {
    let apiId: Int32
    let apiHash: String

    enum Error: LocalizedError {
        case missingFile
        case missingApiId
        case missingApiHash

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "TelegramConfig.plist is missing. Copy TelegramConfig.example.plist to Sources/Unlim/Resources/TelegramConfig.plist and fill in your own api_id / api_hash from my.telegram.org."
            case .missingApiId:
                return "TelegramConfig.plist has no usable api_id. Fill it in from my.telegram.org."
            case .missingApiHash:
                return "TelegramConfig.plist has no usable api_hash. Fill it in from my.telegram.org."
            }
        }
    }

    static func load(bundle: Bundle = .main) throws -> TDLibConfig {
        guard let url = bundle.url(forResource: "TelegramConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw Error.missingFile
        }
        guard let apiId = plist["api_id"] as? Int, apiId != 0 else {
            throw Error.missingApiId
        }
        guard let apiHash = plist["api_hash"] as? String, !apiHash.isEmpty,
              apiHash != "PASTE_YOUR_API_HASH_HERE"
        else {
            throw Error.missingApiHash
        }
        return TDLibConfig(apiId: Int32(apiId), apiHash: apiHash)
    }

    /// Writable directories TDLib needs for its database and downloaded files.
    var databaseDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tdlib").path
    }

    var filesDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tdlib-files").path
    }
}
