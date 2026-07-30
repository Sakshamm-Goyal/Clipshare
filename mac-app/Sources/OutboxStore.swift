import Foundation

/// Persists encrypted routes until the receiving device ACKs them. The file
/// contains only the already-encrypted envelope, never clipboard plaintext.
final class OutboxStore {
    private let fileURL: URL
    private var routes: [String: Message] = [:]

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipShare", isDirectory: true)
        try? fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        fileURL = applicationSupport.appendingPathComponent("outbox.json")
        load()
    }

    func enqueue(_ message: Message) {
        guard let id = message.id else { return }
        routes[id] = message
        persist()
    }

    func acknowledge(_ messageID: String) {
        guard routes.removeValue(forKey: messageID) != nil else { return }
        persist()
    }

    func pendingRoutes() -> [Message] {
        routes.values.sorted { ($0.id ?? "") < ($1.id ?? "") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Message].self, from: data) else {
            return
        }
        routes = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
