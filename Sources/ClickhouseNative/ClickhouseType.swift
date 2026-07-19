import Foundation
import Cclickhouse

/// A parsed ClickHouse type expression (e.g. `Nullable(Array(Int32))`).
///
/// Use `ClickhouseType.parse(_:)` to obtain an instance from a type name string.
/// Once parsed, you can inspect the kind, children, and various properties.
public struct ClickhouseType: Sendable, Hashable, CustomStringConvertible {
    /// Kind of this type node.
    public let kind: ClickhouseTypeKind

    /// Child types (e.g. the element type of an Array, the inner type of a Nullable).
    public let children: [ClickhouseType]

    /// The full type name (e.g. `"Nullable(Array(Int32))"`).
    public let name: String

    public var description: String { name }

    // MARK: - Initialization

    /// Parse a ClickHouse type name string into a type tree.
    ///
    /// ```swift
    /// let t = try ClickhouseType.parse("Nullable(Array(Int32))")
    /// print(t.kind)               // .nullable
    /// print(t.children[0].kind)   // .array
    /// ```
    public static func parse(_ name: String) throws -> ClickhouseType {
        var errBuf = [CChar](repeating: 0, count: 256)
        guard let handle = name.withCString({ cstr in
            chc_swift_type_parse(cstr, name.utf8.count, &errBuf, errBuf.count)
        }) else {
            let errMsg = errBuf.prefix(while: { $0 != 0 }).map(UInt8.init)
            throw ClickhouseError.parseFailed(String(decoding: errMsg, as: UTF8.self))
        }
        defer { chc_swift_type_free(handle) }
        return ClickhouseType(cHandle: handle)
    }

    /// Eagerly read all data from a C type handle (owned or borrowed).
    internal init(cHandle: UnsafeMutableRawPointer) {
        self.kind = ClickhouseTypeKind(chcKind: chc_swift_type_kind(cHandle))

        // Read name eagerly
        var nameLen: size_t = 0
        if let s = chc_swift_type_name(cHandle, &nameLen), nameLen > 0 {
            self.name = String(decoding: Data(bytes: s, count: nameLen), as: UTF8.self)
        } else {
            self.name = ""
        }

        // Recursively read children eagerly
        let n = chc_swift_type_n_children(cHandle)
        var kids: [ClickhouseType] = []
        kids.reserveCapacity(n)
        for i in 0..<n {
            if let child = chc_swift_type_child(cHandle, i) {
                kids.append(ClickhouseType(cHandle: child))
            }
        }
        self.children = kids
    }

    /// Hashable conformance — based on kind + name + children.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(name)
        hasher.combine(children)
    }

    public static func == (lhs: ClickhouseType, rhs: ClickhouseType) -> Bool {
        lhs.kind == rhs.kind && lhs.name == rhs.name && lhs.children == rhs.children
    }
}

// MARK: - Type Kind

/// ClickHouse type kind, mirroring `chc_kind`.
public enum ClickhouseTypeKind: Sendable, Hashable, CustomStringConvertible {
    case void
    case int8, int16, int32, int64, int128, int256
    case uint8, uint16, uint32, uint64, uint128, uint256
    case float32, float64, bfloat16
    case bool
    case date, date32
    case datetime, datetime64
    case time, time64
    case string, fixedString
    case decimal32, decimal64, decimal128, decimal256
    case uuid, ipv4, ipv6
    case enum8, enum16
    case nullable, array, tuple, map, nested
    case lowCardinality
    case interval
    case point, ring, polygon, multiPolygon
    case variant, dynamic, json, object
    case aggregateFunction, simpleAggregateFunction
    case qbit
    case nothing
    case other(Int32)

    init(chcKind: Int32) {
        self = Self.fromCHC(chcKind)
    }

    static func fromCHC(_ k: Int32) -> ClickhouseTypeKind {
        switch k {
        case 0:  return .void
        case 1:  return .int8
        case 2:  return .int16
        case 3:  return .int32
        case 4:  return .int64
        case 5:  return .int128
        case 6:  return .int256
        case 7:  return .uint8
        case 8:  return .uint16
        case 9:  return .uint32
        case 10: return .uint64
        case 11: return .uint128
        case 12: return .uint256
        case 13: return .float32
        case 14: return .float64
        case 15: return .bfloat16
        case 16: return .bool
        case 17: return .date
        case 18: return .date32
        case 19: return .datetime
        case 20: return .datetime64
        case 21: return .time
        case 22: return .time64
        case 23: return .string
        case 24: return .fixedString
        case 25: return .decimal32
        case 26: return .decimal64
        case 27: return .decimal128
        case 28: return .decimal256
        case 29: return .uuid
        case 30: return .ipv4
        case 31: return .ipv6
        case 32: return .enum8
        case 33: return .enum16
        case 34: return .nullable
        case 35: return .array
        case 36: return .tuple
        case 37: return .map
        case 38: return .nested
        case 39: return .lowCardinality
        case 40: return .interval
        case 41: return .point
        case 42: return .ring
        case 43: return .polygon
        case 44: return .multiPolygon
        case 45: return .variant
        case 46: return .dynamic
        case 47: return .json
        case 48: return .object
        case 49: return .aggregateFunction
        case 50: return .simpleAggregateFunction
        case 51: return .qbit
        case 52: return .nothing
        default: return .other(k)
        }
    }

    public var description: String {
        switch self {
        case .void: return "Void"
        case .int8: return "Int8"
        case .int16: return "Int16"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .int128: return "Int128"
        case .int256: return "Int256"
        case .uint8: return "UInt8"
        case .uint16: return "UInt16"
        case .uint32: return "UInt32"
        case .uint64: return "UInt64"
        case .uint128: return "UInt128"
        case .uint256: return "UInt256"
        case .float32: return "Float32"
        case .float64: return "Float64"
        case .bfloat16: return "BFloat16"
        case .bool: return "Bool"
        case .date: return "Date"
        case .date32: return "Date32"
        case .datetime: return "DateTime"
        case .datetime64: return "DateTime64"
        case .time: return "Time"
        case .time64: return "Time64"
        case .string: return "String"
        case .fixedString: return "FixedString"
        case .decimal32: return "Decimal32"
        case .decimal64: return "Decimal64"
        case .decimal128: return "Decimal128"
        case .decimal256: return "Decimal256"
        case .uuid: return "UUID"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .enum8: return "Enum8"
        case .enum16: return "Enum16"
        case .nullable: return "Nullable"
        case .array: return "Array"
        case .tuple: return "Tuple"
        case .map: return "Map"
        case .nested: return "Nested"
        case .lowCardinality: return "LowCardinality"
        case .interval: return "Interval"
        case .point: return "Point"
        case .ring: return "Ring"
        case .polygon: return "Polygon"
        case .multiPolygon: return "MultiPolygon"
        case .variant: return "Variant"
        case .dynamic: return "Dynamic"
        case .json: return "JSON"
        case .object: return "Object"
        case .aggregateFunction: return "AggregateFunction"
        case .simpleAggregateFunction: return "SimpleAggregateFunction"
        case .qbit: return "QBit"
        case .nothing: return "Nothing"
        case .other(let v): return "Unknown(\(v))"
        }
    }
}

// MARK: - Errors

public enum ClickhouseError: Error, CustomStringConvertible {
    case parseFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case invalidColumn(String)
    case typeMismatch(String)

    public var description: String {
        switch self {
        case .parseFailed(let m): return "Type parse failed: \(m)"
        case .readFailed(let m): return "Block read failed: \(m)"
        case .writeFailed(let m): return "Block write failed: \(m)"
        case .invalidColumn(let m): return "Invalid column: \(m)"
        case .typeMismatch(let m): return "Type mismatch: \(m)"
        }
    }
}
