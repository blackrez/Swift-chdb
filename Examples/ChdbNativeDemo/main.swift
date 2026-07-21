import Foundation
import Swift_chdb
import ClickhouseNative

/// Demo: query chDB in Native format, then parse the binary result
/// with ClickhouseNative into typed Swift columns.

// 1. Connect to chDB
let db: ChdbConnection
do {
    db = try ChdbConnection()
} catch {
    print("Failed to connect to chDB: \(error)")
    exit(1)
}


print("=== chDB Native Format Demo ===")
print()

// 2. Create a table and insert data
try await db.query("""
    CREATE TABLE IF NOT EXISTS demo (
        id      Int32,
        name    String,
        score   Float64,
        active  UInt8
    ) ENGINE = Memory
    """)

try await db.query("INSERT INTO demo VALUES (1, 'Alice', 95.5, 1), (2, 'Bob', 87.0, 1), (3, 'Charlie', 72.3, 0)")

print("Data inserted. Querying in Native format...")
print()

// 3. Query in Native format
let result = try await db.query("SELECT id, name, score, active FROM demo ORDER BY id", format: .native)

guard let nativeData = result.rawData else {
    print("Error: no data returned from query")
    exit(1)
}

print("Got \(nativeData.count) bytes of Native format data")
print()

// 4. Parse the Native format bytes
guard let block = try ClickhouseBlock.read(from: nativeData) else {
    print("No block returned (EOF)")
    exit(1)
}

print("Block: \(block.rowCount) rows × \(block.columns.count) columns")
print()

// 5. Display typed columns

// Print header
for col in block.columns {
    print("  \(col.name): \(col.type.name) (\(col.type.kind))")
}
print()
print("--- Row data ---")
print()

// Row-by-row using typed accessors
for i in 0..<block.rowCount {
    guard let idCol = block["id"], let nameCol = block["name"],
          let scoreCol = block["score"], let activeCol = block["active"],
          let ids = idCol.int32Values, let names = nameCol.stringValues,
          let scores = scoreCol.doubleValues, let actives = activeCol.uint8Values else {
        print("  ⚠️ missing or mismatched column"); continue
    }
    let id    = ids[i]
    let name  = names[i]
    let score = scores[i]
    let active = actives[i] != 0

    print("  id=\(id)  name=\(name)  score=\(score)  active=\(active)")
}

print()
print("=== Demo complete ===")
