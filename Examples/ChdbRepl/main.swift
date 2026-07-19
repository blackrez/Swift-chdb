#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Swift_chdb

/// A simple interactive SQL REPL for chDB.
///
/// Usage:
///   swift run chdb-repl
///   swift run chdb-repl --path /tmp/mydb
///
/// Commands:
///   .quit / .exit / Ctrl+D  — exit the REPL
///   .help                   — show available commands
///
/// Everything else is executed as a SQL query.

let arguments = CommandLine.arguments.dropFirst()

var dbPath = ":memory:"
if let pathIndex = arguments.firstIndex(of: "--path"),
   pathIndex + 1 < arguments.count {
    dbPath = arguments[arguments.index(after: pathIndex)]
}

let db: ChdbConnection
do {
    db = try ChdbConnection(path: dbPath)
} catch {
    print("Failed to connect to chDB: \(error)")
    exit(1)
}

print("chDB REPL — Connected to: \(dbPath == ":memory:" ? "in-memory database" : dbPath)")
print("Type SQL queries or '.help' for help. Ctrl+D or '.quit' to exit.")
print()

let prompt = dbPath == ":memory:" ? "chdb> " : "\(dbPath)> "

repl: while true {
    print(prompt, terminator: "")
    guard let line = readLine() else {
        // EOF (Ctrl+D)
        print()
        break
    }

    let trimmed = line.trimmingCharacters(in: .whitespaces)

    guard !trimmed.isEmpty else { continue }

    // Handle meta commands
    switch trimmed.lowercased() {
    case ".quit", ".exit", ".q":
        break repl
    case ".help", ".h", "?":
        print("""
        Commands:
          .quit / .exit  — exit the REPL
          .help          — show this help

        SQL: enter any valid ClickHouse SQL query.
        """)
        continue
    default:
        break
    }

    do {
        let result = try await db.query(trimmed, format: .prettyCompact)

        if let errorMsg = result.errorMessage {
            print("Error: \(errorMsg)")
        } else if let text = result.text, !text.isEmpty {
            print(text)
        } else {
            print("Query executed successfully (no output).")
        }

        // Show metrics
        print("[\(result.elapsed.formattedElapsed) — \(result.rowsRead) rows, \(result.bytesRead.formattedBytes)]")
    } catch {
        print("Error: \(error)")
    }
    print()
}

// MARK: - Formatting helpers

extension Double {
    /// Formats elapsed time in a human-friendly way.
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

extension UInt64 {
    /// Formats byte counts in a human-friendly way.
    var formattedBytes: String {
        if self < 1024 {
            return "\(self) B"
        } else if self < 1024 * 1024 {
            return String(format: "%.1f KiB", Double(self) / 1024)
        } else if self < 1024 * 1024 * 1024 {
            return String(format: "%.1f MiB", Double(self) / (1024 * 1024))
        } else {
            return String(format: "%.2f GiB", Double(self) / (1024 * 1024 * 1024))
        }
    }
}
