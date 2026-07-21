import Foundation
import Cchdb

/// The result of a chDB query execution, containing output data and execution metrics.
public struct ChdbResult: Sendable {
    /// The raw query output bytes (nil if empty or errored).
    /// For text-based formats (CSV, JSON, PrettyCompact, etc.), use ``text`` instead.
    /// For binary formats (Native, Arrow, Parquet, etc.), use this property directly.
    ///
    /// This is the single source of truth; ``text`` derives a UTF-8 string from it.
    private let _outputBuffer: Data?

    /// The query output as a UTF-8 string (nil if the result was empty or binary-only).
    /// Only valid for text-based formats (CSV, JSON, PrettyCompact, etc.).
    /// For binary formats (Native, Arrow, etc.), use ``rawData`` instead.
    public var text: String? {
        _outputBuffer.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Raw binary output data (nil if the result was empty or an error).
    /// Use this for binary formats like Native, Arrow, Parquet, etc.
    /// For text-based formats, ``text`` is more convenient.
    public var rawData: Data? { _outputBuffer }

    /// Query execution time in seconds.
    public let elapsed: Double

    /// Number of rows read during query execution.
    public let rowsRead: UInt64

    /// Number of bytes read during query execution.
    public let bytesRead: UInt64

    /// Error message if the query failed, nil otherwise.
    public let errorMessage: String?

    /// Creates a result by taking ownership of a raw C result pointer.
    /// The C result is freed during this initializer.
    /// - Parameter raw: The `chdb_result` pointer to consume.
    init(consuming raw: UnsafeMutablePointer<chdb_result>?) {
        self = ChdbResult(copying: raw)
        _safeDestroy(raw)
    }

    /// Creates a result from already-decoded values (used by streaming accumulator).
    init(rawData: Data?, elapsed: Double, rowsRead: UInt64, bytesRead: UInt64, errorMessage: String?) {
        self._outputBuffer = rawData
        self.elapsed = elapsed
        self.rowsRead = rowsRead
        self.bytesRead = bytesRead
        self.errorMessage = errorMessage
    }
    init(copying raw: UnsafeMutablePointer<chdb_result>?) {
        guard let raw else {
            self._outputBuffer = nil
            self.elapsed = 0
            self.rowsRead = 0
            self.bytesRead = 0
            self.errorMessage = "nil result"
            return
        }

        // Read error message first
        let errPtr = chdb_result_error(raw)
        if let errPtr, errPtr.pointee != 0 {
            self.errorMessage = String(cString: errPtr)
            self._outputBuffer = nil
        } else {
            self.errorMessage = nil
            // Read the output buffer
            let bufPtr = chdb_result_buffer(raw)
            let len = chdb_result_length(raw)
            if let bufPtr, len > 0 {
                self._outputBuffer = Data(bytes: bufPtr, count: len)
            } else {
                self._outputBuffer = nil
            }
        }

        // Read metrics
        self.elapsed = chdb_result_elapsed(raw)
        self.rowsRead = chdb_result_rows_read(raw)
        self.bytesRead = chdb_result_bytes_read(raw)
    }
}

// MARK: - Diagnostics

/// Safely destroy a chdb_result.
/// The chdb_destroy_query_result function handles freeing all internal resources
/// regardless of which allocator was used internally.
func _safeDestroy(_ raw: UnsafeMutablePointer<chdb_result>?) {
    guard let raw else { return }
    chdb_destroy_query_result(raw)
}

func _safeCancelStream(_ conn: chdb_connection, _ raw: UnsafeMutablePointer<chdb_result>?) {
    guard let raw else { return }
    chdb_stream_cancel_query(conn, raw)
}
