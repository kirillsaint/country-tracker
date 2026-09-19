import Foundation

// Очередь точек, ещё не доехавших до сервера. Хранится в JSON-файле в Application Support:
// в самолёте / роуминге точки копятся, при появлении сети уходят пачкой.
actor PendingQueue {
    static let shared = PendingQueue()

    private let fileURL: URL
    private var cache: [PendingPoint]?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pending-points.json")
    }

    func all() -> [PendingPoint] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? Self.decoder.decode([PendingPoint].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    func count() -> Int { all().count }

    func enqueue(_ point: PendingPoint) {
        var list = all()
        list.append(point)
        save(list)
    }

    func remove(ids: Set<String>) {
        save(all().filter { !ids.contains($0.clientId) })
    }

    private func save(_ list: [PendingPoint]) {
        cache = list
        if let data = try? Self.encoder.encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
