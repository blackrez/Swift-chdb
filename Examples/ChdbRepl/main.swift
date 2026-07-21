import Swift_chdb

print("chDB REPL — Stateless mode (no persistent connection)")
print("Type SQL queries or '.help' for help. Ctrl+D or '.quit' to exit.")
print()

let prompt = "chdb> "

repl: while true {
    print(prompt, terminator: "")
    guard let line = readLine() else {
        print()
        break
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }

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

    let result = ChdbConnection.query(sql: trimmed, format: .prettyCompact)
    if let errorMsg = result.errorMessage {
        print("Error: \(errorMsg)")
    } else if let text = result.text, !text.isEmpty {
        print(text)
    } else {
        print("Query executed successfully (no output).")
    }
    print("[\(result.elapsed.formattedElapsed) — \(result.rowsRead) rows, \(result.bytesRead.formattedBytes)]")
    print()
}

extension Double {
    var formattedElapsed: String {
        if self < 0.001 { return String(format: "%.1f µs", self * 1_000_000) }
        if self < 1.0   { return String(format: "%.1f ms", self * 1_000) }
        if self < 60.0  { return String(format: "%.2f s", self) }
        return "\(Int(self) / 60)m \(Int(self) % 60)s"
    }
}

extension UInt64 {
    var formattedBytes: String {
        if self < 1024 { return "\(self) B" }
        if self < 1024 * 1024 { return String(format: "%.1f KiB", Double(self) / 1024) }
        if self < 1024 * 1024 * 1024 { return String(format: "%.1f MiB", Double(self) / (1024 * 1024)) }
        return String(format: "%.2f GiB", Double(self) / (1024 * 1024 * 1024))
    }
}
