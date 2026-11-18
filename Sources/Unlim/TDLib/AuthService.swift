import Foundation
import UIKit

/// Drives the TDLib authorization state machine
/// (https://core.telegram.org/tdlib/getting-started).
/// TDLib delivers `.authorizationState` updates; this service answers each
/// waiting state and publishes the current state for the UI.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .waitTdlibParameters
    @Published private(set) var qrLink: String?

    private let client: TelegramClient
    private let config: TDLibConfig
    private var listenTask: Task<Void, Never>?

    init(client: TelegramClient, config: TDLibConfig, bus: UpdateBus) {
        self.client = client
        self.config = config
        listenTask = Task { [weak self] in
            await self?.observe(bus: bus)
        }
    }

    deinit {
        listenTask?.cancel()
    }

    private func observe(bus: UpdateBus) async {
        for await update in bus.subscribe() {
            guard case .authorizationState(let newState) = update else { continue }
            state = newState
            if newState == .waitTdlibParameters {
                // First update after launch: hand TDLib our parameters.
                // Errors are ignored here — a wrong state rejects the call
                // and the next update drives the flow again.
                try? await applyParameters()
            }
        }
    }

    /// Called on `authorizationStateWaitTdlibParameters`.
    func applyParameters() async throws {
        let applicationVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let parameters = TdlibParameters(
            apiId: config.apiId,
            apiHash: config.apiHash,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            applicationVersion: applicationVersion,
            databaseDirectory: config.databaseDirectory,
            filesDirectory: config.filesDirectory,
            useMessageDatabase: true,
            useFileDatabase: true,
            useChatInfoDatabase: true,
            useSecretChats: false,
            enableStorageOptimizer: true
        )
        try await client.setTdlibParameters(parameters)
    }

    func sendPhoneNumber(_ phoneNumber: String) async throws {
        try await client.setAuthenticationPhoneNumber(phoneNumber)
    }

    func sendCode(_ code: String) async throws {
        try await client.checkAuthenticationCode(code)
    }

    func sendPassword(_ password: String) async throws {
        try await client.checkAuthenticationPassword(password)
    }

    /// Starts QR login and returns the link to render as a QR code.
    /// The user scans it in Telegram (Settings → Devices → Link Desktop
    /// Device); TDLib then advances to ready (or waits for the 2FA password).
    func requestQRCode() async throws -> String {
        let link = try await client.requestQrCodeAuthentication()
        qrLink = link
        return link
    }

    func confirmQRCode(link: String) async throws {
        try await client.confirmQrCodeAuthentication(link: link)
    }
}
