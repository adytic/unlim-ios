import SwiftUI

/// Settings: sync options, albums to sync, and storage info.
/// Option toggles mirror Android's setOptions — they store the preference;
/// the Vision-based labeling / face-recognition features themselves are
/// not built yet (see README.md).
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newFolder = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Telegram") {
                    HStack {
                        Text("Saved Messages chat")
                        Spacer()
                        Text(appState.savedMessages.storageChatId.map(String.init) ?? "—")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("api_id")
                        Spacer()
                        Text("Configured — see TelegramConfig.plist")
                            .foregroundColor(.secondary)
                    }
                }
                Section("Sync options") {
                    Toggle("Image labeling", isOn: binding(for: .imageLabeling))
                    Toggle("Face recognition", isOn: binding(for: .faceRecognition))
                    Toggle("Auto album", isOn: binding(for: .autoAlbum))
                    Text("Labeling and face recognition need the Vision-based features (not built yet); the switches only store the preference, like Android's setOptions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section("Albums to sync") {
                    let sortedFolders = appState.sync.foldersToSync.sorted()
                    ForEach(sortedFolders, id: \.self) { folder in
                        Text(folder)
                    }
                    .onDelete { indexSet in
                        var folders = appState.sync.foldersToSync
                        for index in indexSet {
                            folders.remove(sortedFolders[index])
                        }
                        appState.sync.updateFoldersToSync(folders)
                    }
                    HStack {
                        TextField("Album name", text: $newFolder)
                        Button("Add") {
                            guard !newFolder.isEmpty else { return }
                            var folders = appState.sync.foldersToSync
                            folders.insert(newFolder)
                            appState.sync.updateFoldersToSync(folders)
                            newFolder = ""
                        }
                    }
                }
                Section("Storage") {
                    Button("Clear synced set") {
                        UserDefaults.standard.removeObject(forKey: "Synced")
                        Task { await appState.sync.refreshSyncPrompt() }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func binding(for option: SyncOption) -> Binding<Bool> {
        Binding(
            get: {
                switch option {
                case .imageLabeling: return appState.sync.imageLabelingEnabled
                case .faceRecognition: return appState.sync.faceRecognitionEnabled
                case .autoAlbum: return appState.sync.autoAlbumEnabled
                }
            },
            set: { appState.sync.setOption(option, enabled: $0) }
        )
    }
}
