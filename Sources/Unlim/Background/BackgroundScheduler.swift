import BackgroundTasks
import Foundation

/// Background sync, adapted from PhotosBackup's background-sync strategy
/// (docs/background-sync-strategy.md): resubmit-first, bounded work,
/// expiration cancels. Two deliberate adaptations:
///
/// 1. There is NO background URLSession transfer here. PhotosBackup's PUTs
///    go over HTTP; UnLim's transfers run inside TDLib, which owns the
///    network socket. The BGProcessingTask window therefore runs the same
///    queue drain the foreground uses, time-boxed by the task.
/// 2. iOS controls scheduling. A BGProcessingTask is an *opportunity*, not
///    a timer — the app must never promise a deadline for unattended sync.
///    `earliestBeginDate` is an eligibility date, not a schedule.
enum BackgroundScheduler {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let processingTaskIdentifier = "com.adit.unlim.background-sync"
    static let refreshTaskIdentifier = "com.adit.unlim.background-refresh"

    /// Set at launch (UnlimApp): the work a background window should do.
    static var processingHandler: (() async -> Void)?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleProcessing(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleRefresh(task)
        }
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        // Resubmit first — the Immich/Nextcloud pattern: a window that
        // crashes or expires must not lose the next opportunity.
        scheduleProcessing()
        let work = Task {
            await processingHandler?()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            await processingHandler?()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
