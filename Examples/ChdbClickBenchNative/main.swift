import Foundation
import Swift_chdb
import ClickhouseNative

/// ClickBench — all queries in .native format, parsed via ClickhouseBlock.
///
/// Reads SQL from files (sql/create.sql, sql/insert.sql, sql/queries.sql)
/// and runs the 43 official ClickBench queries on the hits.parquet dataset.
///
/// Two modes:
///   --parquet            – imports hits.parquet into a MergeTree table, then benchmarks
///   --parquet-direct     – queries hits.parquet directly via file() table function
///
/// Usage:
///   swift run chdb-clickbench-native --parquet              # Import then benchmark
///   swift run chdb-clickbench-native --parquet-direct       # Direct file() mode
///   swift run chdb-clickbench-native --parquet --quick      # Quick subset (10 queries)
///   swift run chdb-clickbench-native --parquet --parquet-path /data/hits.parquet  # Custom path

// MARK: - Configuration

enum Mode {
    case parquetImport
    case parquetDirect
}

struct Config {
    var mode: Mode = .parquetImport
    var full: Bool = true
    var path: String = ":memory:"
    var parquetPath: String = "./hits.parquet"
    var sqlDir: String = "./sql"
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments.dropFirst()
    var iter = args.makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--quick":
            config.full = false
        case "--path":
            config.path = iter.next() ?? ":memory:"
        case "--parquet":
            config.mode = .parquetImport
        case "--parquet-direct":
            config.mode = .parquetDirect
        case "--parquet-path":
            config.parquetPath = iter.next() ?? config.parquetPath
        case "--sql-dir":
            config.sqlDir = iter.next() ?? config.sqlDir
        default:
            break
        }
    }
    return config
}

func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    return FileManager.default.currentDirectoryPath + "/" + path
}

let config = parseArgs()

// MARK: - Read SQL files

let sqlDir = resolvePath(config.sqlDir)

func readSQLFile(_ name: String) throws -> String {
    let path = sqlDir + "/" + name
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8)
    else {
        throw ChdbError.queryFailed("Cannot read SQL file: \(path)")
    }
    return content
}

let createSQL: String = try readSQLFile("create.sql")
let insertSQLTemplate: String = try readSQLFile("insert.sql")
let queriesFile: String = try readSQLFile("queries.sql")

let parquetFile = resolvePath(config.parquetPath)
let insertSQL = insertSQLTemplate
    .replacingOccurrences(of: "__PARQUET_PATH__", with: parquetFile)
    .trimmingCharacters(in: .whitespacesAndNewlines)

let queries: [String] = queriesFile
    .components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty && !$0.hasPrefix("--") }

print("⚡ chDB ClickBench — Native format")
print("   Mode: \(config.mode == .parquetImport ? "import (MergeTree)" : "direct file()")")
print("   Parquet: \(parquetFile)")
print("   SQL dir: \(sqlDir)")
print("   Queries: \(queries.count) total, \(config.full ? "all" : "10 (--quick)")")
print()

// MARK: - Connection

let db: ChdbConnection
do { db = try ChdbConnection(path: config.path) } catch {
    print("❌ Failed to connect: \(error)"); exit(1)
}

// MARK: - Setup

switch config.mode {
case .parquetImport:
    print("Creating table...", terminator: " ")
    try await db.query("DROP TABLE IF EXISTS hits")
    try await db.query(createSQL)
    print("Done.")

    print("Importing data...", terminator: " ")
    let importStart = CFAbsoluteTimeGetCurrent()
    try await db.query(insertSQL)
    let importTime = CFAbsoluteTimeGetCurrent() - importStart
    print("Done. (\(importTime.formattedElapsed))")

case .parquetDirect:
    print("Using direct file() mode — no setup needed.")
    print()
}

// Verify row count via Native format
let fromClause: String = config.mode == .parquetImport ? "hits" : "file('\(parquetFile)')"
let countBlock = try ClickhouseBlock.read(
    from: try await db.query("SELECT count() AS cnt FROM \(fromClause)", format: .native).rawData!)!
let count = Int(countBlock["cnt"]?.uint64Values?.first ?? 0)
print("   Row count: \(count.formatted) ✓")
print()

// MARK: - Select queries

let selectedQueries: [(Int, String)]
let quickSet: Set<Int> = [0, 1, 2, 4, 5, 6, 12, 19, 20, 29] // Q1-Q7, Q13, Q20, Q21, Q30
if config.full {
    selectedQueries = queries.enumerated().map { ($0.offset, $0.element) }
} else {
    selectedQueries = queries.enumerated().filter { quickSet.contains($0.offset) }
}

// Transform queries for direct mode
let finalQueries: [(Int, String)] = selectedQueries.map { (idx, sql) in
    if config.mode == .parquetDirect {
        let trimmed = sql.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        let modified = trimmed
            .replacingOccurrences(of: #"FROM hits\b"#, with: "FROM file('\(parquetFile)')", options: .regularExpression)
            .replacingOccurrences(of: #"FROM\hits\b"#, with: "FROM file('\(parquetFile)')", options: .regularExpression)
        let settings = " SETTINGS max_bytes_before_external_sort = 0, max_memory_usage = 0"
        return (idx, modified + settings)
    }
    return (idx, sql)
}

// MARK: - Run benchmark

print("| Query | Time | Cols | Rows | First values |")
print("|-------|------|------|------|-------------|")

var totalElapsed: Double = 0
var passed = 0
var failed = 0

for (idx, sql) in finalQueries {
    let qname = "Q\(idx + 1)"
    let start = CFAbsoluteTimeGetCurrent()
    do {
        let result = try await db.query(sql, format: .native)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        totalElapsed += elapsed

        guard result.errorMessage == nil else {
            print("| \(qname) | \(elapsed.formattedElapsed) | ❌ \(result.errorMessage!.prefix(60)) |")
            failed += 1
            continue
        }

        guard let rawData = result.rawData else {
            // Empty result set — not an error, just no matching rows
            print("| \(qname) | \(elapsed.formattedElapsed) | — | 0 | (empty) |")
            passed += 1
            continue
        }
        let block = try ClickhouseBlock.read(from: rawData)
        guard let block else {
            // Empty block (EOF) — also a legitimate empty result
            print("| \(qname) | \(elapsed.formattedElapsed) | — | 0 | (empty) |")
            passed += 1
            continue
        }
        let colSummary = block.columns.map(\.name).joined(separator: ", ")
        let preview: String
        if block.rowCount > 0, let firstCol = block.columns.first {
            preview = formatFirstValue(firstCol.column)
        } else {
            preview = "(empty)"
        }
        print("| \(qname) | \(elapsed.formattedElapsed) | \(block.columns.count) | \(block.rowCount) | \(preview) |")
        passed += 1
    } catch {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("| \(qname) | \(elapsed.formattedElapsed) | ❌ \(String(describing: error).prefix(60)) |")
        failed += 1
    }
}

// MARK: - Summary

print()
print("---")
print("**Total:** \(totalElapsed.formattedElapsed)")
print("**Passed:** \(passed)/\(finalQueries.count)")
if failed > 0 { print("**Failed:** \(failed)") }
print()

// MARK: - Helpers

func formatFirstValue(_ col: ClickhouseColumn) -> String {
    switch col {
    case .fixed(let data, let size):
        guard size > 0, data.count >= size else { return "(empty)" }
        switch size {
        case 1: return "\(data.withUnsafeBytes { $0.load(as: UInt8.self) })"
        case 4: return "\(data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })"
        case 8: return "\(data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian })"
        default: return "\(data.count / size) vals"
        }
    case .string(let s):
        return s.first.map { String($0.prefix(40)) } ?? "(empty)"
    case .nullable(_, let inner):
        return "nullable(\(formatFirstValue(inner)))"
    case .array(_, let values):
        return "arr(\(formatFirstValue(values)))"
    case .tuple(let children):
        return "tuple(\(children.count))"
    case .lowCardinality(_, let dict):
        return "lc(\(formatFirstValue(dict)))"
    case .nothing:
        return "(nothing)"
    }
}

extension Double {
    var formattedElapsed: String {
        if self < 0.001 { return String(format: "%.2f ms", self * 1_000) }
        if self < 1.0   { return String(format: "%.1f ms", self * 1_000) }
        if self < 60.0  { return String(format: "%.2f s", self) }
        return "\(Int(self) / 60)m \(Int(self) % 60)s"
    }
}

extension Int {
    var formatted: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
