import SwiftUI

/// The upload queue (SyncStore rows) and the not-yet-synced photo prompt,
/// mirroring Android's queue UI and sync prompt dialog.
struct QueueView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isSyncingPrompt = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            List {
                Section("Queue") {
                    ForEach(appState.sync.queue) { model in
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: model.path).lastPathComponent)
                                .font(.headline)
                            Text(model.state.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Button(appState.sync.isPaused ? "Resume" : "Pause") {
                            if appState.sync.isPaused {
                                appState.sync.resume()
                            } else {
                                appState.sync.pause()
                            }
                        }
                        Button("Cancel all", role: .destructive) {
                            appState.sync.cancelAll()
                        }
                    }
                }
                Section("Not synced yet") {
                    ForEach(appState.sync.syncPrompt) { prompt in
                        VStack(alignment: .leading) {
                            Text(prompt.isVideo ? "Video" : "Photo").font(.headline)
                            Text("\(prompt.pixelSize) · \(prompt.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown date")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button("Sync all") {
                        Task { await syncPrompt() }
                    }
                    .disabled(appState.sync.syncPrompt.isEmpty || isSyncingPrompt)
                    Button("Skip all") {
                        appState.sync.cancelSyncPrompt()
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Upload queue")
        }
    }

    private func syncPrompt() async {
        guard let storageId = appState.savedMessages.storageChatId else {
            errorMessage = "Not logged in yet."
            return
        }
        isSyncingPrompt = true
        defer { isSyncingPrompt = false }
        var paths: [String] = []
        for prompt in appState.sync.syncPrompt {
            do {
                let url = try await GalleryScanner.exportAsset(
                    prompt.asset,
                    to: AppDirectories.tempFolder(for: .gallery)
                )
                paths.append(url.path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await appState.sync.uploadToGallery(storageId: storageId, paths: paths)
        await appState.sync.refreshSyncPrompt()
    }
}
