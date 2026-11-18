import Foundation
import TDLibKit

/// The ONLY file in this project that talks to TDLibKit directly.
///
/// TODO(TDLibKit) — READ THIS FIRST:
/// Every generated name used here is derived from the TL method/type names
/// in https://core.telegram.org/tdlib/docs and the call pattern in the
/// TDLibKit README (`TDLibClientManager`, `createClient(updateHandler:)`,
/// `client.getChatHistory(chatId:fromMessageId:limit:offset:onlyLocal:)`).
/// The research report (2026-11-18) could NOT verify the exact generated
/// Swift spellings. After the first `xcodegen generate` + SPM resolve, open
/// the generated sources under
/// DerivedData/.../SourcePackages/checkouts/TDLibKit/Sources and fix any
/// name that does not match. The rest of the app only sees the
/// `TelegramClient` protocol, so fixes stay in this file.
final class TDLibKitAdapter: TelegramClient {
    enum AdapterError: LocalizedError {
        case noClient

        var errorDescription: String? {
            "TDLib client is not available."
        }
    }

    private let manager = TDLibClientManager()
    private var client: TDLibClient?
    private let updatesContinuation: AsyncStream<TDLibUpdate>.Continuation
    let updates: AsyncStream<TDLibUpdate>

    init() {
        var continuation: AsyncStream<TDLibUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updatesContinuation = continuation
        // TODO(TDLibKit): verify createClient(updateHandler:) delivers raw Data.
        client = manager.createClient { [weak self] data in
            self?.handleUpdateData(data)
        }
    }

    // MARK: - Updates

    private func handleUpdateData(_ data: Data) {
        // TODO(TDLibKit): verify Update decodes from the raw Data the
        // handler receives, and verify the case payload shapes below
        // (each case carries its TL struct, e.g. UpdateNewMessage.message).
        guard let update = try? JSONDecoder().decode(Update.self, from: data) else { return }
        switch update {
        case .updateAuthorizationState(let payload):
            updatesContinuation.yield(.authorizationState(mapAuthState(payload.authorizationState)))
        case .updateNewMessage(let payload):
            updatesContinuation.yield(.newMessage(mapMessage(payload.message)))
        case .updateMessageSendSucceeded(let payload):
            updatesContinuation.yield(.messageSendSucceeded(oldMessageId: payload.oldMessageId, message: mapMessage(payload.message)))
        case .updateMessageSendFailed(let payload):
            updatesContinuation.yield(.messageSendFailed(oldMessageId: payload.oldMessageId))
        case .updateFile(let payload):
            updatesContinuation.yield(.fileUpdated(mapFile(payload.file)))
        case .updateSavedMessagesTopic:
            updatesContinuation.yield(.savedMessagesTopicChanged)
        case .updateDeleteMessages(let payload):
            updatesContinuation.yield(.deleteMessages(chatId: payload.chatId, messageIds: payload.messageIds))
        default:
            break
        }
    }

    // TODO(TDLibKit): verify the AuthorizationState enum case spellings and
    // whether each case carries a payload (use `case .authorizationStateWaitCode(_):`
    // style if it does).
    private func mapAuthState(_ state: AuthorizationState) -> AuthState {
        switch state {
        case .authorizationStateWaitTdlibParameters: return .waitTdlibParameters
        case .authorizationStateWaitPhoneNumber: return .waitPhoneNumber
        case .authorizationStateWaitCode: return .waitCode
        case .authorizationStateWaitPassword: return .waitPassword
        case .authorizationStateWaitRegistration: return .waitRegistration
        case .authorizationStateWaitOtherDeviceConfirmation: return .waitOtherDeviceConfirmation
        case .authorizationStateReady: return .ready
        case .authorizationStateLoggingOut: return .loggingOut
        case .authorizationStateClosing: return .closing
        case .authorizationStateClosed: return .closed
        }
    }

    private func mapFile(_ file: File) -> RemoteFile {
        RemoteFile(
            id: file.id,
            size: file.size,
            localPath: file.local.path,
            isDownloadingCompleted: file.local.isDownloadingCompleted,
            downloadedSize: file.local.downloadedSize,
            fileName: nil
        )
    }

    // TODO(TDLibKit): verify MessageContent case spellings and payload
    // struct field names (MessageDocument.document / .caption,
    // MessagePhoto.photo.sizes, MessageText.text).
    private func mapMessage(_ message: Message) -> ChatMessage {
        switch message.content {
        case .messageDocument(let doc):
            let tdFile = doc.document.document
            let file = RemoteFile(
                id: tdFile.id,
                size: tdFile.size,
                localPath: tdFile.local.path,
                isDownloadingCompleted: tdFile.local.isDownloadingCompleted,
                downloadedSize: tdFile.local.downloadedSize,
                fileName: doc.document.fileName
            )
            return ChatMessage(id: message.id, chatId: message.chatId, content: .document(file, caption: doc.caption.text))
        case .messagePhoto(let photo):
            let largest = photo.photo.sizes.max { $0.width * $0.height < $1.width * $1.height }
            if let largest {
                let file = mapFile(largest.photo)
                return ChatMessage(id: message.id, chatId: message.chatId, content: .photo(file, caption: photo.caption.text))
            }
            return ChatMessage(id: message.id, chatId: message.chatId, content: .other("messagePhoto"))
        case .messageText(let text):
            return ChatMessage(id: message.id, chatId: message.chatId, content: .text(text.text.text))
        default:
            return ChatMessage(id: message.id, chatId: message.chatId, content: .other(String(describing: message.content)))
        }
    }

    // MARK: - Auth

    func setTdlibParameters(_ parameters: TdlibParameters) async throws {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify TdlibParameters field names and the
        // apiVersion value.
        let tdlibParameters = TdlibParameters(
            apiId: parameters.apiId,
            apiHash: parameters.apiHash,
            deviceModel: parameters.deviceModel,
            systemVersion: parameters.systemVersion,
            applicationVersion: parameters.applicationVersion,
            useTestDc: false,
            databaseDirectory: parameters.databaseDirectory,
            filesDirectory: parameters.filesDirectory,
            databaseEncryptionKey: [],
            useFileDatabase: parameters.useFileDatabase,
            useChatInfoDatabase: parameters.useChatInfoDatabase,
            useMessageDatabase: parameters.useMessageDatabase,
            useSecretChats: parameters.useSecretChats,
            apiVersion: "1.8.69",
            enableStorageOptimizer: parameters.enableStorageOptimizer,
            ignoreBackgroundUpdates: false
        )
        try await client.setTdlibParameters(parameters: tdlibParameters)
    }

    func setAuthenticationPhoneNumber(_ phoneNumber: String) async throws {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify setAuthenticationPhoneNumber labels and
        // the AuthenticationCodeSettings initializer.
        try await client.setAuthenticationPhoneNumber(
            phoneNumber: phoneNumber,
            settings: AuthenticationCodeSettings(
                allowFlashCall: false,
                allowMissedCall: false,
                allowSmsRetrieverApi: false,
                firebaseAuthenticationSettings: nil,
                authenticationTokens: []
            )
        )
    }

    func checkAuthenticationCode(_ code: String) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.checkAuthenticationCode(code: code)
    }

    func checkAuthenticationPassword(_ password: String) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.checkAuthenticationPassword(password: password)
    }

    func requestQrCodeAuthentication() async throws -> String {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify requestQrCodeAuthentication returns Link
        // and the field name for the URL.
        let link = try await client.requestQrCodeAuthentication(otherUserIds: [])
        return link.link
    }

    func confirmQrCodeAuthentication(link: String) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.confirmQrCodeAuthentication(link: link)
    }

    // MARK: - Saved Messages

    func getMe() async throws -> Int64 {
        guard let client else { throw AdapterError.noClient }
        let user = try await client.getMe()
        return user.id
    }

    func getSavedMessagesTopics() async throws -> [SavedTopic] {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify SavedMessagesTopics shape and how a topic
        // maps to a history id (see topicId(of:) below).
        let result = try await client.getSavedMessagesTopics()
        return result.topics.map { topic in
            SavedTopic(id: topicId(of: topic), name: topicName(of: topic), messageCount: 0)
        }
    }

    /// Maps a TDLib SavedMessagesTopic to the id getSavedMessagesTopicHistory
    /// expects. TL: My Notes is topic 0; an author topic is identified by
    /// the author's user id.
    /// TODO(TDLibKit): verify the SavedMessagesTopicType enum case spellings
    /// and payload shapes (e.g. whether the author case carries a struct
    /// with a userId field).
    private func topicId(of topic: SavedMessagesTopic) -> Int64 {
        switch topic.type {
        case .savedMessagesTopicTypeMyNotes:
            return 0
        case .savedMessagesTopicTypeAuthor(let author):
            return author.userId
        }
    }

    private func topicName(of topic: SavedMessagesTopic) -> String {
        switch topic.type {
        case .savedMessagesTopicTypeMyNotes:
            return "My Notes"
        case .savedMessagesTopicTypeAuthor(let author):
            return "User \(author.userId)"
        }
    }

    func getSavedMessagesTopicHistory(topicId: Int64, fromMessageId: Int64, limit: Int32) async throws -> [ChatMessage] {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify parameter labels and the Messages shape.
        // History is reverse-chronological; fromMessageId 0 = latest,
        // limit <= 100.
        let result = try await client.getSavedMessagesTopicHistory(
            savedMessagesTopicId: topicId,
            fromMessageId: fromMessageId,
            offset: 0,
            limit: limit
        )
        return result.messages.map(mapMessage)
    }

    // MARK: - Send / download

    func sendDocument(chatId: Int64, threadId: Int64, localPath: String, thumbnailPath: String?, caption: String) async throws -> ChatMessage {
        guard let client else { throw AdapterError.noClient }
        // TODO(TDLibKit): verify InputMessageDocument / InputThumbnail
        // initializers and the sendMessage parameter labels.
        let thumbnail: InputThumbnail? = thumbnailPath.map {
            InputThumbnail(
                thumbnail: .inputFileLocal(InputFileLocal(path: $0)),
                width: 320,
                height: 320
            )
        }
        let content = InputMessageContent.inputMessageDocument(
            InputMessageDocument(
                document: .inputFileLocal(InputFileLocal(path: localPath)),
                thumbnail: thumbnail,
                disableContentTypeDetection: true,
                caption: FormattedText(text: caption, entities: nil)
            )
        )
        let message = try await client.sendMessage(
            chatId: chatId,
            messageThreadId: threadId,
            replyTo: nil,
            options: nil,
            replyMarkup: nil,
            inputMessageContent: content
        )
        return mapMessage(message)
    }

    func downloadFile(fileId: Int32) async throws -> RemoteFile {
        guard let client else { throw AdapterError.noClient }
        // We ask for a synchronous download: the call returns when the file
        // is complete. Progress still arrives via updateFile (see
        // FileDownloadService). TODO(TDLibKit): verify the parameter labels.
        let file = try await client.downloadFile(
            fileId: fileId,
            priority: 1,
            offset: 0,
            limit: 0,
            synchronous: true
        )
        return mapFile(file)
    }

    func cancelDownload(fileId: Int32) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false)
    }

    func getFile(fileId: Int32) async throws -> RemoteFile {
        guard let client else { throw AdapterError.noClient }
        return mapFile(try await client.getFile(fileId: fileId))
    }

    func close() async {
        manager.closeClients()
        client = nil
        updatesContinuation.finish()
    }
}
