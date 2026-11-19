import Foundation
import TDLibKit

/// The ONLY file in this project that talks to TDLibKit directly.
///
/// Verified against the generated sources of TDLibKit
/// 1.5.2-tdlib-1.8.66-d8d46dfa (2026-11-19, after CI run #2 failed to
/// compile). The names below are the real generated spellings, not guesses:
/// - `TDLibClientManager.createClient(updateHandler:)` takes
///   `(Data, TDLibClient) -> Void`.
/// - `setTdlibParameters` takes flattened optional params, not a
///   `TdlibParameters` object; `apiVersion`, `enableStorageOptimizer` and
///   `ignoreBackgroundUpdates` are not parameters in 1.8.66.
/// - Phone auth settings are `PhoneNumberAuthenticationSettings`
///   (7 fields), not `AuthenticationCodeSettings`.
/// - `requestQrCodeAuthentication` returns `Ok`; the QR link arrives in
///   `updateAuthorizationState` →
///   `authorizationStateWaitOtherDeviceConfirmation.link`.
/// - There is no `getSavedMessagesTopics` getter: call
///   `loadSavedMessagesTopics` and collect the topics from the
///   `updateSavedMessagesTopic` updates (count via
///   `updateSavedMessagesTopicCount`).
/// - `SavedMessagesTopicType` has no author case in 1.8.66: MyNotes /
///   AuthorHidden / SavedFromChat(chatId). A topic's identity is its
///   `topic.id` — use that for history calls, not a derived id.
/// - `File.id` is `Int`; `Messages.messages` is optional.
/// - `InputMessageDocument` takes `(caption, document: InputDocument)`;
///   the file/thumbnail/disableContentTypeDetection fields live on
///   `InputDocument`. `FormattedText.entities` is a non-optional array.
/// - `sendMessage` takes `topicId: MessageTopic`, not `messageThreadId`.
/// - `AuthorizationState` cases with payloads (waitCode, waitPassword,
///   waitRegistration, waitOtherDeviceConfirmation, waitPremiumPurchase,
///   waitEmailAddress, waitEmailCode) must be matched with `(_)`.
/// The rest of the app only sees the `TelegramClient` protocol, so fixes
/// stay in this file.
///
/// Still unverified without a real login: whether `Update` decodes from
/// the raw `Data` the handler receives, and the wait timeouts below
/// (30 s for the QR link, 5 s for the topic list).
final class TDLibKitAdapter: TelegramClient {
    enum AdapterError: LocalizedError {
        case noClient
        case timeout

        var errorDescription: String? {
            switch self {
            case .noClient:
                return "TDLib client is not available."
            case .timeout:
                return "Timed out waiting for a reply from TDLib."
            }
        }
    }

    private let manager = TDLibClientManager()
    private var client: TDLibClient?
    private let updatesContinuation: AsyncStream<TDLibUpdate>.Continuation
    let updates: AsyncStream<TDLibUpdate>

    /// State for the async waits below (QR link, topic list). Guarded by
    /// `waitLock`; a continuation is always removed from its table before
    /// it is resumed, so none is ever resumed twice.
    private let waitLock = NSLock()
    private var qrLink: String?
    private var qrWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var topicsCache: [Int64: SavedMessagesTopic] = [:]
    private var topicsExpectedCount: Int?
    private var topicsWaiters: [UUID: CheckedContinuation<[SavedTopic], Never>] = [:]

    init() {
        var continuation: AsyncStream<TDLibUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updatesContinuation = continuation
        client = manager.createClient { [weak self] data, _ in
            self?.handleUpdateData(data)
        }
    }

    // MARK: - Updates

    private func handleUpdateData(_ data: Data) {
        guard let update = try? JSONDecoder().decode(Update.self, from: data) else { return }
        switch update {
        case .updateAuthorizationState(let payload):
            if case .authorizationStateWaitOtherDeviceConfirmation(let conf) = payload.authorizationState {
                deliverQrLink(conf.link)
            }
            updatesContinuation.yield(.authorizationState(mapAuthState(payload.authorizationState)))
        case .updateNewMessage(let payload):
            updatesContinuation.yield(.newMessage(mapMessage(payload.message)))
        case .updateMessageSendSucceeded(let payload):
            updatesContinuation.yield(.messageSendSucceeded(oldMessageId: payload.oldMessageId, message: mapMessage(payload.message)))
        case .updateMessageSendFailed(let payload):
            updatesContinuation.yield(.messageSendFailed(oldMessageId: payload.oldMessageId))
        case .updateFile(let payload):
            updatesContinuation.yield(.fileUpdated(mapFile(payload.file)))
        case .updateSavedMessagesTopic(let payload):
            waitLock.lock()
            topicsCache[payload.topic.id] = payload.topic
            waitLock.unlock()
            updatesContinuation.yield(.savedMessagesTopicChanged)
            maybeResumeTopics()
        case .updateSavedMessagesTopicCount(let payload):
            waitLock.lock()
            topicsExpectedCount = payload.topicCount
            waitLock.unlock()
            maybeResumeTopics()
        case .updateDeleteMessages(let payload):
            updatesContinuation.yield(.deleteMessages(chatId: payload.chatId, messageIds: payload.messageIds))
        default:
            break
        }
    }

    private func mapAuthState(_ state: AuthorizationState) -> AuthState {
        switch state {
        case .authorizationStateWaitTdlibParameters: return .waitTdlibParameters
        case .authorizationStateWaitPhoneNumber: return .waitPhoneNumber
        // Premium-purchase and e-mail auth are not part of this app's
        // login UI; they map to the closest state the UI knows.
        case .authorizationStateWaitPremiumPurchase(_): return .waitPhoneNumber
        case .authorizationStateWaitEmailAddress(_): return .waitPhoneNumber
        case .authorizationStateWaitEmailCode(_): return .waitCode
        case .authorizationStateWaitCode(_): return .waitCode
        case .authorizationStateWaitOtherDeviceConfirmation(_): return .waitOtherDeviceConfirmation
        case .authorizationStateWaitRegistration(_): return .waitRegistration
        case .authorizationStateWaitPassword(_): return .waitPassword
        case .authorizationStateReady: return .ready
        case .authorizationStateLoggingOut: return .loggingOut
        case .authorizationStateClosing: return .closing
        case .authorizationStateClosed: return .closed
        }
    }

    private func mapFile(_ file: File) -> RemoteFile {
        RemoteFile(
            id: Int32(file.id),
            size: file.size,
            localPath: file.local.path,
            isDownloadingCompleted: file.local.isDownloadingCompleted,
            downloadedSize: file.local.downloadedSize,
            fileName: nil
        )
    }

    private func mapMessage(_ message: Message) -> ChatMessage {
        switch message.content {
        case .messageDocument(let doc):
            let tdFile = doc.document.document
            let file = RemoteFile(
                id: Int32(tdFile.id),
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
        // 1.8.66 takes the fields flattened (no TdlibParameters object,
        // no apiVersion / enableStorageOptimizer / ignoreBackgroundUpdates).
        // useTestDc is always false for this app; databaseEncryptionKey is
        // empty (no encryption); systemLanguageCode defaults to English.
        try await client.setTdlibParameters(
            apiHash: parameters.apiHash,
            apiId: Int(parameters.apiId),
            applicationVersion: parameters.applicationVersion,
            databaseDirectory: parameters.databaseDirectory,
            databaseEncryptionKey: Data(),
            deviceModel: parameters.deviceModel,
            filesDirectory: parameters.filesDirectory,
            systemLanguageCode: "en",
            systemVersion: parameters.systemVersion,
            useChatInfoDatabase: parameters.useChatInfoDatabase,
            useFileDatabase: parameters.useFileDatabase,
            useMessageDatabase: parameters.useMessageDatabase,
            useSecretChats: parameters.useSecretChats,
            useTestDc: false
        )
    }

    func setAuthenticationPhoneNumber(_ phoneNumber: String) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.setAuthenticationPhoneNumber(
            phoneNumber: phoneNumber,
            settings: PhoneNumberAuthenticationSettings(
                allowFlashCall: false,
                allowMissedCall: false,
                allowSmsRetrieverApi: false,
                authenticationTokens: [],
                firebaseAuthenticationSettings: nil,
                hasUnknownPhoneNumber: false,
                isCurrentPhoneNumber: false
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
        // Returns Ok; the tg:// link arrives in the next
        // authorizationStateWaitOtherDeviceConfirmation update.
        try await client.requestQrCodeAuthentication(otherUserIds: [])
        return try await waitForQrLink()
    }

    private func waitForQrLink() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let id = UUID()
            waitLock.lock()
            if let link = qrLink {
                waitLock.unlock()
                continuation.resume(returning: link)
                return
            }
            qrWaiters[id] = continuation
            waitLock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self.waitLock.lock()
                if let waiter = self.qrWaiters.removeValue(forKey: id) {
                    self.waitLock.unlock()
                    waiter.resume(throwing: AdapterError.timeout)
                } else {
                    self.waitLock.unlock()
                }
            }
        }
    }

    private func deliverQrLink(_ link: String) {
        waitLock.lock()
        qrLink = link
        let waiters = qrWaiters
        qrWaiters.removeAll()
        waitLock.unlock()
        for waiter in waiters.values { waiter.resume(returning: link) }
    }

    func confirmQrCodeAuthentication(link: String) async throws {
        guard let client else { throw AdapterError.noClient }
        _ = try await client.confirmQrCodeAuthentication(link: link)
    }

    // MARK: - Saved Messages

    func getMe() async throws -> Int64 {
        guard let client else { throw AdapterError.noClient }
        let user = try await client.getMe()
        return user.id
    }

    func getSavedMessagesTopics() async throws -> [SavedTopic] {
        guard let client else { throw AdapterError.noClient }
        // No getter in 1.8.66: loading triggers one
        // updateSavedMessagesTopic per topic (plus a count update). A 404
        // from load just means everything was already loaded, so it is
        // ignored and the cache is returned.
        try? await client.loadSavedMessagesTopics(limit: 100)
        return await waitForTopics()
    }

    private func waitForTopics() async -> [SavedTopic] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SavedTopic], Never>) in
            let id = UUID()
            waitLock.lock()
            let done = topicsExpectedCount.map { topicsCache.count >= $0 } ?? false
            if done {
                let topics = sortedTopicsLocked()
                waitLock.unlock()
                continuation.resume(returning: topics)
                return
            }
            topicsWaiters[id] = continuation
            waitLock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.waitLock.lock()
                if let waiter = self.topicsWaiters.removeValue(forKey: id) {
                    let topics = self.sortedTopicsLocked()
                    self.waitLock.unlock()
                    waiter.resume(returning: topics)
                } else {
                    self.waitLock.unlock()
                }
            }
        }
    }

    private func maybeResumeTopics() {
        waitLock.lock()
        guard let expected = topicsExpectedCount, topicsCache.count >= expected, !topicsWaiters.isEmpty else {
            waitLock.unlock()
            return
        }
        let waiters = topicsWaiters
        topicsWaiters.removeAll()
        let topics = sortedTopicsLocked()
        waitLock.unlock()
        for waiter in waiters.values { waiter.resume(returning: topics) }
    }

    /// Call with `waitLock` held.
    private func sortedTopicsLocked() -> [SavedTopic] {
        topicsCache.values
            .sorted { $0.order > $1.order }
            .map { SavedTopic(id: $0.id, name: topicName(of: $0), messageCount: 0) }
    }

    private func topicName(of topic: SavedMessagesTopic) -> String {
        switch topic.type {
        case .savedMessagesTopicTypeMyNotes:
            return "My Notes"
        case .savedMessagesTopicTypeAuthorHidden:
            return "Hidden author"
        case .savedMessagesTopicTypeSavedFromChat(let savedFrom):
            return "Chat \(savedFrom.chatId)"
        }
    }

    func getSavedMessagesTopicHistory(topicId: Int64, fromMessageId: Int64, limit: Int32) async throws -> [ChatMessage] {
        guard let client else { throw AdapterError.noClient }
        // History is reverse-chronological; fromMessageId 0 = latest,
        // limit <= 100.
        let result = try await client.getSavedMessagesTopicHistory(
            savedMessagesTopicId: topicId,
            fromMessageId: fromMessageId,
            offset: 0,
            limit: Int(limit)
        )
        return (result.messages ?? []).map(mapMessage)
    }

    // MARK: - Send / download

    func sendDocument(chatId: Int64, threadId: Int64, localPath: String, thumbnailPath: String?, caption: String) async throws -> ChatMessage {
        guard let client else { throw AdapterError.noClient }
        let thumbnail: InputThumbnail? = thumbnailPath.map {
            InputThumbnail(
                thumbnail: .inputFileLocal(InputFileLocal(path: $0)),
                width: 320,
                height: 320
            )
        }
        let content = InputMessageContent.inputMessageDocument(
            InputMessageDocument(
                caption: FormattedText(text: caption, entities: []),
                document: InputDocument(
                    disableContentTypeDetection: true,
                    document: .inputFileLocal(InputFileLocal(path: localPath)),
                    thumbnail: thumbnail
                )
            )
        )
        let message = try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: .messageTopicSavedMessages(MessageTopicSavedMessages(savedMessagesTopicId: threadId))
        )
        return mapMessage(message)
    }

    func downloadFile(fileId: Int32) async throws -> RemoteFile {
        guard let client else { throw AdapterError.noClient }
        // We ask for a synchronous download: the call returns when the file
        // is complete. Progress still arrives via updateFile (see
        // FileDownloadService).
        let file = try await client.downloadFile(
            fileId: Int(fileId),
            priority: 1,
            offset: 0,
            limit: 0,
            synchronous: true
        )
        return mapFile(file)
    }

    func cancelDownload(fileId: Int32) async throws {
        guard let client else { throw AdapterError.noClient }
        try await client.cancelDownloadFile(fileId: Int(fileId), onlyIfPending: false)
    }

    func getFile(fileId: Int32) async throws -> RemoteFile {
        guard let client else { throw AdapterError.noClient }
        return mapFile(try await client.getFile(fileId: Int(fileId)))
    }

    func close() async {
        manager.closeClients()
        client = nil
        waitLock.lock()
        let qrPending = qrWaiters
        qrWaiters.removeAll()
        let topicsPending = topicsWaiters
        topicsWaiters.removeAll()
        waitLock.unlock()
        for waiter in qrPending.values { waiter.resume(throwing: AdapterError.noClient) }
        for waiter in topicsPending.values { waiter.resume(returning: []) }
        updatesContinuation.finish()
    }
}
