import SwiftUI

@main
struct UnlimApp: App {
    private let appState: AppState?
    private let configError: TDLibConfig.Error?

    init() {
        BackgroundScheduler.register()
        do {
            let state = try AppState()
            appState = state
            configError = nil
            BackgroundScheduler.processingHandler = { [weak state] in
                await state?.sync.drainUntilIdle()
            }
            BackgroundScheduler.scheduleProcessing()
            BackgroundScheduler.scheduleRefresh()
        } catch let error as TDLibConfig.Error {
            appState = nil
            configError = error
        } catch {
            appState = nil
            configError = .missingFile
        }
    }

    var body: some Scene {
        WindowGroup {
            if let appState {
                ContentView()
                    .environmentObject(appState)
            } else {
                MissingConfigView(error: configError)
            }
        }
    }
}

/// Shown when TelegramConfig.plist is missing or unfilled.
struct MissingConfigView: View {
    let error: TDLibConfig.Error?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Setup needed").font(.title2).bold()
                Text(error?.localizedDescription ?? "Telegram credentials are missing.")
                Text("1. Create an app at https://my.telegram.org and note your api_id and api_hash.\n2. Copy TelegramConfig.example.plist to Sources/Unlim/Resources/TelegramConfig.plist.\n3. Fill in your own api_id and api_hash, then rebuild.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Never commit the real file, and never reuse UnLim's keys.")
                    .font(.footnote)
            }
            .padding()
            .navigationTitle("Unlim")
        }
    }
}
