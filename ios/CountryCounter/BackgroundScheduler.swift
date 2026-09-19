import BackgroundTasks
import Foundation
import os

// Ежечасный фоновый тик: снять одну точку и отправить очередь.
// iOS не гарантирует интервал — это "не раньше чем через час", реально может быть и 3 часа,
// зависит от того, как часто вы открываете приложение. Основная нагрузка лежит на visits и
// significant changes, а это — страховка.
enum BackgroundScheduler {
    static let refreshIdentifier = "ge.kirillsaint.countrycounter.refresh"
    private static let log = Logger(subsystem: "ge.kirillsaint.countrycounter", category: "bgtask")

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskSchedulerErrorDomain code 1 = недоступно (симулятор), code 3 = уже запланировано
            log.error("schedule failed: \(error.localizedDescription)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let completed = OSAllocatedUnfairLock(initialState: false)
        func finish(_ success: Bool) {
            let first = completed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { task.setTaskCompleted(success: success) }
        }

        let work = Task { @MainActor in
            if AppSettings.hourlyEnabled {
                _ = await LocationTracker.shared.requestOneShot(source: .hourly)
            }
            await Uploader.flush()
            finish(true)
        }
        task.expirationHandler = {
            work.cancel()
            finish(false)
        }
    }
}
