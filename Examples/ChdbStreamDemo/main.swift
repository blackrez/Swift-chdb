import Foundation
import Swift_chdb
import ClickhouseNative

/// Demo: using `streamQuery()` to process large result sets asynchronously,
/// and `query<T: Decodable>` to decode JSON results directly into Swift types.
///
/// This shows how streaming queries work in an async context — useful for
/// web servers (Vapor, Hummingbird, etc.) where you want to stream query
/// results to a client without buffering everything in memory.
///
/// Usage:
///   swift run chdb-stream-demo
///
/// Requires: macOS 10.15+ / iOS 13+ (for AsyncThrowingStream)

// MARK: - Model

/// A Swift type matching the rows in our demo table.
/// `query<T: Decodable>` automatically maps JSON to this.
struct StreamRow: Decodable {
    let id: Int32
    let value: Double
    let label: String
}

// MARK: - Connection setup

let db: ChdbConnection
do {
    db = try ChdbConnection()
} catch {
    print("Failed to connect to chDB: \(error)")
    exit(1)
}


// Seed some data for the demo
try await db.query("""
    CREATE TABLE IF NOT EXISTS stream_demo (
        id    Int32,
        value Float64,
        label String
    ) ENGINE = Memory
    """)

try await db.query("TRUNCATE TABLE stream_demo")

// Insert 100k rows so there's enough data to see streaming in action
print("Inserting 100_000 rows...", terminator: " ")
try await db.query("""
    INSERT INTO stream_demo
    SELECT number, rand() / 1e9, 'row_' || toString(number)
    FROM system.numbers LIMIT 100_000
    """)
print("Done.\n")

// MARK: - Decodable query demo

print("=== Decodable query ===")

/// Decode a handful of rows directly into `[StreamRow]`.
/// The `query` overload automatically unwraps ClickHouse's `{"data": [...]}`
/// wrapper when using the default `keyPath: "data"`.
let sampleRows: [StreamRow] = try await db.query(
    "SELECT id, value, label FROM stream_demo ORDER BY id LIMIT 5",
    format: .json)

for row in sampleRows {
    print("  id=\(row.id)  value=\(String(format: "%.4f", row.value))  label=\(row.label)")
}

// Also decode a scalar value using .native format + ClickhouseBlock
let countResult = try await db.query("SELECT count() AS cnt FROM stream_demo", format: .native)
let countBlock = try! ClickhouseBlock.read(from: countResult.rawData!)!
let count = countBlock["cnt"]?.uint64Values?.first ?? 0
print("  Total rows in table: \(count)\n")

// MARK: - Streaming query demo

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
func runStreamingDemo() async throws {
    var totalRows = 0
    var chunkCount = 0
    var totalElapsed: Double = 0

    // Stream the data in chunks — process each as it arrives
    // instead of waiting for the entire result set.
    let stream = await db.streamQuery(
        "SELECT id, value, label FROM stream_demo ORDER BY id",
        format: .csv
    )
    for try await chunk in stream {
        chunkCount += 1
        totalRows += Int(chunk.rowsRead)
        totalElapsed += chunk.elapsed

        // Count rows in this chunk by counting newlines in the CSV text
        if let text = chunk.text {
            let lines = text.split(separator: "\n").count
            print("  Chunk \(chunkCount): \(lines) lines, "
                  + "\(chunk.elapsed.formattedElapsed) elapsed")
        }
    }

    print()
    print("=== Stream complete ===")
    print("Total chunks:   \(chunkCount)")
    print("Total rows:     \(totalRows)")
    print("Total elapsed:  \(totalElapsed.formattedElapsed)")
}

// MARK: - Run the async demo

if #available(macOS 10.15, *) {
    try await runStreamingDemo()
} else {
    print("Streaming requires macOS 10.15+")
}

// MARK: - Web server pattern (Vapor-style)

/// In a real web app (e.g. Vapor), you'd route a request to something like:
///
/// ```swift
/// app.get("api", "query") { req async throws -> Response in
///     let db = try await req.application.chdb.connection()
///
///     // Return a streaming response — each chunk is flushed to the client
///     // as it arrives from ClickHouse, without buffering the full result.
///     return Response(body: .init(stream: { writer in
///         for try await chunk in db.streamQuery(req.query["sql"] ?? "SELECT 1") {
///             try await writer.write(.buffer(.init(string: chunk.text ?? "")))
///         }
///         try await writer.write(.end)
///     }))
/// }
/// ```
///
/// The key benefit: with `streamQuery`, a 10-million-row query starts sending
/// data to the client immediately, rather than waiting for all rows to be
/// computed and buffered first. Memory stays O(chunk_size) regardless of
/// result-set size.

// MARK: - Formatting helpers

extension Double {
    var formattedElapsed: String {
        if self < 0.001 {
            return String(format: "%.1f µs", self * 1_000_000)
        } else if self < 1.0 {
            return String(format: "%.1f ms", self * 1_000)
        } else if self < 60.0 {
            return String(format: "%.2f s", self)
        } else {
            let minutes = Int(self) / 60
            let seconds = Int(self) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}
