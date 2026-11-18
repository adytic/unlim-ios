import Foundation

/// Fans the single TDLib update stream out to many subscribers.
/// TDLibKit delivers updates on one stream, but auth, sync and downloads
/// each need their own view of it — so the bus owns the one subscription
/// and forwards every update to every live subscriber.
final class UpdateBus {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TDLibUpdate>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?

    init(updates: AsyncStream<TDLibUpdate>) {
        pumpTask = Task { [weak self] in
            for await update in updates {
                self?.forward(update)
            }
        }
    }

    deinit {
        pumpTask?.cancel()
        lock.lock()
        let all = continuations.values
        continuations.removeAll()
        lock.unlock()
        for continuation in all {
            continuation.finish()
        }
    }

    func subscribe() -> AsyncStream<TDLibUpdate> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            self?.add(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
    }

    private func add(id: UUID, continuation: AsyncStream<TDLibUpdate>.Continuation) {
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
    }

    private func remove(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func forward(_ update: TDLibUpdate) {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for continuation in all {
            continuation.yield(update)
        }
    }
}
