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

/// Context captured from the actor for executing a query.
private struct QueryCtx: @unchecked Sendable {
    let conn: chdb_connection
    let alive: Bool
}

/// An actor that manages a connection to an embedded chDB (ClickHouse) instance.
///
/// All queries execute on a **single‑threaded `NIOThreadPool`** to guarantee
/// serialised access to the underlying C connection (chDB's `chdb_query()` is
/// not safe for concurrent calls on the same connection handle).
///
/// Blocking ``chdb_query()`` calls are offloaded to the thread pool so the
/// Swift cooperative thread pool is never blocked.
public actor ChdbConnection {
    private let _state = ConnState()
    private let queryPool: NIOThreadPool

    // MARK: - Init / Deinit

    public nonisolated let databasePath: String
    public nonisolated var isPersistent: Bool { databasePath != ":memory:" }
    public var defaultEngine: ChdbEngine = .memory

    /// chDB configuration. Provide a file path or inline YAML/XML content.
    public enum ChdbConfig: Sendable {
        /// Path to a configuration file (YAML or XML).
        /// Relative paths are resolved from the current working directory.
        case file(String)
        /// Inline configuration content (YAML or XML). Written to a temp file.
        case inline(String)

        /// Resolve to a `--config-file=path` argument, or nil if no config.
        func buildArg() throws -> String? {
            switch self {
            case .file(let path):
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ChdbError.connectionFailed("Config file not found: \(url.path)")
                }
                return "--config-file=\(url.path)"

            case .inline(let content):
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chdb-\(UUID().uuidString).yml")
                try content.write(to: tmp, atomically: true, encoding: .utf8)
                return "--config-file=\(tmp.path)"
            }
        }
    }

    /// Temporary directory created for `:memory:` mode, cleaned up on close.
    private let _tmpDBDir: String?

    private let memoryLimitMB: Int

    public init(path: String = ":memory:", config: ChdbConfig? = nil, memoryLimitMB: Int = 256) throws {
        let resolvedPath: String
        var tmpDir: String? = nil

        if path == ":memory:" {
            // chDB creates an on-disk directory named ":memory:" — use a real temp dir instead
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("chdb-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            resolvedPath = tmp.path
            tmpDir = resolvedPath
        } else {
            resolvedPath = path
        }

        self.databasePath = path  // keep the original ":memory:" for the public API
        self._tmpDBDir = tmpDir
        self.memoryLimitMB = memoryLimitMB
        self.queryPool = NIOThreadPool(numberOfThreads: 1)
        self.queryPool.start()

        var args = ["chdb", "--path=\(resolvedPath)"]
        if memoryLimitMB > 0 {
            args.append("--max_server_memory_usage=\(memoryLimitMB * 1_000_000)")
        }
        if let configArg = try config?.buildArg() {
            args.append(configArg)
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        for p in cargs { guard p != nil else { throw ChdbError.connectionFailed("out of memory") } }
        let ptr = cargs.withUnsafeMutableBufferPointer { buf in
            chdb_connect(Int32(buf.count), buf.baseAddress)
        }
        guard let ptr else { throw ChdbError.connectionFailed(nil) }
        _state.connPtr = ptr
        _state.conn = ptr.pointee
    }

    deinit {
        if let ptr = _state.connPtr.map(PtrBox.init(value:)) {
            _state.connPtr = nil
            _state.conn = nil
            let tmp = _tmpDBDir
            queryPool.shutdownGracefully(queue: .global()) { _ in
                chdb_close_conn(ptr.value)
                tmp.map { try? FileManager.default.removeItem(atPath: $0) }
            }
        } else {
            _state.connPtr = nil
            _state.conn = nil
            queryPool.shutdownGracefully(queue: .global()) { _ in }
        }
    }

    // MARK: - Internals

    /// Captures the connection for offloaded query execution.
    private func _queryCtx() -> QueryCtx? {
        guard let conn = _state.conn else { return nil }
        return QueryCtx(conn: conn, alive: _state.connPtr != nil)
    }

    private var conn: chdb_connection? { _state.conn }
    private func ensureOpen() throws -> chdb_connection {
        guard let conn else { throw ChdbError.connectionClosed }
        return conn
    }

    // MARK: - Read Query (concurrent)

    /// Executes a SQL query on the serial query pool.
    /// Uses streaming internally — buffers chunks in Swift, avoiding C-side OOM
    /// on large results. Cancellation-aware via `Task.isCancelled` checks.
    public func query(_ sql: String, format: ChdbFormat = .csv) async throws -> ChdbResult {
        guard let ctx = _queryCtx() else { throw ChdbError.connectionClosed }
        let fmt = format.rawValue
        return try await queryPool.runIfActive {
            guard ctx.alive else { throw ChdbError.connectionClosed }
            return try Self._bufferedQuery(conn: ctx.conn, sql: sql, format: fmt)
        }
    }

    /// Executes a SQL query with parameter binding on the serial query pool.
    /// Uses buffered `chdb_query_with_params` — params are typically used for
    /// DML/INSERT, not large result sets.
    public func query(_ sql: String, format: ChdbFormat = .csv, params: [String: String]) async throws -> ChdbResult {
        guard let ctx = _queryCtx() else { throw ChdbError.connectionClosed }
        let names = Array(params.keys)
        let values = Array(params.values)
        let count = params.count
        let fmt = format.rawValue
        return try await queryPool.runIfActive {
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

    // MARK: - Internal: buffered query

    /// Executes a buffered query via chdb_query.
    /// Note: chDB ≤ 26.5 cannot mix `chdb_stream_query` with `chdb_query` on the
    /// same connection — a failed streaming attempt corrupts the query context.
    /// When chDB fixes this, wire `_accumulateStream` into this path for
    /// cancellation-aware, OOM-safe large result streaming.
    private static func _bufferedQuery(conn: chdb_connection, sql: String, format: String) throws -> ChdbResult {
        guard let raw = chdb_query(conn, sql, format) else {
            throw ChdbError.queryFailed("query returned nil")
        }
        let result = ChdbResult(consuming: raw)
        if let error = result.errorMessage { throw ChdbError.queryFailed(error) }
        return result
    }

    // MARK: - Streaming helpers (for future use)

    /// Accumulates all chunks from a streaming query into a single ChdbResult.
    /// Ready to wire into ``_bufferedQuery`` when chDB supports mixing stream +
    /// buffered calls on the same connection.
    private static func _accumulateStream(conn: chdb_connection, first: UnsafeMutablePointer<chdb_result>) throws -> ChdbResult {
        var accumulator = Data()
        var totalRows: UInt64 = 0
        var totalBytes: UInt64 = 0
        var finalElapsed: Double = 0
        var streamError: String? = nil
        var current: UnsafeMutablePointer<chdb_result>? = first
        var isFirst = true

        while let raw = current {
            // Check for cooperative cancellation between chunks
            if Task.isCancelled {
                chdb_stream_cancel_query(conn, raw)
                throw ChdbError.queryFailed("cancelled")
            }

            let bufPtr = chdb_result_buffer(raw)
            let bufLen = chdb_result_length(raw)
            let errPtr = chdb_result_error(raw)

            if let errPtr, errPtr.pointee != 0 {
                streamError = String(cString: errPtr)
                chdb_stream_cancel_query(conn, raw)
                break
            }

            // EOF signal: empty buffer after the first chunk
            if !isFirst, bufLen == 0 {
                chdb_destroy_query_result(raw)
                break
            }

            if let bufPtr, bufLen > 0 {
                accumulator.append(UnsafeBufferPointer(start: UnsafeRawPointer(bufPtr).assumingMemoryBound(to: UInt8.self), count: bufLen))
            }

            totalRows += chdb_result_rows_read(raw)
            totalBytes += chdb_result_bytes_read(raw)
            finalElapsed = chdb_result_elapsed(raw)
            isFirst = false

            let next = chdb_stream_fetch_result(conn, raw)
            chdb_destroy_query_result(raw)
            current = next
        }

        if let streamError {
            throw ChdbError.queryFailed(streamError)
        }

        return ChdbResult(
            rawData: accumulator.isEmpty ? nil : accumulator,
            elapsed: finalElapsed,
            rowsRead: totalRows,
            bytesRead: totalBytes,
            errorMessage: nil
        )
    }

    // MARK: - Decodable Query

    public func query<T: Decodable>(_ sql: String, format: ChdbFormat = .native) async throws -> T {
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
            Task {
                await Self.runStream(connRef: connRef, state: state, sql: sql, format: format.rawValue, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak state, connRef] _ in
                guard let state else { return }; let raw = state.withCurrent { $0 }
                guard let current = raw else { return }; _safeCancelStream(connRef.value, current)
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
                _safeCancelStream(conn, raw)
                state.withCurrent { $0 = nil }; continuation.finish(throwing: ChdbError.queryFailed(error)); return
            }
            if !isFirst, result.rawData?.isEmpty ?? true {
                _safeDestroy(raw); state.withCurrent { $0 = nil }; continuation.finish(); return
            }
            isFirst = false; continuation.yield(result)
            current = chdb_stream_fetch_result(conn, raw); _safeDestroy(raw)
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

    /// Execute a write query (INSERT, CREATE, DROP) on the serial query pool.
    /// DDL/DML don't support streaming — uses buffered chdb_query.
    @discardableResult
    private func _writeQuery(_ sql: String, format: ChdbFormat = .csv) async throws -> ChdbResult {
        let conn = try ensureOpen()
        let safeConn = SafeConn(value: conn)
        let fmt = format.rawValue
        return try await queryPool.runIfActive {
            try Self._bufferedQuery(conn: safeConn.value, sql: sql, format: fmt)
        }
    }

    // MARK: - Connection Management

    public func close() async {
        guard let ptr = _state.connPtr else { return }
        let box = PtrBox(value: ptr)
        let tmp = _tmpDBDir
        _state.connPtr = nil
        _state.conn = nil
        await withCheckedContinuation { c in
            queryPool.shutdownGracefully(queue: .global()) { _ in
                chdb_close_conn(box.value)
                c.resume()
            }
        }
        // Clean up temp directory after connection is closed
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
    }

    public var isClosed: Bool { _state.connPtr == nil }
}

// MARK: - Sendable wrappers

private struct SafeConn: @unchecked Sendable { let value: chdb_connection }

/// Wraps an UnsafeMutablePointer for Sendable conformance.
private struct PtrBox<T>: @unchecked Sendable { let value: UnsafeMutablePointer<T> }

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

// MARK: - Stateless query (no connection needed)

extension ChdbConnection {
    /// Execute a one-shot SQL query without creating a persistent connection.
    /// Uses `chdb_query_cmdline()` — no memory pre-allocation, no OOM risk.
    /// Good for simple queries on small data.
    public static func query(sql: String, format: ChdbFormat = .csv) -> ChdbResult {
        let args = ["chdb", "--query=\(sql)", "--format=\(format.rawValue)"]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        for p in cargs { guard p != nil else { return ChdbResult(consuming: nil) } }
        let result = cargs.withUnsafeMutableBufferPointer { buf in
            chdb_query_cmdline(Int32(buf.count), buf.baseAddress)
        }
        return ChdbResult(consuming: result)
    }
}
