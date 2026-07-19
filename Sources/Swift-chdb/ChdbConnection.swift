import Foundation
import Cchdb
import ClickhouseNative
import NIOPosix

/// Supported ClickHouse output formats for query results.
public enum ChdbFormat: String, Sendable, CaseIterable, CustomStringConvertible {
    case csv = "CSV"
    case tsv = "TSV"
    case json = "JSON"
    case jsonEachRow = "JSONEachRow"
    case native = "Native"
    case pretty = "Pretty"
    case prettyCompact = "PrettyCompact"
    case prettyCompactNoEscapes = "PrettyCompactNoEscapes"
    case vertical = "Vertical"
    case xml = "XML"
    case null = "Null"
    case tabSeparated = "TabSeparated"
    case tabSeparatedRaw = "TabSeparatedRaw"
    case values = "Values"
    public var description: String { rawValue }
}

/// Container for the C connection state. @unchecked Sendable required for C pointers.
/// Actor deinit runs only after all actor-isolated work completes — no race with close().
private final class ConnState: @unchecked Sendable {
    var connPtr: UnsafeMutablePointer<chdb_connection?>?
    var conn: chdb_connection?
}

/// Context captured from the actor for a read query — allows concurrent execution.
private struct ReadCtx: @unchecked Sendable {
    let conn: chdb_connection
    let alive: Bool
    let pool: NIOThreadPool
}

/// An actor that manages a connection to an embedded chDB (ClickHouse) instance.
///
/// **Read queries** (`query(_:format:)`) are `nonisolated` — they capture the
/// connection handle from the actor (fast, non-blocking) and execute on a
/// **multi-threaded NIOThreadPool** (`coreCount` threads). This allows multiple
/// read queries to run concurrently.
///
/// **Write operations** (`close()`, and methods calling INSERT/CREATE/DROP) are
/// actor-isolated and execute on a **single-threaded write pool**, guaranteeing
/// serialised access to mutable C state.
///
/// Blocking ``chdb_query()`` calls are offloaded to the thread pools so the
/// Swift cooperative thread pool is never blocked.
public actor ChdbConnection {
    private let _state = ConnState()
    private let readPool: NIOThreadPool
    private let writePool: NIOThreadPool

    // MARK: - Init / Deinit

    public nonisolated let databasePath: String
    public nonisolated var isPersistent: Bool { databasePath != ":memory:" }
    public var defaultEngine: ChdbEngine = .memory

    public init(path: String = ":memory:") throws {
        self.databasePath = path
        let coreCount = ProcessInfo.processInfo.processorCount
        self.readPool = NIOThreadPool(numberOfThreads: max(coreCount, 2))
        self.writePool = NIOThreadPool(numberOfThreads: 1)
        self.readPool.start()
        self.writePool.start()

        let args = ["chdb", "--path=\(path)"]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        let ptr = cargs.withUnsafeMutableBufferPointer { buf in
            chdb_connect(Int32(buf.count), buf.baseAddress)
        }
        guard let ptr else { throw ChdbError.connectionFailed(nil) }
        _state.connPtr = ptr
        _state.conn = ptr.pointee
    }

    deinit {
        readPool.shutdownGracefully(queue: .global()) { _ in }
        writePool.shutdownGracefully(queue: .global()) { _ in }
        if let ptr = _state.connPtr { chdb_close_conn(ptr) }
    }

    // MARK: - Internals

    /// Fast actor-internal read: captures connection + read pool for concurrent execution.
    private func _readCtx() -> ReadCtx? {
        guard let conn = _state.conn else { return nil }
        return ReadCtx(conn: conn, alive: _state.connPtr != nil, pool: readPool)
    }

    private var conn: chdb_connection? { _state.conn }
    private func ensureOpen() throws -> chdb_connection {
        guard let conn else { throw ChdbError.connectionClosed }
        return conn
    }

    // MARK: - Read Query (concurrent)

    /// Executes a read SQL query on the multi-threaded pool (concurrent).
    /// Captures the connection from the actor (fast) then offloads to the thread pool.
    public nonisolated func query(_ sql: String, format: ChdbFormat = .csv) async throws -> ChdbResult {
        guard let ctx = await _readCtx() else { throw ChdbError.connectionClosed }
        let fmt = format.rawValue
        return try await ctx.pool.runIfActive {
            guard ctx.alive else { throw ChdbError.connectionClosed }
            let raw = chdb_query(ctx.conn, sql, fmt)
            let result = ChdbResult(consuming: raw)
            if let error = result.errorMessage { throw ChdbError.queryFailed(error) }
            return result
        }
    }

    /// Executes a SQL query with parameter binding on the multi-threaded pool.
    public nonisolated func query(_ sql: String, format: ChdbFormat = .csv, params: [String: String]) async throws -> ChdbResult {
        guard let ctx = await _readCtx() else { throw ChdbError.connectionClosed }
        let names = Array(params.keys)
        let values = Array(params.values)
        let count = params.count
        let fmt = format.rawValue
        return try await ctx.pool.runIfActive {
            guard ctx.alive else { throw ChdbError.connectionClosed }
            let cNamesMut: [UnsafeMutablePointer<CChar>?] = names.map { strdup($0) }
            let cValuesMut: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
            defer { cNamesMut.forEach { free($0) }; cValuesMut.forEach { free($0) } }
            for p in cNamesMut { guard p != nil else { throw ChdbError.queryFailed("out of memory") } }
            for p in cValuesMut { guard p != nil else { throw ChdbError.queryFailed("out of memory") } }
            let cNames: [UnsafePointer<CChar>?] = cNamesMut.map { UnsafePointer($0) }
            let cValues: [UnsafePointer<CChar>?] = cValuesMut.map { UnsafePointer($0) }
            let raw = cNames.withUnsafeBufferPointer { namesBuf in
                cValues.withUnsafeBufferPointer { valuesBuf in
                    chdb_query_with_params(ctx.conn, sql, fmt, namesBuf.baseAddress, valuesBuf.baseAddress, count)
                }
            }
            let result = ChdbResult(consuming: raw)
            if let error = result.errorMessage { throw ChdbError.queryFailed(error) }
            return result
        }
    }

    // MARK: - Decodable Query

    public nonisolated func query<T: Decodable>(_ sql: String, format: ChdbFormat = .native) async throws -> T {
        let result = try await query(sql, format: format)
        guard let data = result.rawData else {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: "Query returned no data"))
        }
        guard let block = try ClickhouseBlock.read(from: data) else {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: "Query returned no block (EOF)"))
        }
        return try block.decode(T.self)
    }

    // MARK: - Streaming Query

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func streamQuery(_ sql: String, format: ChdbFormat = .csv) -> AsyncThrowingStream<ChdbResult, Error> {
        guard let conn = _state.conn else {
            return AsyncThrowingStream { $0.finish(throwing: ChdbError.connectionClosed) }
        }
        let state = StreamState()
        let connRef = ConnRef(value: conn)
        return AsyncThrowingStream { continuation in
            Task { [self] in
                await Self.runStream(connRef: connRef, state: state, sql: sql, format: format.rawValue, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak state, connRef] _ in
                guard let state else { return }; let raw = state.withCurrent { $0 }
                guard let current = raw else { return }; chdb_stream_cancel_query(connRef.value, current)
                state.withCurrent { $0 = nil }
            }
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private nonisolated static func runStream(
        connRef: ConnRef, state: StreamState, sql: String, format: String,
        continuation: AsyncThrowingStream<ChdbResult, Error>.Continuation
    ) async {
        let conn = connRef.value
        guard let first = chdb_stream_query(conn, sql, format) else {
            continuation.finish(throwing: ChdbError.queryFailed("stream failed to initialise")); return
        }
        state.withCurrent { $0 = first }; var current: UnsafeMutablePointer<chdb_result>? = first; var isFirst = true
        while let raw = current {
            let result = ChdbResult(copying: raw)
            if let error = result.errorMessage {
                chdb_stream_cancel_query(conn, raw); chdb_destroy_query_result(raw)
                state.withCurrent { $0 = nil }; continuation.finish(throwing: ChdbError.queryFailed(error)); return
            }
            if !isFirst, result.rawData?.isEmpty ?? true {
                chdb_destroy_query_result(raw); state.withCurrent { $0 = nil }; continuation.finish(); return
            }
            isFirst = false; continuation.yield(result)
            current = chdb_stream_fetch_result(conn, raw); chdb_destroy_query_result(raw)
            state.withCurrent { $0 = current }
        }
        state.withCurrent { $0 = nil }; continuation.finish()
    }

    // MARK: - Database Introspection

    public func listTables() async throws -> [(name: String, engine: String, rows: UInt64, bytes: UInt64)] {
        let result = try await query("SELECT name, engine, total_rows, bytes FROM system.tables WHERE database = currentDatabase() ORDER BY name", format: .native)
        guard let data = result.rawData, let block = try ClickhouseBlock.read(from: data) else { return [] }
        let names = block["name"]?.stringValues ?? []
        let engines = block["engine"]?.stringValues ?? []
        let rc = names.count
        func readNN(_ col: String) -> [UInt64] {
            guard let c = block[col] else { return [] }
            if let n = c.nullableUInt64Values { return n.map { $0 ?? 0 } }
            return c.uint64Values ?? []
        }
        let rows = readNN("total_rows"), bytes = readNN("bytes")
        return (0..<rc).map { i in (i < names.count ? names[i] : "", i < engines.count ? engines[i] : "", i < rows.count ? rows[i] : 0, i < bytes.count ? bytes[i] : 0) }
    }

    public func tableSize(_ table: String) async throws -> UInt64 {
        let result = try await query("SELECT bytes FROM system.tables WHERE database = currentDatabase() AND name = {name:String}", format: .native, params: ["name": table])
        guard let data = result.rawData, let block = try ClickhouseBlock.read(from: data) else { return 0 }
        if let nullable = block["bytes"]?.nullableUInt64Values { for v in nullable { if let v { return v } }; return 0 }
        return block["bytes"]?.uint64Values?.first ?? 0
    }

    // MARK: - Table Management (serialised via write pool)

    @discardableResult
    public func createTable(_ name: String, columns: [String: String], engine: ChdbEngine? = nil, orderBy: [String]? = nil, primaryKey: [String]? = nil) async throws -> String {
        let eng = engine ?? defaultEngine
        let colDefs = columns.map { "    \($0.key) \($0.value)" }.joined(separator: ",\n")
        var sql = "CREATE TABLE IF NOT EXISTS \(name) (\n\(colDefs)\n) ENGINE = \(eng.rawValue)"
        if let pk = primaryKey, !pk.isEmpty { sql += "\nPRIMARY KEY (\(pk.joined(separator: ", ")))" }
        if let ob = orderBy, !ob.isEmpty { sql += "\nORDER BY (\(ob.joined(separator: ", ")))" }
        else if eng.requiresOrderBy {
            if let pk = primaryKey, !pk.isEmpty { sql += "\nORDER BY (\(pk.joined(separator: ", ")))" }
            else if let fc = columns.keys.first { sql += "\nORDER BY (\(fc))" }
        }
        // Write queries go through the serialised write pool
        try await _writeQuery(sql)
        return sql
    }

    /// Execute a write query (INSERT, CREATE, DROP) on the serialised write pool.
    private func _writeQuery(_ sql: String, format: ChdbFormat = .csv) async throws -> ChdbResult {
        let conn = try ensureOpen()
        let safeConn = SafeConn(value: conn)
        let fmt = format.rawValue
        return try await writePool.runIfActive {
            let raw = chdb_query(safeConn.value, sql, fmt)
            let result = ChdbResult(consuming: raw)
            if let error = result.errorMessage { throw ChdbError.queryFailed(error) }
            return result
        }
    }

    // MARK: - Connection Management

    public func close() {
        guard let ptr = _state.connPtr else { return }
        chdb_close_conn(ptr)
        _state.connPtr = nil; _state.conn = nil
    }

    public var isClosed: Bool { _state.connPtr == nil }
}

// MARK: - Sendable wrappers

private struct SafeConn: @unchecked Sendable { let value: chdb_connection }

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private struct ConnRef: @unchecked Sendable { let value: chdb_connection }

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    var current: UnsafeMutablePointer<chdb_result>?
    func withCurrent<T>(_ body: (inout UnsafeMutablePointer<chdb_result>?) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&current)
    }
}
