import Foundation

/// Owns the TDLib client and all services; the single source of truth the
/// SwiftUI views observe. Created only when TelegramConfig.plist is present
/// (UnlimApp shows MissingConfigView otherwise).
@MainActor
final class AppState: ObservableObject {
    let client: TelegramClient
    let bus: UpdateBus
    let auth: AuthService
    let savedMessages: SavedMessagesService
    let sync: SyncService
    let downloads: FileDownloadService

    init() throws {
        let config = try TDLibConfig.load()
        let adapter = TDLibKitAdapter()
        let bus = UpdateBus(updates: adapter.updates)
        self.client = adapter
        self.bus = bus
        self.auth = AuthService(client: adapter, config: config, bus: bus)
        self.savedMessages = SavedMessagesService(client: adapter)
        self.sync = SyncService(client: adapter)
        self.downloads = FileDownloadService(client: adapter, bus: bus)
        Task { [weak self] in await self?.observeUpdates() }
        Task { [weak self] in await self?.bootstrap() }
    }

    private func bootstrap() async {
        await sync.initialize()
        do {
            let userId = try await savedMessages.loadStorageChatId()
            sync.storageChatId = userId
            try await savedMessages.loadTopics()
        } catch {
            // Not logged in yet: topics load once auth reaches .ready
            // (see observeUpdates).
        }
    }

    private func observeUpdates() async {
        for await update in bus.subscribe() {
            switch update {
            case .authorizationState(let state):
                if state == .ready {
                    do {
                        let userId = try await savedMessages.loadStorageChatId()
                        sync.storageChatId = userId
                        try await savedMessages.loadTopics()
                    } catch {
                        // Stay on the login screen; the next update retries.
                    }
                }
            case .messageSendSucceeded(let oldMessageId, let message):
                await sync.handleMessageSendSucceeded(oldMessageId: oldMessageId, message: message)
            default:
                break
            }
        }
    }
}
