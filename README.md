# Swift-chDB

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo.png">
  <img src="logo.png" alt="Swift-chDB" width="400">
</picture>

> **Embedded ClickHouse for Swift** — run SQL analytics queries directly from Swift, no server required.

[![Swift](https://img.shields.io/badge/Swift-6.3+-F05138?logo=swift)](https://swift.org)
[![Platforms](https://img.shields.io/badge/macOS-15%2B-blue?logo=apple)](https://apple.com)
[![Linux](https://img.shields.io/badge/Linux-amd64%20%7C%20arm64-orange?logo=linux)](Dockerfile)
[![NIO](https://img.shields.io/badge/NIO-2.101-blueviolet)](https://github.com/apple/swift-nio)

---

## ✨ Features

- 🚀 **Zero server** — chDB runs in-process, no ClickHouse installation needed
- ⚡ **Native format** — ColumnarDecoder with zero-copy, no JSON intermediate
- 🔒 **Concurrent reads** — `nonisolated` + multi-threaded `NIOThreadPool` (N threads)
- 🐧 & 🍎 **Linux & macOS** — Dockerfile included for Linux testing
- 📊 **ClickBench** — 43 official queries, **35 ms** (CSV) / **22 ms** (Native)

## 🧠 What is ClickHouse?

[ClickHouse](https://clickhouse.com) is an open-source **column-oriented SQL database**
built for real-time analytics. Unlike traditional row-based databases (PostgreSQL,
SQLite), ClickHouse stores data by column, enabling **blazing-fast aggregations**,
filters, and scans over billions of rows. It powers analytics at companies like
Uber, eBay, and Cloudflare.

## 🧰 What is chDB?

[chDB](https://github.com/chdb-io/chdb) is **ClickHouse embedded** — the same
analytical engine packaged as a single C library. No server process,
no configuration, no network port. Just link the library and run SQL.

**Swift-chDB** wraps chDB in a modern Swift API with:
- Actor-based thread safety (Swift concurrency)
- NIOThreadPool for non-blocking query execution
- ColumnarDecoder for zero-copy native format decoding
- Full support for 53 ClickHouse data types
- MergeTree, Memory, ReplacingMergeTree, and 15+ table engines

## 📦 Installation

**Package.swift:**
```swift
dependencies: [
    .package(url: "https://github.com/blackrez/Swift-chdb.git", from: "main")
]
```

**Quick setup:**
```bash
git clone ... && cd Swift-chdb
./setup.sh            # Downloads chDB binary for your platform
swift build           # Build everything
swift test            # Run tests
```

## 🚀 Quick Start

### In-Memory
```swift
import Swift_chdb

let db = try Chdb()
let result = try await db.query("SELECT 'Hello, chDB!' AS greeting")
print(result.text ?? "")
```

### Persistent (MergeTree)
```swift
let db = try Chdb(path: "/tmp/mydb")
db.defaultEngine = .mergeTree

try await db.createTable("hits", columns: [
    "WatchID": "UInt64",
    "EventDate": "Date",
    "URL": "String",
], orderBy: ["EventDate", "WatchID"])

try await db.query("INSERT INTO hits VALUES (1, '2024-01-01', 'https://example.com')")
```

### Decodable (Native format, no JSON)
```swift
struct User: Decodable {
    let id: Int32
    let name: String
}

let users: [User] = try await db.query("SELECT id, name FROM users")
// ← ColumnarDecoder reads directly from columns, no intermediate format
```

## 📊 ClickBench — Analytical Benchmark

note : This does not reflect the real clickbench result and conditions.

```bash
# MergeTree mode (default) — imports hits.parquet then runs 43 queries
swift run chdb-clickbench --parquet

# Quick mode (10 queries)
swift run chdb-clickbench --parquet --quick

# Custom parquet file path
swift run chdb-clickbench --parquet --parquet-path /data/hits.parquet

# Direct file() mode — no import
swift run chdb-clickbench --parquet-direct

# Native format version (ClickhouseBlock)
swift run chdb-clickbench-native --parquet

# Options: --sql-dir PATH  → custom SQL files directory
#          --parquet PATH → custom parquet file path
#          --path PATH    → database storage path (default: /tmp/clickbench-UUID)
#                          Use --path :memory: for Memory engine (faster, no disk)
#                          If you hit NOT_ENOUGH_SPACE, use --path with a larger disk
```

Results (100K rows, 10 queries):

| Mode | Time | Queries |
|------|------|---------|
| Import Memory + CSV | **35 ms** | 43/43 ✅ |
| Import Memory + Native | **22 ms** | 43/43 ✅ |
| Direct file() + CSV | **35 ms** | 43/43 ✅ |
| Direct file() + Native | **22 ms** | 43/43 ✅ |

Full dataset (100M rows, 14 GB) with `--parquet-direct` + native: **~90s**, 43/43 ✅.

> ⚠️ Full dataset requires `SETTINGS max_bytes_before_external_sort = 0, max_memory_usage = 0` for GROUP BY queries on high-cardinality columns. This is automatically added in `--parquet-direct` mode.

**Benchmark environment:** Apple M1, 8 GB RAM, macOS 26.5.2, Swift 6.3.3, chDB 2.2.1 (326 MB).


## 🏛 Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Your App                           │
│     try await db.query("SELECT ...")                  │
├──────────────────────────────────────────────────────┤
│          ChdbConnection (Actor)                       │
│                                                       │
│  ┌─────────────────┐       ┌──────────────────────┐  │
│  │  _readCtx()      │ ───→ │ readPool (N threads)  │  │
│  │  + alive flag    │       │ chdb_query() → SELECT │  │
│  │  (nonisolated)   │       └──────────────────────┘  │
│  └─────────────────┘                                  │
│  ┌─────────────────┐       ┌──────────────────────┐  │
│  │  _writeQuery()   │ ───→ │ writePool (1 thread)  │  │
│  │  (actor-isolated)│       │ chdb_query() → INSERT │  │
│  └─────────────────┘       └──────────────────────┘  │
├──────────────────────────────────────────────────────┤
│              ClickhouseNative                         │
│  ┌────────────────┐  ┌──────────────────────────┐    │
│  │ ClickhouseBlock │  │ ColumnarDecoder           │    │
│  │ (columnar data) │─→│ (Decodable, zero JSON,   │    │
│  │  + zero-copy    │  │  53/53 types, zéro copie)│    │
│  └────────────────┘  └──────────────────────────┘    │
├──────────────────────────────────────────────────────┤
│              C chDB (libchdb.so)                      │
│         chdb_query(), chdb_connect()                  │
└──────────────────────────────────────────────────────┘
```

### Concurrent Reads

`query()` is `nonisolated` — it captures the connection handle from the actor
(via `_readCtx()`, a fast microsecond read) and executes on a **multi-threaded**
read pool (`coreCount` threads). Multiple SELECTs can run simultaneously:

```swift
// These 3 queries run concurrently on readPool:
async let r1 = db.query("SELECT count(*) FROM hits")
async let r2 = db.query("SELECT count(DISTINCT UserID) FROM hits")
async let r3 = db.query("SELECT URL, count(*) FROM hits GROUP BY URL LIMIT 10")
let results = try await (r1, r2, r3)  // completes in ~max(r1,r2,r3) time
```

### Thread Safety

| Mechanism | Problem Solved |
|-----------|---------------|
| **Actor** | Serializes writes (close, INSERT, CREATE) and connection state |
| **nonisolated reads** | Reads bypass actor serialization — concurrent SELECTs |
| **readPool (N threads)** | `chdb_query()` offloaded, multiple queries in parallel |
| **writePool (1 thread)** | DDL/DML serialized, no write conflicts |
| **Alive flag** | Use-after-free prevented: checked before and after pool dispatch |
| **Self capture** | Actor stays alive for the stream's full duration |
| **ColumnarDecoder** | `as?` instead of `as!` — no crash on type mismatch |

## 📚 API

### ChdbConnection

| Method | Description |
|--------|-------------|
| `init(path:)` | Connect to chDB (`:memory:` by default) |
| `query(_:format:)` | Execute SQL → `ChdbResult` |
| `query(_:format:params:)` | Query with named parameter binding |
| `query<T: Decodable>(_:format:)` | Query → Decodable (native format) |
| `streamQuery(_:format:)` | `AsyncThrowingStream` of result chunks |
| `listTables()` | List tables with metadata (engine, rows, bytes) |
| `tableSize(_:)` | On-disk size of a table |
| `createTable(_:columns:engine:orderBy:)` | Typed table creation |
| `close()` | Close the connection |

### Properties

| Property | Description |
|----------|-------------|
| `databasePath` | Database path |
| `isPersistent` | `true` if path ≠ `:memory:` |
| `defaultEngine` | Default table engine (`.memory`, `.mergeTree`, etc.) |
| `isClosed` | Connection state |

### ChdbEngine

`.memory`, `.mergeTree`, `.replacingMergeTree`, `.summingMergeTree`,
`.aggregatingMergeTree`, `.collapsingMergeTree`, `.versionedCollapsingMergeTree`,
`.graphiteMergeTree`, `.buffer`, `.set`, `.join`, `.view`,
`.materializedView`, `.distributed`

### ChdbFormat

`.csv`, `.tsv`, `.json`, `.jsonEachRow`, `.native`, `.pretty`,
`.prettyCompact`, `.vertical`, `.xml`, `.null`, `.tabSeparated`, `.values`

## 🐧 Linux

### Supported architectures

| Architecture | Status | How |
|-------------|--------|-----|
| **amd64** (x86_64) | ✅ Tested via Docker | Download from [chDB releases](https://github.com/chdb-io/chdb/releases) |
| **arm64** (aarch64) | ✅ Supported | Use `libchdb-linux-arm64.tar.gz` |

### Docker (recommended)

```bash
./setup.sh                  # Auto-detect OS + architecture
# Or explicitly:
./setup.sh --linux-amd64    # Linux x86_64
./setup.sh --linux-arm64    # Linux ARM64
./setup.sh --macos-arm64    # macOS Apple Silicon
./setup.sh --macos-x86_64   # macOS Intel

docker build -t swift-chdb .
docker run --rm -it swift-chdb swift run chdb-clickbench --parquet --quick
```

The Dockerfile downloads `libchdb-linux-amd64.tar.gz` automatically.
For arm64, edit the URL in the `Dockerfile` to `libchdb-linux-arm64.tar.gz`.

### Native installation

```bash
# 1. Download libchdb for your architecture
./setup.sh --linux-amd64   # or --linux-arm64

# 2. Install system-wide
sudo cp libchdb.so /usr/lib/
sudo cp chdb.h /usr/include/
sudo ldconfig

# 3. Create pkg-config file
sudo mkdir -p /usr/lib/pkgconfig
cat | sudo tee /usr/lib/pkgconfig/chdb.pc << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: chdb
Description: ClickHouse embedded database library
Version: 1.0.0
Libs: -L${libdir} -lchdb
Cflags: -I${includedir}
EOF

# 4. Build
swift build -c release
```

The `Package.swift` auto-detects the platform:
- **macOS** → `chdb.xcframework` (binary target)
- **Linux** → `Clibchdb` (system library + `libchdb.so` via pkg-config)

> ⚠️ `ChdbWebDemo` requires `Network.framework` (Apple) → macOS only.

## 🔬 Supported Types

**53/53 ClickHouse types** — parsing, decoding, and JSON conversion.

| Category | ClickHouse Types | Swift Type |
|----------|-----------------|------------|
| Integers | Int8, Int16, Int32, Int64 | `Int8`, `Int16`, `Int32`, `Int64` |
| | Int128, Int256 | `String` (hex) |
| | UInt8, UInt16, UInt32 | `UInt8`, `UInt16`, `UInt32` |
| | UInt64 | `UInt64` / `NSNumber` |
| | UInt128, UInt256 | `String` (hex) |
| Floats | Float32, Float64 | `Float`, `Double` |
| | BFloat16 | `Float` (converted) |
| Bool | Bool | `Bool` |
| Date/Time | Date, Date32 | `Int` (days since epoch) |
| | DateTime | `Int` (Unix timestamp) |
| | DateTime64 | `Double` (fractional) |
| | Time, Time64 | `Int` |
| String | String | `String` |
| | FixedString(N) | `String` (padded) |
| Decimal | Decimal32/64/128/256 | `String` |
| Network | UUID | `String` (`xxxxxxxx-...`) |
| | IPv4, IPv6 | `String` |
| Enum | Enum8, Enum16 | `String` |
| Compound | Array(T) | `[T]` |
| | Tuple | `[Any]` or `Decodable` |
| | Map(K,V) | `[(K, V)]` |
| | Nullable(T) | `T?` / `NSNull` |
| | LowCardinality(T) | `T` |
| Geo | Point | `[Double]` (lat, lon) |
| | Ring | `[[Double]]` |
| | Polygon | `[[[Double]]]` |
| | MultiPolygon | `[[[[Double]]]]` |
| Modern | Variant, Dynamic | ❌ Not yet supported by C lib |
| | JSON, Object | `String` (string mode) |
| Aggregate | AggregateFunction | ❌ Not yet supported by C lib |
| | SimpleAggregateFunction | inner type |
| Other | Interval | `Int` |
| | QBit | `Int` |
| | Nothing | empty / `nil` |

> ❌ `Variant`, `Dynamic`, `AggregateFunction`: C-level decoding not yet supported by the current library build.

## 🔧 Dependencies

| Package | Version | Usage |
|---------|---------|-------|
| [swift-nio](https://github.com/apple/swift-nio) | ≥ 2.101 | `NIOThreadPool` for offloading blocking C calls |

## 📄 License

MIT


> **Trademarks:** ClickHouse® is a registered trademark of ClickHouse Inc.  
> chDB is a project of [chdb-io](https://github.com/chdb-io/chdb).  
> Swift and the Swift logo are trademarks of Apple Inc.  
> Linux® is a registered trademark of Linus Torvalds.  
>
> **Copyrights:** Portions of this software are based on
> [ClickHouse](https://github.com/ClickHouse/ClickHouse) © 2016-2025 ClickHouse Inc.
> and [chDB](https://github.com/chdb-io/chdb) © chdb-io,
> used in accordance with the Apache License, Version 2.0.
>
> **Swift-chDB is not affiliated with, endorsed by, or sponsored by ClickHouse Inc.**
