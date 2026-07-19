/// Supported ClickHouse table engines for use with ``ChdbConnection``.
///
/// Use with ``ChdbConnection/defaultEngine`` to set the engine used by
/// ``ChdbConnection/createTable(_:columns:engine:orderBy:primaryKey:)``,
/// or pass directly to that method.
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
    /// In-memory table (default). Data is lost when the connection closes.
    /// Best for small lookup tables, temporary data, and benchmarks.
    case memory = "Memory"

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

    /// Buffer writes to memory before flushing to another table.
    /// Useful for batching small inserts in high-throughput scenarios.
    case buffer = "Buffer"

    /// A specialised set data structure for use with `IN` operators.
    case set = "Set"

    /// A specialised hash-join data structure.
    case join = "Join"

    /// Logical view over a `SELECT` query (no physical storage).
    case view = "View"

    /// Materialised view that stores results on disk.
    case materializedView = "MaterializedView"

    /// A view that pushes data to specified targets.
    case distributed = "Distributed"

    public var description: String { rawValue }

    /// Whether this engine requires a persistent (disk-based) connection.
    /// Memory, Set, Join, View, and Buffer can work in `:memory:` mode.
    /// All MergeTree variants require disk storage.
    public var requiresPersistentStorage: Bool {
        switch self {
        case .memory, .buffer, .set, .join, .view, .materializedView:
            return false
        case .mergeTree, .replacingMergeTree, .summingMergeTree,
            .aggregatingMergeTree, .collapsingMergeTree,
            .versionedCollapsingMergeTree, .graphiteMergeTree,
            .distributed:
            return true
        }
    }

    /// Whether this engine requires an `ORDER BY` clause.
    public var requiresOrderBy: Bool {
        switch self {
        case .memory, .buffer, .set, .join, .view, .materializedView, .distributed:
            return false
        case .mergeTree, .replacingMergeTree, .summingMergeTree,
            .aggregatingMergeTree, .collapsingMergeTree,
            .versionedCollapsingMergeTree, .graphiteMergeTree:
            return true
        }
    }
}
