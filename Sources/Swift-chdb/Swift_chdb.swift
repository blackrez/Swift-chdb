/// chDB — embedded ClickHouse for Swift.
///
/// This module provides a Swift-friendly binding to the chDB C library,
/// allowing you to run SQL queries on an embedded ClickHouse engine.
///
/// ## Quick Start
/// ```swift
/// import Swift_chdb
///
/// let db = try Chdb()
/// let result = try db.query("SELECT 'Hello, chDB!' AS greeting")
/// print(result.text ?? "")
/// ```
import Cchdb

/// Convenience typealias for `ChdbConnection`.
///
/// Use this shorthand for quick, single-word access to the chDB API:
/// ```swift
/// let db = try Chdb()
/// ```
public typealias Chdb = ChdbConnection
