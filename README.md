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
- MergeTree, Memory, and 45+ table engines (MergeTree family, Log, Kafka, S3, MySQL, PostgreSQL, EmbeddedRocksDB, SQLite, etc.)

## 📦 Installation

**Prerequisites:** Download the chDB dynamic library into the project:

```bash
./setup.sh --current-dynamic
```

This downloads `libchdb.dylib` (or `.so` on Linux) from chdb-core releases
and places it in `.local/lib/` inside the project. The build links it directly —
**no pkg-config, no system install required.**

Then add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/blackrez/Swift-chdb.git", branch: "main")
]
```

And to your target:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "Swift_chdb", package: "Swift-chdb"),
        .product(name: "ClickhouseNative", package: "Swift-chdb"),
    ]
)
```

> 💡 On Linux, add `libchdb.so` to your library path:
> `sudo ldconfig && swift build`

> **How it works:** `Package.swift` computes the absolute path to `.local/lib/libchdb.dylib`
> using `#filePath`, so the linker always finds the correct dylib regardless of
> the consumer's working directory. No pkg-config or system-wide install needed.

## 🏃‍➡️ Running examples

Examples are included as executable targets (not exposed as products, so they don't affect downstream builds). Run them locally:

```bash
# Interactive REPL
swift run ChdbRepl

# Native format demo
swift run ChdbNativeDemo

# Stream query demo
swift run ChdbStreamDemo

# ClickBench benchmark (requires hits.parquet)
swift run ChdbClickBench --parquet

# ClickBench with Native format
swift run ChdbClickBenchNative --parquet

# S3-backed storage demo (requires env vars)
export S3_BUCKET=my-bucket
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=eu-west-1
swift run ChdbS3Demo

# AWS Lambda deployment (see Examples/ChdbLambda/)
cd Examples/ChdbLambda
./scripts/build-and-deploy.sh
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

**Benchmark environment:** Apple M1, 8 GB RAM, macOS 26.5.2, Swift 6.3.3, chDB-core 26.5.0.


## 🏛 Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Your App                           │
│     try await db.query("SELECT ...")                  │
├──────────────────────────────────────────────────────┤
│          ChdbConnection (Actor)                       │
│                                                       │
│  ┌─────────────────────┐  ┌──────────────────────┐   │
│  │  query()            │  │  streamQuery()        │   │
│  │  → chdb_query()     │  │  → chdb_stream_query()│   │
│  │  (buffered)         │  │  → AsyncThrowingStream│   │
│  └─────────┬───────────┘  └───────────┬──────────┘   │
│            │                          │               │
│  ┌─────────▼──────────────────────────▼───────────┐   │
│  │          queryPool (1 NIO thread)               │   │
│  │  Serialised C calls — chDB is not reentrant     │   │
│  └────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────┤
│              ClickhouseNative                         │
│  ┌────────────────┐  ┌──────────────────────────┐    │
│  │ ClickhouseBlock │  │ ColumnarDecoder           │    │
│  │ (columnar data) │─→│ (Decodable, zero JSON,   │    │
│  │  + zero-copy    │  │  53/53 types)            │    │
│  └────────────────┘  └──────────────────────────┘    │
├──────────────────────────────────────────────────────┤
│              C chDB (libchdb.dylib)                   │
│      (.local/lib/libchdb.dylib — project-local)      │
└──────────────────────────────────────────────────────┘
```

### Query pipeline

| Method | C API | Used for |
|---|---|---|
| `query()` | `chdb_query` (buffered) | SELECT, DDL, DML — all SQL |
| `query(params:)` | `chdb_query_with_params` | Parameterised SQL |
| `streamQuery()` | `chdb_stream_query` + `chdb_stream_fetch_result` | Large result sets — yields `ChdbResult` chunks via `AsyncThrowingStream` |
| `ChdbConnection.query(sql:)` static | `chdb_query_cmdline` | Stateless one-shot queries, no connection |

> **Note:** `query()` does not use streaming internally. chDB ≤ 26.5 cannot mix
> `chdb_stream_query` with `chdb_query` on the same connection — a failed stream
> attempt corrupts the query context. When chDB fixes this, `query()` will switch
> to streaming with cancellation support and OOM-safe chunk accumulation.

### Concurrent Reads

### Thread Safety

| Mechanism | Problem Solved |
|-----------|---------------|
| **Actor** | Serializes all access to the C connection — no concurrent `chdb_query()` calls |
| **queryPool (1 thread)** | Offloads blocking C calls from Swift cooperative pool — single-threaded, serial |
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

`.memory`, `.null`, `.generateRandom`, `.view`, `.materializedView`, `.alias`, `.dictionary`,
`.mergeTree`, `.replacingMergeTree`, `.summingMergeTree`,
`.aggregatingMergeTree`, `.collapsingMergeTree`, `.versionedCollapsingMergeTree`,
`.graphiteMergeTree`, `.log`, `.stripeLog`, `.file`, `.url`, `.merge`,
`.executable`, `.kafka`, `.timeSeries`, `.windowView`, `.loop`,
`.mySQL`, `.postgreSQL`, `.materializedPostgreSQL`, `.mongoDB`, `.sqlite`,
`.redis`, `.odbc`, `.jdbc`, `.keeperMap`, `.ytSaurus`,
`.s3`, `.s3Queue`, `.iceberg`, `.deltaLake`, `.paimon`,
`.azureQueue`, `.objectStorage`, `.hudi`,
`.embeddedRocksDB`, `.buffer`, `.set`, `.join`, `.distributed`

### ChdbFormat

`.csv`, `.tsv`, `.json`, `.jsonEachRow`, `.native`, `.pretty`,
`.prettyCompact`, `.vertical`, `.xml`, `.null`, `.tabSeparated`, `.values`

## 🐧 Linux

For Linux, use the static library via `./setup.sh --current` (downloads `libchdb.a`
into `Cchdb.artifactbundle/`). Or for dynamic: `./setup.sh --current-dynamic`
(downloads `libchdb.so` into `.local/lib/`).

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
# 1. Download libchdb for your architecture (dynamic)
./setup.sh --current-dynamic

# This downloads libchdb.so into .local/lib/ and writes pkg-config.
# The build links it directly — no manual installation needed.

# 4. Build
swift build -c release
```

`Package.swift` computes the library path from `#filePath`:
- The dylib/so is expected at `.local/lib/` inside the package.

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
