import Foundation
import Swift_chdb

/// ClickBench — the standard ClickHouse analytical benchmark.
///
/// Reads SQL from files (sql/create.sql, sql/insert.sql, sql/queries.sql)
/// and runs the 43 official ClickBench queries on the hits.parquet dataset.
///
/// Two modes:
///   --parquet            – imports hits.parquet into a Memory table, then benchmarks
///   --parquet-direct     – queries hits.parquet directly via file() table function
///
/// Usage:
///   swift run chdb-clickbench --parquet                  # Import (Memory engine)
///   swift run chdb-clickbench --parquet-direct           # Direct file() mode
///   swift run chdb-clickbench --parquet --quick          # Quick subset (10 queries)
///   swift run chdb-clickbench --parquet --path /tmp/clickbench  # MergeTree engine (disk)
///
/// SQL files location (configurable with --sql-dir):
///   sql/create.sql    — CREATE TABLE statement
///   sql/insert.sql    — INSERT ... FROM file('...')  (uses __PARQUET_PATH__ placeholder)
///   sql/queries.sql   — One SELECT query per line (43 queries)

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

print("⚡ chDB ClickBench")
print("   Mode: \(config.mode == .parquetImport ? "import (Memory)" : "direct file()")")
print("   Parquet: \(parquetFile)")
print("   SQL dir: \(sqlDir)")
print("   Queries: \(queries.count) total, \(config.full ? "all" : "10 (--quick)")")
print()

// MARK: - Connection

let db: ChdbConnection
do {
    db = try ChdbConnection(path: config.path)
} catch {
    print("❌ Failed to connect: \(error)")
    exit(1)
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

// Verify row count
let fromClause: String = config.mode == .parquetImport ? "hits" : "file('\(parquetFile)')"
let countResult = try await db.query("SELECT count() AS cnt FROM \(fromClause)", format: .csv)
let count = Int(countResult.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
print("   Row count: \(count.formatted) ✓")
print()

// MARK: - Select queries

let selectedQueries: [(Int, String)]
let quickSet: Set<Int> = [0, 1, 2, 4, 5, 6, 12, 19, 20, 29] // Q1, Q2, Q3, Q5, Q6, Q7, Q13, Q20, Q21, Q30
if config.full {
    selectedQueries = queries.enumerated().map { ($0.offset, $0.element) }
} else {
    selectedQueries = queries.enumerated().filter { quickSet.contains($0.offset) }
}

// Transform queries for direct mode
let finalQueries: [(Int, String)] = selectedQueries.map { (idx, sql) in
    if config.mode == .parquetDirect {
        // Strip trailing semicolons before adding SETTINGS
        let trimmed = sql.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let modified = trimmed
            .replacingOccurrences(of: #"FROM hits\b"#, with: "FROM file('\(parquetFile)')", options: .regularExpression)
            .replacingOccurrences(of: #"FROM\hits\b"#, with: "FROM file('\(parquetFile)')", options: .regularExpression)
        let settings = " SETTINGS max_bytes_before_external_sort = 0, max_memory_usage = 0"
        return (idx, modified + settings)
    }
    return (idx, sql)
}

// MARK: - Run benchmark

print("| Query | Time | Result |")
print("|-------|------|--------|")

var totalElapsed: Double = 0
var passed = 0
var failed = 0

for (idx, sql) in finalQueries {
    let qname = "Q\(idx + 1)"
    let start = CFAbsoluteTimeGetCurrent()
    do {
        let result = try await db.query(sql, format: .csv)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        totalElapsed += elapsed

        let rowCount = result.rowsRead
        let preview = result.text?.split(separator: "\n").prefix(2).joined(separator: " ↵ ") ?? ""
        let previewTrimmed = String(preview.prefix(60))
        print("| \(qname) | \(elapsed.formattedElapsed) | \(rowCount) rows \(previewTrimmed.isEmpty ? "" : "— \(previewTrimmed)") |")
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
if failed > 0 {
    print("**Failed:** \(failed)")
}
print()

// MARK: - Formatting

extension Double {
    var formattedElapsed: String {
        if self < 0.001 { return String(format: "%.2f ms", self * 1_000) }
        if self < 1.0   { return String(format: "%.1f ms", self * 1_000) }
        if self < 60.0  { return String(format: "%.2f s", self) }
        let m = Int(self) / 60
        let s = Int(self) % 60
        return "\(m)m \(s)s"
    }
}

extension Int {
    var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
