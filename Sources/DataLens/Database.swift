import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Tiny synchronous SQLite wrapper (serialised on its own queue).
final class SQLiteDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "datalens.sqlite")

    init?(path: String, readOnly: Bool = false) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func exec(_ sql: String, _ params: [Any?] = []) -> Bool {
        queue.sync { run(sql, params) { _ in } }
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        queue.sync {
            var rows: [[String: Any]] = []
            _ = run(sql, params) { stmt in
                var row: [String: Any] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                    default: break
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// Runs many statements inside one transaction.
    func transaction(_ body: () -> Void) {
        queue.sync {
            sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        }
        body()
        queue.sync {
            sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        }
    }

    private func run(_ sql: String, _ params: [Any?], row: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) } else { return rc == SQLITE_DONE }
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int64 {
        if let v = self[k] as? Int64 { return v }
        if let v = self[k] as? Double { return Int64(v) }
        return 0
    }
    func dbl(_ k: String) -> Double {
        if let v = self[k] as? Double { return v }
        if let v = self[k] as? Int64 { return Double(v) }
        return 0
    }
    func str(_ k: String) -> String { (self[k] as? String) ?? "" }
}

// MARK: - Shell helper

enum Shell {
    /// Runs a command off the main thread and returns stdout (stderr discarded).
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 600) async -> (out: String, status: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ("", -1)); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (String(decoding: data, as: UTF8.self), p.terminationStatus))
            }
        }
    }

    /// Synchronous variant for use on background queues.
    static func runSync(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Allocated size in bytes of a path via `du` (0 if missing / unreadable).
    static func sizeOf(_ path: String) async -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let r = await run("/usr/bin/du", ["-skx", path])
        let first = r.out.split(separator: "\t").first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return first * 1024
    }
}
