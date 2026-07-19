import Foundation

/// Errors that can occur during chDB operations.
public enum ChdbError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Failed to create a connection to chDB.
    case connectionFailed(String?)
    /// Query execution returned an error.
    case queryFailed(String)
    /// The connection has been closed.
    case connectionClosed

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .connectionFailed(let msg):
            return "chDB connection failed: \(msg ?? "unknown cause")"
        case .queryFailed(let msg):
            return "chDB query error: \(msg)"
        case .connectionClosed:
            return "chDB connection is closed"
        }
    }
}
