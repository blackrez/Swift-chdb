import Foundation
import Cclickhouse

/// A block of columnar data in ClickHouse native format.
///
/// Use `ClickhouseBlock.read(from:)` to parse native format bytes,
/// or build one programmatically.
public struct ClickhouseBlock: Sendable {
    /// Column information and data.
    public let columns: [ColumnInfo]
    /// Number of rows in this block.
    public let rowCount: Int

    /// Creates a block with the given columns and row count.
    public init(columns: [ColumnInfo], rowCount: Int) {
        self.columns = columns
        self.rowCount = rowCount
    }

    /// Information about a single column in the block.
    public struct ColumnInfo: Sendable {
        /// Column name.
        public let name: String
        /// Parsed ClickHouse type.
        public let type: ClickhouseType
        /// Column data.
        public let column: ClickhouseColumn
    }

    // MARK: - Read

    /// Read one block from ClickHouse native format bytes.
    ///
    /// - Parameter data: Raw native format bytes (with or without BlockInfo prefix).
    /// - Parameter hasBlockInfo: Whether the data includes a BlockInfo prefix
    ///   (set `true` for TCP protocol data, `false` for clickhouse-local output).
    /// - Returns: A parsed block, or `nil` if at EOF (empty data).
    public static func read(from data: Data, hasBlockInfo: Bool = false) throws -> ClickhouseBlock? {
        var errBuf = [CChar](repeating: 0, count: 256)

        guard let blockHandle = data.withUnsafeBytes({ buf in
            chc_swift_block_read(buf.baseAddress, buf.count,
                                 hasBlockInfo ? 1 : 0,
                                 &errBuf, errBuf.count)
        }) else {
            // Check if it's EOF (not an error)
            let errMsg = errBuf.prefix(while: { $0 != 0 }).map(UInt8.init)
            let errorText = String(decoding: errMsg, as: UTF8.self)
            if errorText.isEmpty {
                return nil
            }
            throw ClickhouseError.readFailed(errorText)
        }
        defer { chc_swift_block_free(blockHandle) }

        return try decode(block: blockHandle)
    }

    /// Decode a block handle into a Swift `ClickhouseBlock`.
    private static func decode(block handle: UnsafeMutableRawPointer) throws -> ClickhouseBlock {
        let nCols = Int(chc_swift_block_n_columns(handle))
        let nRows = Int(chc_swift_block_n_rows(handle))

        var columns: [ColumnInfo] = []
        columns.reserveCapacity(nCols)

        for i in 0..<nCols {
            // Column name
            var nameLen: size_t = 0
            guard let namePtr = chc_swift_block_col_name(handle, i, &nameLen) else {
                throw ClickhouseError.readFailed("nil column name at index \(i)")
            }
            let name = String(cString: namePtr)

            // Column type (borrowed handle)
            guard let typeHandle = chc_swift_block_col_type(handle, i) else {
                throw ClickhouseError.readFailed("nil column type at index \(i)")
            }
            let type = ClickhouseType(cHandle: typeHandle)

            // Column data (borrowed handle)
            guard let colHandle = chc_swift_block_col_data(handle, i) else {
                throw ClickhouseError.readFailed("nil column data at index \(i)")
            }
            let col = try ClickhouseColumn.decode(from: colHandle)

            columns.append(ColumnInfo(name: name, type: type, column: col))
        }

        return ClickhouseBlock(columns: columns, rowCount: nRows)
    }

    // MARK: - Write

    /// Serialize this block to ClickHouse native format bytes.
    /// This is a placeholder — block writing requires the C builder API.
    public func write(hasBlockInfo: Bool = false) throws -> Data {
        throw ClickhouseError.writeFailed(
            "Block writing is not yet implemented. " +
            "Use the C API directly via chc_block_write()."
        )
    }
}

// MARK: - Convenience

extension ClickhouseBlock {
    /// Look up a column by name.
    public subscript(name: String) -> ClickhouseColumn? {
        columns.first(where: { $0.name == name })?.column
    }

    /// All column names.
    public var columnNames: [String] {
        columns.map(\.name)
    }

    /// All column types.
    public var columnTypes: [ClickhouseType] {
        columns.map(\.type)
    }
}
