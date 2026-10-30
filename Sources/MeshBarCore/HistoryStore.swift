import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

public protocol HistoryStoring: AnyObject {
    func append(_ samples: [HistorySample]) throws
    func samples(since: Date, nodeID: String?) throws -> [HistorySample]
    func purge(olderThan: Date) throws
    func removeAll() throws
    /// Per-client samples, one per client per poll.
    func appendClients(_ samples: [ClientSample]) throws
    func clientSamples(clientID: String, since: Date) throws -> [ClientSample]
}

extension HistoryStoring {
    public func appendClients(_ samples: [ClientSample]) throws {}
    public func clientSamples(clientID: String, since: Date) throws -> [ClientSample] { [] }
}

public enum HistoryStoreError: Error, Equatable, CustomStringConvertible {
    case openFailed
    case writeFailed

    public var description: String {
        switch self {
        case .openFailed: return "Could not open the history database."
        case .writeFailed: return "Could not write a history sample."
        }
    }
}

public enum HistoryCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// JSON-lines fallback. One sample per line under Application Support.
public final class JSONLinesHistoryStore: HistoryStoring {
    private let fileURL: URL
    private let clientsURL: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.jsonl")
        clientsURL = directory.appendingPathComponent("client-history.jsonl")
        for url in [fileURL, clientsURL] where !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func appendClients(_ samples: [ClientSample]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try appendLines(samples, to: clientsURL)
    }

    public func clientSamples(clientID: String, since: Date) throws -> [ClientSample] {
        lock.lock()
        defer { lock.unlock() }
        return readClients().filter { $0.clientID == clientID && $0.timestamp >= since }
    }

    private func readClients() -> [ClientSample] {
        guard let data = try? Data(contentsOf: clientsURL), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = HistoryCoding.decoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in line.data(using: .utf8).flatMap { try? decoder.decode(ClientSample.self, from: $0) } }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func appendLines<T: Encodable>(_ items: [T], to url: URL) throws {
        let encoder = HistoryCoding.encoder()
        var blob = Data()
        for item in items {
            blob.append(try encoder.encode(item))
            blob.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = handle.seekToEndOfFile()
        try handle.write(contentsOf: blob)
    }

    private func writeLines<T: Encodable>(_ items: [T], to url: URL) throws {
        let encoder = HistoryCoding.encoder()
        var blob = Data()
        for item in items {
            blob.append(try encoder.encode(item))
            blob.append(0x0A)
        }
        try blob.write(to: url, options: .atomic)
    }

    public func append(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        let encoder = HistoryCoding.encoder()
        var blob = Data()
        for sample in samples {
            blob.append(try encoder.encode(sample))
            blob.append(0x0A)
        }
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        _ = handle.seekToEndOfFile()
        try handle.write(contentsOf: blob)
    }

    public func samples(since: Date, nodeID: String?) throws -> [HistorySample] {
        lock.lock()
        defer { lock.unlock() }
        return try read(since: since, nodeID: nodeID)
    }

    public func purge(olderThan: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let kept = try read(since: .distantPast, nodeID: nil).filter { $0.timestamp >= olderThan }
        try write(kept)
        let clients = readClients()
        if clients.contains(where: { $0.timestamp < olderThan }) {
            try writeLines(clients.filter { $0.timestamp >= olderThan }, to: clientsURL)
        }
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try write([])
        try writeLines([ClientSample](), to: clientsURL)
    }

    private func read(since: Date, nodeID: String?) throws -> [HistorySample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = HistoryCoding.decoder()
        var parsed: [HistorySample] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = line.data(using: .utf8),
                  let sample = try? decoder.decode(HistorySample.self, from: row) else {
                MeshLog.shape("Skipped a history line that was not a sample")
                continue
            }
            guard sample.timestamp >= since else { continue }
            if let nodeID, sample.nodeID != nodeID { continue }
            parsed.append(sample)
        }
        return parsed.sorted { $0.timestamp < $1.timestamp }
    }

    private func write(_ samples: [HistorySample]) throws {
        let encoder = HistoryCoding.encoder()
        var blob = Data()
        for sample in samples {
            blob.append(try encoder.encode(sample))
            blob.append(0x0A)
        }
        try blob.write(to: fileURL, options: .atomic)
    }
}

/// History in sqlite3, linked from the system library. No third-party wrapper.
public final class SQLiteHistoryStore: HistoryStoring {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let opened: Int32 = path.withCString { cString in
            sqlite3_open_v2(cString, &db, flags, nil)
        }
        guard opened == SQLITE_OK, db != nil else {
            if db != nil { sqlite3_close(db) }
            throw HistoryStoreError.openFailed
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS samples (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            node_id TEXT NOT NULL,
            node_name TEXT NOT NULL,
            is_online INTEGER NOT NULL,
            parent_id TEXT,
            speed_mbps REAL,
            rssi_dbm INTEGER,
            connection_type TEXT,
            client_count INTEGER NOT NULL,
            wan_connected INTEGER,
            wan_type TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp);
        CREATE INDEX IF NOT EXISTS idx_samples_node ON samples(node_id, timestamp);
        """)
        try migrate()
    }

    /// Schema version in `PRAGMA user_version`.
    /// 1: node/WAN samples. 2: adds per-client samples.
    public static let schemaVersion: Int32 = 2

    private func migrate() throws {
        var version: Int32 = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        if version < 2 {
            try exec("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS client_samples (
                timestamp REAL NOT NULL,
                client_id TEXT NOT NULL,
                mac TEXT,
                name TEXT NOT NULL,
                node_id TEXT,
                node_name TEXT,
                band TEXT,
                medium TEXT,
                rssi_dbm INTEGER,
                link_mbps REAL,
                is_online INTEGER NOT NULL,
                ip TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_client_samples_client ON client_samples(client_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_client_samples_timestamp ON client_samples(timestamp);
            PRAGMA user_version = 2;
            COMMIT;
            """)
        }
    }

    public func userVersion() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    public func appendClients(_ samples: [ClientSample]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let sql = """
            INSERT INTO client_samples (
                timestamp, client_id, mac, name, node_id, node_name, band, medium, rssi_dbm, link_mbps, is_online, ip
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryStoreError.writeFailed
            }
            defer { sqlite3_finalize(statement) }
            for sample in samples {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
                bindText(statement, 2, sample.clientID)
                bindText(statement, 3, sample.macAddress)
                bindText(statement, 4, sample.name)
                bindText(statement, 5, sample.nodeID)
                bindText(statement, 6, sample.nodeName)
                bindText(statement, 7, sample.band)
                bindText(statement, 8, sample.medium)
                if let rssi = sample.rssiDbm {
                    sqlite3_bind_int(statement, 9, Int32(rssi))
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                bindDouble(statement, 10, sample.linkMbps)
                sqlite3_bind_int(statement, 11, sample.isOnline ? 1 : 0)
                bindText(statement, 12, sample.ipAddress)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func clientSamples(clientID: String, since: Date) throws -> [ClientSample] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT timestamp, client_id, mac, name, node_id, node_name, band, medium, rssi_dbm, link_mbps, is_online, ip FROM client_samples WHERE client_id = ? AND timestamp >= ? ORDER BY timestamp ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, clientID)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
        var rows: [ClientSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ClientSample(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                clientID: columnText(statement, 1) ?? clientID,
                macAddress: columnText(statement, 2),
                name: columnText(statement, 3) ?? "",
                nodeID: columnText(statement, 4),
                nodeName: columnText(statement, 5),
                band: columnText(statement, 6),
                medium: columnText(statement, 7),
                rssiDbm: columnInt(statement, 8),
                linkMbps: columnDouble(statement, 9),
                isOnline: sqlite3_column_int(statement, 10) != 0,
                ipAddress: columnText(statement, 11)
            ))
        }
        return rows
    }

    deinit {
        sqlite3_close(db)
    }

    public func append(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            for sample in samples {
                try insert(sample)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func samples(since: Date, nodeID: String?) throws -> [HistorySample] {
        lock.lock()
        defer { lock.unlock() }
        let sql: String
        if nodeID == nil {
            sql = "SELECT id, timestamp, node_id, node_name, is_online, parent_id, speed_mbps, rssi_dbm, connection_type, client_count, wan_connected, wan_type FROM samples WHERE timestamp >= ? ORDER BY timestamp ASC"
        } else {
            sql = "SELECT id, timestamp, node_id, node_name, is_online, parent_id, speed_mbps, rssi_dbm, connection_type, client_count, wan_connected, wan_type FROM samples WHERE timestamp >= ? AND node_id = ? ORDER BY timestamp ASC"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        if let nodeID {
            bindText(statement, 2, nodeID)
        }
        var rows: [HistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(read(statement))
        }
        return rows
    }

    public func purge(olderThan: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        for table in ["samples", "client_samples"] {
            let sql = "DELETE FROM \(table) WHERE timestamp < ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryStoreError.writeFailed
            }
            sqlite3_bind_double(statement, 1, olderThan.timeIntervalSince1970)
            let code = sqlite3_step(statement)
            sqlite3_finalize(statement)
            statement = nil
            guard code == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
        }
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("DELETE FROM samples; DELETE FROM client_samples;")
    }

    private func insert(_ sample: HistorySample) throws {
        let sql = """
        INSERT OR REPLACE INTO samples (
            id, timestamp, node_id, node_name, is_online, parent_id, speed_mbps, rssi_dbm,
            connection_type, client_count, wan_connected, wan_type
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, sample.id.uuidString)
        sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
        bindText(statement, 3, sample.nodeID)
        bindText(statement, 4, sample.nodeName)
        sqlite3_bind_int(statement, 5, sample.isOnline ? 1 : 0)
        bindText(statement, 6, sample.parentID)
        bindDouble(statement, 7, sample.speedMbps)
        if let rssi = sample.rssiDbm {
            sqlite3_bind_int(statement, 8, Int32(rssi))
        } else {
            sqlite3_bind_null(statement, 8)
        }
        bindText(statement, 9, sample.connectionType)
        sqlite3_bind_int(statement, 10, Int32(sample.clientCount))
        if let wan = sample.wanConnected {
            sqlite3_bind_int(statement, 11, wan ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        bindText(statement, 12, sample.wanType)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.writeFailed
        }
    }

    private func read(_ statement: OpaquePointer?) -> HistorySample {
        let id = UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID()
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        return HistorySample(
            id: id,
            timestamp: timestamp,
            nodeID: columnText(statement, 2) ?? "",
            nodeName: columnText(statement, 3) ?? "",
            isOnline: sqlite3_column_int(statement, 4) != 0,
            parentID: columnText(statement, 5),
            speedMbps: columnDouble(statement, 6),
            rssiDbm: columnInt(statement, 7),
            connectionType: columnText(statement, 8),
            clientCount: Int(sqlite3_column_int(statement, 9)),
            wanConnected: columnBool(statement, 10),
            wanType: columnText(statement, 11)
        )
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &message)
        if let message {
            sqlite3_free(message)
        }
        guard code == SQLITE_OK else { throw HistoryStoreError.writeFailed }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { cString in
            sqlite3_bind_text(statement, index, cString, -1, destructor)
        }
    }

    private func bindDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func columnBool(_ statement: OpaquePointer?, _ index: Int32) -> Bool? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(statement, index) != 0
    }
}

public enum HistoryStoreFactory {
    /// Prefer sqlite3. If it cannot be opened, keep history as JSON-lines
    /// rather than dropping samples.
    public static func open(directory: URL) throws -> HistoryStoring {
        do {
            return try SQLiteHistoryStore(directory: directory)
        } catch {
            MeshLog.shape("SQLite history store did not open; using JSON-lines")
            return try JSONLinesHistoryStore(directory: directory)
        }
    }
}
