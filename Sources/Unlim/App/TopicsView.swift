import SwiftUI

/// Saved Messages topics, then message history per topic with downloads.
struct TopicsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationView {
            List(appState.savedMessages.topics) { topic in
                NavigationLink(destination: TopicHistoryView(topic: topic)) {
                    VStack(alignment: .leading) {
                        Text(topic.name).font(.headline)
                        Text("\(topic.messageCount) messages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Saved Messages")
            .task { try? await appState.savedMessages.loadTopics() }
            .refreshable { try? await appState.savedMessages.loadTopics() }
        }
    }
}

struct TopicHistoryView: View {
    @EnvironmentObject private var appState: AppState
    let topic: SavedTopic
    @State private var progress: [Int64: Double] = [:]
    @State private var alertMessage: String?

    var body: some View {
        List(appState.savedMessages.messages) { message in
            MessageRow(message: message, progress: progress[message.id] ?? 0) {
                Task { await download(message) }
            }
        }
        .navigationTitle(topic.name)
        .task { try? await appState.savedMessages.loadHistory(topicId: topic.id) }
        .alert(
            "Unlim",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func download(_ message: ChatMessage) async {
        do {
            let url = try await appState.downloads.downloadMessage(
                message,
                allMessages: appState.savedMessages.messages
            ) { fraction in
                Task { @MainActor in progress[message.id] = fraction }
            }
            progress[message.id] = 1
            alertMessage = "Saved \(url.lastPathComponent) to Documents/Unlim."
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let progress: Double
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if case .document(let file, _) = message.content {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if progress > 0 && progress < 1 {
                ProgressView(value: progress)
            }
            if isDownloadable {
                Button("Download", action: onDownload)
            }
        }
    }

    /// Only documents download in this version. Photo messages carry their
    /// file id inside the largest PhotoSize — wiring that up is a follow-up
    /// (see README.md).
    private var isDownloadable: Bool {
        if case .document = message.content { return true }
        return false
    }

    private var title: String {
        switch message.content {
        case .document(let file, let caption):
            if let path = CaptionBuilder.parseFileCaption(caption)?.path {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return file.fileName ?? "Document"
        case .photo:
            return "Photo"
        case .text(let text):
            return text
        case .other(let name):
            return name
        }
    }
}
