import Foundation
import os

// Отправляет накопленную очередь на сервер. Безопасно дёргать откуда угодно и сколько угодно:
// одновременно работает только одна отправка, остальные вызовы ждут её и затем отправляют то,
// что успело накопиться (раньше они просто выходили, и точка при открытии приложения
// оставалась в очереди, пока шла отправка предыдущей).
enum Uploader {
    private static let log = Logger(subsystem: "ge.kirillsaint.stamps", category: "upload")
    private static let gate = Gate()

    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Передаёт очередь следующему ожидающему, не опуская флаг
        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    @discardableResult
    static func flush() async -> Int {
        await gate.acquire()
        defer { Task { await gate.release() } }

        let queue = PendingQueue.shared
        let pending = await queue.all()
        guard !pending.isEmpty else { return 0 }

        guard let client = try? APIClient.fromSettings() else {
            log.info("upload skipped: not signed in, \(pending.count) pending")
            return 0
        }

        var sent = 0
        for batch in stride(from: 0, to: pending.count, by: 200).map({ Array(pending[$0..<min($0 + 200, pending.count)]) }) {
            do {
                let result = try await client.upload(batch)
                await queue.remove(ids: Set(batch.map(\.clientId)))
                sent += batch.count
                log.info("uploaded \(batch.count): inserted \(result.inserted), skipped \(result.skipped)")
            } catch {
                log.error("upload failed: \(error.localizedDescription)")
                break
            }
        }
        // Новые точки могли сдвинуть счётчики — проверяем правила и в фоне тоже
        if sent > 0 {
            await RuleNotifier.check()
            await EntryPrompter.check()
        }
        await RegimeChecks.processPending()
        return sent
    }
}
