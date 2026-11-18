import Foundation

/// Our own thin model of the TDLib surface this app needs.
/// `TDLibKitAdapter` maps these to/from the generated TDLibKit types.
/// Keeping the app on this protocol means only that one file has to change
/// if a generated name differs (see the TODO header in TDLibKitAdapter.swift).

enum AuthState: Equatable, Sendable {
    case waitTdlibParameters
    case waitPhoneNumber
    case waitCode
    case waitPassword
    case waitRegistration
    case waitOtherDeviceConfirmation
    case ready
    case loggingOut
    case closing
    case closed
}

enum TDLibUpdate: Sendable {
    case authorizationState(AuthState)
    case newMessage(ChatMessage)
    case messageSendSucceeded(oldMessageId: Int64, message: ChatMessage)
    case messageSendFailed(oldMessageId: Int64)
    case fileUpdated(RemoteFile)
    case savedMessagesTopicChanged
    case deleteMessages(chatId: Int64, messageIds: [Int64])
}

/// A file as TDLib sees it. `fileName` is only known for files attached to
/// a message (it comes from the TDLib Document, not from File itself).
struct RemoteFile: Sendable, Equatable {
    let id: Int32
    let size: Int64
    let localPath: String?
    let isDownloadingCompleted: Bool
    let downloadedSize: Int64
    let fileName: String?
}

struct ChatMessage: Identifiable, Sendable {
    let id: Int64
    let chatId: Int64
    let content: MessageContent
}

enum MessageContent: Sendable {
    case document(RemoteFile, caption: String)
    case photo(RemoteFile, caption: String)
    case text(String)
    /// Any other constructor; the associated string is the constructor name,
    /// kept for debugging (e.g. "messageVideo").
    case other(String)
}

/// One Saved Messages topic. `id` is the topic id used by
/// getSavedMessagesTopicHistory: 0 for My Notes, the author's user id for
/// author topics (see the mapping TODO in TDLibKitAdapter.swift).
struct SavedTopic: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let messageCount: Int32
}

/// Parameters for TDLib's setTdlibParameters (TL names, see
/// https://core.telegram.org/tdlib/docs).
struct TdlibParameters: Sendable {
    let apiId: Int32
    let apiHash: String
    let deviceModel: String
    let systemVersion: String
    let applicationVersion: String
    let databaseDirectory: String
    let filesDirectory: String
    let useMessageDatabase: Bool
    let useFileDatabase: Bool
    let useChatInfoDatabase: Bool
    let useSecretChats: Bool
    let enableStorageOptimizer: Bool
}

protocol TelegramClient: AnyObject {
    /// The single update stream from TDLib. `UpdateBus` fans it out to the
    /// services that need it; do not consume it directly more than once.
    var updates: AsyncStream<TDLibUpdate> { get }

    func setTdlibParameters(_ parameters: TdlibParameters) async throws
    func setAuthenticationPhoneNumber(_ phoneNumber: String) async throws
    func checkAuthenticationCode(_ code: String) async throws
    func checkAuthenticationPassword(_ password: String) async throws
    /// Returns the link to render as a QR code for the user to scan in
    /// Telegram (Settings → Devices → Link Desktop Device).
    func requestQrCodeAuthentication() async throws -> String
    /// Confirms a login initiated on another device. Not part of this app's
    /// own QR login flow (that uses requestQrCodeAuthentication).
    func confirmQrCodeAuthentication(link: String) async throws
    /// The current user id — the Saved Messages chat id is the user's own id.
    func getMe() async throws -> Int64
    func getSavedMessagesTopics() async throws -> [SavedTopic]
    func getSavedMessagesTopicHistory(topicId: Int64, fromMessageId: Int64, limit: Int32) async throws -> [ChatMessage]
    func sendDocument(chatId: Int64, threadId: Int64, localPath: String, thumbnailPath: String?, caption: String) async throws -> ChatMessage
    func downloadFile(fileId: Int32) async throws -> RemoteFile
    func cancelDownload(fileId: Int32) async throws
    func getFile(fileId: Int32) async throws -> RemoteFile
    func close() async
}
