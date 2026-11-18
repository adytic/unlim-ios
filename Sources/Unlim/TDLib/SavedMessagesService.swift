import Foundation

/// Saved Messages topics and history, via TDLib.
@MainActor
final class SavedMessagesService: ObservableObject {
    @Published private(set) var topics: [SavedTopic] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var storageChatId: Int64?

    private let client: TelegramClient

    init(client: TelegramClient) {
        self.client = client
    }

    /// The Saved Messages chat is the user's own chat: chat id == user id.
    func loadStorageChatId() async throws {
        storageChatId = try await client.getMe()
    }

    func loadTopics() async throws {
        topics = try await client.getSavedMessagesTopics()
    }

    /// History is reverse-chronological; fromMessageId 0 = latest, limit <= 100.
    func loadHistory(topicId: Int64, fromMessageId: Int64 = 0, limit: Int32 = 100) async throws {
        messages = try await client.getSavedMessagesTopicHistory(
            topicId: topicId,
            fromMessageId: fromMessageId,
            limit: limit
        )
    }
}
