/// Supported ClickHouse table engines for use with ``ChdbConnection``.
///
/// Use with ``ChdbConnection/defaultEngine`` to set the engine used by
/// ``ChdbConnection/createTable(_:columns:engine:orderBy:primaryKey:)``,
/// or pass directly to that method.
///
/// Not all engines are suitable for the typed ``createTable`` helper —
/// engines with complex configuration (external databases, message queues,
/// object storage) are better created via raw ``query(_:)`` SQL.
///
/// ## Overview
///
/// ```swift
/// let db = try Chdb(path: "/tmp/bench")
/// db.defaultEngine = .mergeTree
///
/// // Uses MergeTree automatically:
/// try db.createTable("hits", columns: [
///     "WatchID": "BIGINT",
///     "EventDate": "DATE",
///     "URL": "TEXT",
/// ], orderBy: ["CounterID", "EventDate"])
/// ```
public enum ChdbEngine: String, Sendable, CaseIterable, CustomStringConvertible {

    // MARK: - In-Memory & Local

    /// In-memory table (default). Data is lost when the connection closes.
    /// Best for small lookup tables, temporary data, and benchmarks.
    case memory = "Memory"

    /// `/dev/null` engine — accepts data but discards it.
    /// Useful for performance testing or routing.
    case null = "Null"

    /// Generates random rows from the schema. No storage.
    /// Ideal for testing and data generation.
    case generateRandom = "GenerateRandom"

    /// Logical view over a `SELECT` query (no physical storage).
    case view = "View"

    /// Materialised view that stores results on disk.
    case materializedView = "MaterializedView"

    /// Creates an alias to an existing table or database.
    case alias = "Alias"

    /// Wraps an external dictionary for `dictGet` lookups.
    case dictionary = "Dictionary"

    // MARK: - Disk-Based

    /// The standard MergeTree engine for production use.
    /// Stores data on disk, supports primary keys, partitions, and replication.
    /// Requires a persistent ``ChdbConnection`` (non-`:memory:` path).
    ///
    /// - Requires: `ORDER BY` or `PRIMARY KEY` clause.
    case mergeTree = "MergeTree"

    /// Deduplicates rows with the same sorting key.
    /// Useful for idempotent inserts and change-data-capture pipelines.
    case replacingMergeTree = "ReplacingMergeTree"

    /// Pre-aggregates rows during insert using an aggregate function.
    /// Ideal for rollup tables and real-time analytics.
    case summingMergeTree = "SummingMergeTree"

    /// Stores pre-aggregated states for complex aggregations.
    /// Used with materialised views for incremental computation.
    case aggregatingMergeTree = "AggregatingMergeTree"

    /// Supports real-time row updates via a sign column.
    /// Rows with the same sorting key are collapsed based on sign.
    case collapsingMergeTree = "CollapsingMergeTree"

    /// Extends CollapsingMergeTree with version-based deduplication.
    case versionedCollapsingMergeTree = "VersionedCollapsingMergeTree"

    /// Optimised for Graphite metrics data (rollup trees).
    case graphiteMergeTree = "GraphiteMergeTree"

    /// Appends data to a single on-disk file. Low write throughput.
    /// Good for small ephemeral tables or quick exports.
    case log = "Log"

    /// Like Log but stripes writes across multiple files.
    /// Better read concurrency than Log.
    case stripeLog = "StripeLog"

    /// Reads/writes tabular data from a local file path.
    /// Supports CSV, TSV, Parquet, and other formats.
    case file = "File"

    /// Reads/writes data to/from a URL endpoint.
    case url = "URL"

    /// Combines multiple tables into a single virtual table.
    case merge = "Merge"

    /// Runs an external executable as a table source.
    case executable = "Executable"

    /// Consumes from a Kafka topic as a streaming source.
    /// - Requires: Kafka broker configuration.
    case kafka = "Kafka"

    /// Time-series optimized storage with retention policies.
    case timeSeries = "TimeSeries"

    /// Processes streaming window aggregations over time-based windows.
    case windowView = "WindowView"

    /// Loopback engine for testing and recursive queries.
    case loop = "Loop"

    // MARK: - External Databases

    /// Integrates a MySQL table as a data source.
    /// - Requires: MySQL server connection settings.
    case mySQL = "MySQL"

    /// Integrates a PostgreSQL table as a data source.
    /// - Requires: PostgreSQL connection settings.
    case postgreSQL = "PostgreSQL"

    /// Materialized PostgreSQL — mirrors a PostgreSQL table into ClickHouse.
    /// - Requires: PostgreSQL connection settings.
    case materializedPostgreSQL = "MaterializedPostgreSQL"

    /// Integrates a MongoDB collection as a data source.
    /// - Requires: MongoDB URI.
    case mongoDB = "MongoDB"

    /// Integrates a SQLite database as a data source.
    /// - Requires: SQLite file path.
    case sqlite = "SQLite"

    /// Integrates a Redis key-value store.
    /// - Requires: Redis host/port.
    case redis = "Redis"

    /// Integrates an ODBC-compatible data source.
    case odbc = "ODBC"

    /// Integrates a JDBC-compatible data source.
    case jdbc = "JDBC"

    /// Integrates a Keeper (ClickHouse Keeper) coordination map.
    case keeperMap = "KeeperMap"

    /// Integrates YTsaurus (Yandex) tables.
    case ytSaurus = "YTsaurus"

    // MARK: - Object Storage & Cloud

    /// S3-compatible object storage.
    /// Reads/writes data stored in S3 buckets.
    case s3 = "S3"

    /// S3-backed table queue — processes new files as they arrive.
    case s3Queue = "S3Queue"

    /// Iceberg table format support (Parquet-based).
    case iceberg = "Iceberg"

    /// Delta Lake table format support (Linux only).
    case deltaLake = "DeltaLake"

    /// Paimon table format support.
    case paimon = "Paimon"

    /// Azure Blob Storage queue — processes new blobs.
    case azureQueue = "AzureQueue"

    /// Generic object storage (local or remote).
    case objectStorage = "ObjectStorage"

    /// Hudi table format support.
    case hudi = "Hudi"

    // MARK: - Key-Value & Specialised

    /// Key-value storage backed by RocksDB.
    /// Ideal for point lookups and high-throughput writes.
    /// Requires a persistent ``ChdbConnection`` (non-`:memory:` path).
    ///
    /// - Requires: `PRIMARY KEY` clause.
    case embeddedRocksDB = "EmbeddedRocksDB"

    /// Buffer writes to memory before flushing to another table.
    /// Useful for batching small inserts in high-throughput scenarios.
    case buffer = "Buffer"

    /// A specialised set data structure for use with `IN` operators.
    case set = "Set"

    /// A specialised hash-join data structure.
    case join = "Join"

    /// A view that pushes data to specified targets.
    case distributed = "Distributed"

    // MARK: - Description

    public var description: String { rawValue }

    // MARK: - Properties

    /// Whether this engine requires a persistent (disk-based) connection.
    ///
    /// Engines that only store data in memory or connect to external services
    /// can work with an in-memory (``ChdbConnection/init(path:)`` = `":memory:"`)
    /// connection. Disk-based engines (MergeTree variants, Log, RocksDB, etc.)
    /// require a filesystem path.
    public var requiresPersistentStorage: Bool {
        switch self {
        case .memory, .null, .generateRandom, .view, .materializedView,
                .alias, .dictionary,
                .url, .executable, .kafka, .windowView, .loop,
                .mySQL, .postgreSQL, .materializedPostgreSQL, .mongoDB,
                .redis, .odbc, .jdbc, .keeperMap, .ytSaurus,
                .s3, .s3Queue, .iceberg, .deltaLake, .paimon,
                .azureQueue, .hudi,
                .buffer, .set, .join, .distributed:
            return false
        case .mergeTree, .replacingMergeTree, .summingMergeTree,
                .aggregatingMergeTree, .collapsingMergeTree,
                .versionedCollapsingMergeTree, .graphiteMergeTree,
                .log, .stripeLog, .file, .merge,
                .timeSeries, .sqlite,
                .objectStorage,
                .embeddedRocksDB:
            return true
        }
    }

    /// Whether this engine requires an `ORDER BY` clause.
    ///
    /// Only MergeTree-family engines require an ordering clause.
    /// Other engines (Memory, Log, Buffer, URL, Kafka, etc.) sort
    /// by primary key or have no ordering at all.
    public var requiresOrderBy: Bool {
        switch self {
        case .memory, .null, .generateRandom, .view, .materializedView,
                .alias, .dictionary,
                .log, .stripeLog, .file, .url, .merge,
                .executable, .kafka, .windowView, .loop,
                .mySQL, .postgreSQL, .materializedPostgreSQL, .mongoDB,
                .sqlite, .redis, .odbc, .jdbc, .keeperMap, .ytSaurus,
                .s3, .s3Queue, .iceberg, .deltaLake, .paimon,
                .azureQueue, .objectStorage, .hudi,
                .buffer, .set, .join, .distributed, .embeddedRocksDB:
            return false
        case .mergeTree, .replacingMergeTree, .summingMergeTree,
                .aggregatingMergeTree, .collapsingMergeTree,
                .versionedCollapsingMergeTree, .graphiteMergeTree,
                .timeSeries:
            return true
        }
    }

    /// A human-readable category for this engine.
    public var category: String {
        switch self {
        case .memory, .null, .generateRandom: return "In-Memory"
        case .view, .materializedView, .alias, .dictionary: return "SQL"
        case .mergeTree, .replacingMergeTree, .summingMergeTree,
                .aggregatingMergeTree, .collapsingMergeTree,
                .versionedCollapsingMergeTree, .graphiteMergeTree: return "MergeTree"
        case .log, .stripeLog: return "Log"
        case .file, .url, .merge: return "File/IO"
        case .executable: return "External"
        case .kafka: return "Message Queue"
        case .timeSeries, .windowView: return "Time Series"
        case .loop: return "Utility"
        case .mySQL, .postgreSQL, .materializedPostgreSQL, .mongoDB,
                .sqlite, .redis, .odbc, .jdbc, .keeperMap, .ytSaurus: return "External Database"
        case .s3, .s3Queue, .iceberg, .deltaLake, .paimon,
                .azureQueue, .objectStorage, .hudi: return "Object Storage"
        case .embeddedRocksDB, .buffer, .set, .join, .distributed: return "Specialised"
        }
    }
}
