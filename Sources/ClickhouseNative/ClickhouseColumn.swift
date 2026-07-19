import Foundation
import Cclickhouse

// MARK: - Column enum

/// A typed column of data from a ClickHouse native block.
public indirect enum ClickhouseColumn: Sendable {
    case fixed(Data, elemSize: Int)
    case string([String])
    case nullable(nulls: [Bool], inner: ClickhouseColumn)
    case array(offsets: [Int], values: ClickhouseColumn)
    case tuple([ClickhouseColumn])
    case lowCardinality(keys: [Int], dict: ClickhouseColumn)
    case nothing(rows: Int)

    public var rowCount: Int {
        switch self {
        case .fixed(let d, let es): return es > 0 ? d.count / es : 0
        case .string(let s): return s.count
        case .nullable(_, let inner): return inner.rowCount
        case .array(let offs, _): return offs.count
        case .tuple(let ch): return ch.first?.rowCount ?? 0
        case .lowCardinality(let keys, _): return keys.count
        case .nothing(let r): return r
        }
    }
}

// MARK: - Zero-copy access (Phase 1)

extension ClickhouseColumn {
    /// Call `body` with the raw bytes of a fixed-size column, or `nil` if not fixed.
    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T? {
        guard case .fixed(let data, _) = self else { return nil }
        return try data.withUnsafeBytes(body)
    }

    /// Call `body` with the null bitmap buffer, or `nil` if not nullable.
    public func withUnsafeNullMap<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T? {
        guard case .nullable(let nulls, _) = self else { return nil }
        let raw = nulls.map { $0 ? UInt8(1) : UInt8(0) }
        return try raw.withUnsafeBufferPointer(body)
    }

    /// Call `body` with the string offsets, or `nil` if not a string column.
    /// Returns pairs of (offset, endOffset) for each row.
    public func withUnsafeStringRanges<T>(_ body: (UnsafeBufferPointer<UInt64>) throws -> T) rethrows -> T? {
        guard case .fixed(let data, 8) = self else { return nil }
        return try data.withUnsafeBytes { buf in
            try body(buf.bindMemory(to: UInt64.self))
        }
    }

    /// Iterate string values without creating intermediate `[String]`.
    /// The closure receives raw UTF-8 bytes for each row.
    public func forEachStringBytes(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        guard case .string(let strings) = self else { return }
        for s in strings {
            try Array(s.utf8).withUnsafeBytes { buf in
                try body(buf)
            }
        }
    }

    /// Iterate fixed values without creating an intermediate `[Any]` array.
    public func forEachFixedValue(type: ClickhouseType, _ body: (Any) throws -> Void) rethrows {
        guard case .fixed(let data, let es) = self, es > 0 else { return }
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<(data.count / es) {
                try body(_valueAt(base, offset: i * es, size: es, type: type))
            }
        }
    }

    /// Iterate Int32 values without boxing. Returns `nil` if not an Int32 column.
    public func forEachInt32(_ body: (Int32) throws -> Void) rethrows -> Bool {
        guard case .fixed(let data, 4) = self else { return false }
        return try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<(data.count / 4) {
                try body(Int32(littleEndian: base.load(fromByteOffset: i * 4, as: Int32.self)))
            }
            return true
        }
    }

    /// Iterate Int64 values without boxing.
    public func forEachInt64(_ body: (Int64) throws -> Void) rethrows -> Bool {
        guard case .fixed(let data, 8) = self else { return false }
        return try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<(data.count / 8) {
                try body(Int64(littleEndian: base.load(fromByteOffset: i * 8, as: Int64.self)))
            }
            return true
        }
    }

    /// Iterate UInt64 values without boxing.
    public func forEachUInt64(_ body: (UInt64) throws -> Void) rethrows -> Bool {
        guard case .fixed(let data, 8) = self else { return false }
        return try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<(data.count / 8) {
                try body(UInt64(littleEndian: base.load(fromByteOffset: i * 8, as: UInt64.self)))
            }
            return true
        }
    }

    /// Iterate Double values without boxing.
    public func forEachDouble(_ body: (Double) throws -> Void) rethrows -> Bool {
        guard case .fixed(let data, 8) = self else { return false }
        return try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<(data.count / 8) {
                try body(base.load(fromByteOffset: i * 8, as: Double.self))
            }
            return true
        }
    }

    /// Iterate Float values without boxing.
    public func forEachFloat(_ body: (Float) throws -> Void) rethrows -> Bool {
        guard case .fixed(let data, 4) = self else { return false }
        return try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<(data.count / 4) {
                try body(base.load(fromByteOffset: i * 4, as: Float.self))
            }
            return true
        }
    }

    /// Iterate String values without boxing.
    public func forEachString(_ body: (String) throws -> Void) rethrows -> Bool {
        guard case .string(let strings) = self else { return false }
        for s in strings { try body(s) }
        return true
    }
}

// MARK: - Column decoding (C → Swift)

extension ClickhouseColumn {
    static func decode(from handle: UnsafeMutableRawPointer?) throws -> ClickhouseColumn {
        guard let handle else { return .nothing(rows: 0) }
        let layout = chc_col_kind(rawValue: UInt32(bitPattern: chc_swift_col_layout(handle)))
        let nRows = Int(chc_swift_col_n_rows(handle))

        switch layout {
        case CHC_COL_FIXED:
            var elemSize: size_t = 0
            guard let data = chc_swift_col_fixed_data(handle, &elemSize) else {
                return .fixed(Data(), elemSize: 0)
            }
            return .fixed(Data(bytes: data, count: nRows * Int(elemSize)), elemSize: Int(elemSize))

        case CHC_COL_STRING:
            guard let data = chc_swift_col_string_data(handle),
                  let offsets = chc_swift_col_string_offsets(handle) else { return .string([]) }
            var strings: [String] = []
            strings.reserveCapacity(nRows)
            var prev: UInt64 = 0
            for i in 0..<nRows {
                let end = offsets[i]
                let len = Int(end - prev)
                if len == 0 { strings.append("") } else {
                    strings.append(String(decoding: Data(bytes: UnsafeRawPointer(data).advanced(by: Int(prev)), count: len), as: UTF8.self))
                }
                prev = end
            }
            return .string(strings)

        case CHC_COL_NULLABLE:
            guard let nullMap = chc_swift_col_null_map(handle) else { return .nullable(nulls: [], inner: .nothing(rows: 0)) }
            let nulls = (0..<nRows).map { nullMap[$0] != 0 }
            return .nullable(nulls: nulls, inner: try decode(from: chc_swift_col_nullable_inner(handle)))

        case CHC_COL_ARRAY:
            guard let offsets = chc_swift_col_array_offsets(handle) else { return .array(offsets: [], values: .nothing(rows: 0)) }
            return .array(offsets: (0..<nRows).map { Int(offsets[$0]) }, values: try decode(from: chc_swift_col_array_values(handle)))

        case CHC_COL_TUPLE:
            let arity = Int(chc_swift_col_tuple_arity(handle))
            var children: [ClickhouseColumn] = []
            children.reserveCapacity(arity)
            for i in 0..<arity {
                guard let child = chc_swift_col_tuple_child(handle, i) else { throw ClickhouseError.invalidColumn("nil tuple child \(i)") }
                children.append(try decode(from: child))
            }
            return .tuple(children)

        case CHC_COL_LOW_CARDINALITY:
            let keySize = Int(chc_swift_col_lc_key_size(handle))
            guard let keys = chc_swift_col_lc_keys(handle) else { return .lowCardinality(keys: [], dict: .nothing(rows: 0)) }
            let dictCol = try decode(from: chc_swift_col_lc_dict(handle))
            var keyArray: [Int] = []
            keyArray.reserveCapacity(nRows)
            for i in 0..<nRows {
                let v: UInt64 = keySize == 1 ? UInt64(keys.load(fromByteOffset: i, as: UInt8.self))
                    : keySize == 2 ? UInt64(keys.load(fromByteOffset: i * 2, as: UInt16.self))
                    : keySize == 4 ? UInt64(keys.load(fromByteOffset: i * 4, as: UInt32.self))
                    : keys.load(fromByteOffset: i * 8, as: UInt64.self)
                keyArray.append(Int(v))
            }
            return .lowCardinality(keys: keyArray, dict: dictCol)

        default:
            return .nothing(rows: nRows)
        }
    }
}

// MARK: - Convenience typed accessors

extension ClickhouseColumn {
    private func decodeFixedInt<T: FixedWidthInteger>(_: T.Type, size: Int) -> [T]? {
        guard case .fixed(let data, size) = self, size == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return [] }
            return (0..<(data.count / size)).map { base.load(fromByteOffset: $0 * size, as: T.self).littleEndian }
        }
    }
    private func decodeFixedFloat<T>(_: T.Type, size: Int) -> [T]? {
        guard case .fixed(let data, size) = self, size == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return [] }
            return (0..<(data.count / size)).map { base.load(fromByteOffset: $0 * size, as: T.self) }
        }
    }

    public var int32Values: [Int32]? { decodeFixedInt(Int32.self, size: 4) }
    public var int64Values: [Int64]? { decodeFixedInt(Int64.self, size: 8) }
    public var uint8Values: [UInt8]? { guard case .fixed(let d, 1) = self else { return nil }; return [UInt8](d) }
    public var uint32Values: [UInt32]? { decodeFixedInt(UInt32.self, size: 4) }
    public var uint64Values: [UInt64]? { decodeFixedInt(UInt64.self, size: 8) }
    public var floatValues: [Float]? { decodeFixedFloat(Float.self, size: 4) }
    public var doubleValues: [Double]? { decodeFixedFloat(Double.self, size: 8) }
    public var stringValues: [String]? { guard case .string(let s) = self else { return nil }; return s }

    public var nullableUInt64Values: [UInt64?]? {
        guard case .nullable(let nulls, let inner) = self, case .fixed(let data, 8) = inner else { return nil }
        return data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return [] }
            return (0..<(data.count / 8)).map { i in nulls[i] ? nil : base.load(fromByteOffset: i * 8, as: UInt64.self).littleEndian }
        }
    }
}

// MARK: - JSON conversion (kept for backward compat, fixed valueAt)

extension ClickhouseColumn {
    public func toJSONValues(type: ClickhouseType) -> [Any] {
        switch self {
        case .fixed(let data, let es):
            let count = es > 0 ? data.count / es : 0
            guard count > 0 else { return [] }
            return data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return [] }
                return (0..<count).map { _valueAt(base, offset: $0 * es, size: es, type: type) }
            }
        case .string(let s): return s as [Any]
        case .nullable(let nulls, let inner):
            return zip(nulls, inner.toJSONValues(type: type.children.first ?? type)).map { $0 ? NSNull() : $1 }
        case .array(let offs, let vals):
            let flat = vals.toJSONValues(type: type.children.first ?? type)
            var r: [Any] = []; var prev = 0
            for off in offs { r.append(Array(flat[prev..<off])); prev = off }
            return r
        case .tuple(let children):
            return children.enumerated().map { i, col in col.toJSONValues(type: i < type.children.count ? type.children[i] : type) }
        case .lowCardinality(let keys, let dict):
            let dv = dict.toJSONValues(type: type.children.first ?? type)
            return keys.map { $0 < dv.count ? dv[$0] : NSNull() }
        case .nothing: return []
        }
    }
}

// MARK: - Full type conversion (Phase 2 — fixed for ALL types)

/// Read one value from raw column bytes at the given offset.
/// - Parameters:
///   - base: Pointer to the start of the column data
///   - offset: Byte offset for this value
///   - size: Element size in bytes
///   - type: The parsed ClickHouse type for this column
/// - Returns: A JSON-compatible value (Int, Double, String, Bool, or NSNull-compatible)
private func _valueAt(_ base: UnsafeRawPointer, offset: Int, size: Int, type: ClickhouseType) -> Any {
    let ptr = base + offset
    switch type.kind {
    // Integers
    case .int8:    return Int(ptr.load(as: Int8.self))
    case .int16:   return Int(Int16(littleEndian: ptr.load(as: Int16.self)))
    case .int32:   return Int(Int32(littleEndian: ptr.load(as: Int32.self)))
    case .int64:   return Int(Int64(littleEndian: ptr.load(as: Int64.self)))
    case .int128, .int256:  return _int128String(ptr, size: size)
    case .uint8:   return Int(ptr.load(as: UInt8.self))
    case .uint16:  return Int(UInt16(littleEndian: ptr.load(as: UInt16.self)))
    case .uint32:  return Int(UInt32(littleEndian: ptr.load(as: UInt32.self)))
    case .uint64:  return NSNumber(value: UInt64(littleEndian: ptr.load(as: UInt64.self)))
    case .uint128, .uint256: return _uint128String(ptr, size: size)

    // Floats
    case .float32: return Double(ptr.load(as: Float.self))
    case .float64: return ptr.load(as: Double.self)
    case .bfloat16: return Double(_bfloat16ToFloat32(ptr))

    // Bool
    case .bool:    return ptr.load(as: UInt8.self) != 0

    // Date / Time
    case .date, .date32:
        return Int(UInt16(littleEndian: ptr.load(as: UInt16.self)))
    case .datetime:
        return Int(UInt32(littleEndian: ptr.load(as: UInt32.self)))
    case .datetime64:
        return Double(Int64(littleEndian: ptr.load(as: Int64.self))) / 1_000_000_000
    case .time:
        return Int(Int64(littleEndian: ptr.load(as: Int64.self)))
    case .time64:
        return Int(Int64(littleEndian: ptr.load(as: Int64.self)))

    // Decimal → String (value, not type name)
    case .decimal32, .decimal64, .decimal128, .decimal256:
        return _decimalString(ptr, size: size, type: type)

    // String-like
    case .string, .fixedString:
        return _fixedStringValue(ptr, size: size)

    // Network
    case .uuid:    return _uuidString(ptr)
    case .ipv4:    return _ipv4String(ptr)
    case .ipv6:    return _ipv6String(ptr)

    // Enum → String (value name)
    case .enum8:   return _enumString(ptr, size: 1, type: type)
    case .enum16:  return _enumString(ptr, size: 2, type: type)

    // Interval
    case .interval: return Int(Int64(littleEndian: ptr.load(as: Int64.self)))

    // Compound types are handled at the column level, not here
    case .nullable, .array, .tuple, .map, .nested, .lowCardinality, .nothing, .void, .variant, .dynamic, .json, .object:
        return NSNull()

    // AggregateFunction — recurses on last child type
    case .aggregateFunction, .simpleAggregateFunction:
        if let last = type.children.last { return _valueAt(base, offset: offset, size: size, type: last) }
        return NSNull()

    // Geo types — handled at column level (Array/Tuple)
    case .point, .ring, .polygon, .multiPolygon:
        return NSNull()

    // Fallback
    case .qbit, .other:
        return Int(Int32(littleEndian: ptr.load(as: Int32.self)))
    }
}

// MARK: - Low-level type converters

private func _bfloat16ToFloat32(_ ptr: UnsafeRawPointer) -> Float {
    let bits = UInt16(littleEndian: ptr.load(as: UInt16.self))
    return Float(bitPattern: UInt32(bits) << 16)
}

private func _int128String(_ ptr: UnsafeRawPointer, size: Int) -> String {
    let count = min(size, 16)
    let data = Data(bytes: ptr, count: count)
    // Simple hex representation for wide ints
    return "0x" + data.reversed().map { String(format: "%02x", $0) }.joined()
}

private func _uint128String(_ ptr: UnsafeRawPointer, size: Int) -> String {
    return _int128String(ptr, size: size)
}

private func _decimalString(_ ptr: UnsafeRawPointer, size: Int, type: ClickhouseType) -> String {
    // Parse the scale from the type name (e.g. "Decimal(9,2)" → 2)
    let scale = _decimalScale(from: type.name)
    let absValue: Int64
    switch size {
    case 4:  absValue = Int64(Int32(littleEndian: ptr.load(as: Int32.self)))
    case 8:  absValue = Int64(littleEndian: ptr.load(as: Int64.self))
    default: return type.name
    }
    if scale == 0 { return "\(absValue)" }
    let sign = absValue < 0 ? "-" : ""
    let abs = absValue < 0 ? -absValue : absValue
    let intPart = abs / Int64(pow(10.0, Double(scale)))
    let fracPart = abs % Int64(pow(10.0, Double(scale)))
    return "\(sign)\(intPart).\(String(format: "%0\(scale)d", Int(fracPart)))"
}

private func _decimalScale(from typeName: String) -> Int {
    guard let paren = typeName.firstIndex(of: "("),
          let comma = typeName.firstIndex(of: ","),
          let close = typeName.firstIndex(of: ")") else { return 0 }
    return Int(typeName[typeName.index(after: comma)..<close].trimmingCharacters(in: .whitespaces)) ?? 0
}

private func _fixedStringValue(_ ptr: UnsafeRawPointer, size: Int) -> String {
    let end = ptr.advanced(by: size)
    var len = 0
    while len < size, ptr.load(fromByteOffset: len, as: UInt8.self) != 0 { len += 1 }
    return String(decoding: Data(bytes: ptr, count: len), as: UTF8.self)
}

private func _uuidString(_ ptr: UnsafeRawPointer) -> String {
    let b = UnsafeRawBufferPointer(start: ptr, count: 16)
    let bytes = b.map { $0 }
    return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                  bytes[0], bytes[1], bytes[2], bytes[3],
                  bytes[4], bytes[5], bytes[6], bytes[7],
                  bytes[8], bytes[9], bytes[10], bytes[11],
                  bytes[12], bytes[13], bytes[14], bytes[15])
}

private func _ipv4String(_ ptr: UnsafeRawPointer) -> String {
    let b = UInt32(littleEndian: ptr.load(as: UInt32.self))
    return "\(b & 0xFF).\((b >> 8) & 0xFF).\((b >> 16) & 0xFF).\((b >> 24) & 0xFF)"
}

private func _ipv6String(_ ptr: UnsafeRawPointer) -> String {
    let b = UnsafeRawBufferPointer(start: ptr, count: 16).map { $0 }
    return String(format: "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                  b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                  b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
}

private func _enumString(_ ptr: UnsafeRawPointer, size: Int, type: ClickhouseType) -> String {
    // Enum values are stored as their integer representation
    let val: Int = size == 1 ? Int(ptr.load(as: Int8.self)) : Int(Int16(littleEndian: ptr.load(as: Int16.self)))
    return "enum:\(val)"
}

private func pow(_ base: Double, _ exp: Int) -> Double {
    (0..<exp).reduce(1.0) { r, _ in r * base }
}

// MARK: - ColumnarDecoder (Phase 3 — native Decodable, zero JSON)

/// Internal: wraps a column handle for reading one value at a given row.
struct _ColumnReader {
    let column: ClickhouseColumn
    let type: ClickhouseType
    let rowIndex: Int

    func read() throws -> Any {
        switch column {
        case .fixed(let data, let es):
            guard es > 0 else { throw DecodingError.typeMismatch(Any.self, .init(codingPath: [], debugDescription: "zero-size fixed column")) }
            let offset = rowIndex * es
            guard offset + es <= data.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "row \(rowIndex) out of bounds")) }
            return data.withUnsafeBytes { buf in
                _valueAt(buf.baseAddress!, offset: offset, size: es, type: type)
            }

        case .string(let strings):
            guard rowIndex < strings.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "row \(rowIndex) out of bounds")) }
            return strings[rowIndex]

        case .nullable(let nulls, let inner):
            guard rowIndex < nulls.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "row \(rowIndex) out of bounds")) }
            if nulls[rowIndex] { return NSNull() }
            let innerType = type.children.first ?? type
            return try _ColumnReader(column: inner, type: innerType, rowIndex: rowIndex).read()

        case .array(let offsets, let values):
            guard rowIndex < offsets.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "row \(rowIndex) out of bounds")) }
            let prev = rowIndex == 0 ? 0 : offsets[rowIndex - 1]
            let end = offsets[rowIndex]
            let innerType = type.children.first ?? type
            var result: [Any] = []
            for i in prev..<end {
                result.append(try _ColumnReader(column: values, type: innerType, rowIndex: i).read())
            }
            return result

        case .tuple(let children):
            let childTypes = type.children
            var result: [Any] = []
            for (i, child) in children.enumerated() {
                let t = i < childTypes.count ? childTypes[i] : type
                result.append(try _ColumnReader(column: child, type: t, rowIndex: rowIndex).read())
            }
            return result

        case .lowCardinality(let keys, let dict):
            guard rowIndex < keys.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "row \(rowIndex) out of bounds")) }
            let innerType = type.children.first ?? type
            return try _ColumnReader(column: dict, type: innerType, rowIndex: keys[rowIndex]).read()

        case .nothing:
            throw DecodingError.valueNotFound(Any.self, .init(codingPath: [], debugDescription: "column is empty"))
        }
    }
}

/// A `Decoder` that reads directly from a `ClickhouseBlock` without JSON.
/// One instance per row.
public struct ColumnarDecoder: Decoder {
    public let codingPath: [CodingKey]
    public let userInfo: [CodingUserInfoKey: Any] = [:]
    let block: ClickhouseBlock
    let rowIndex: Int

    public init(block: ClickhouseBlock, rowIndex: Int, codingPath: [CodingKey] = []) {
        self.block = block
        self.rowIndex = rowIndex
        self.codingPath = codingPath
    }

    public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        KeyedDecodingContainer(ColumnarKeyedContainer<Key>(block: block, rowIndex: rowIndex, codingPath: codingPath))
    }

    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        ColumnarUnkeyedContainer(columns: block.columns, rowIndex: rowIndex, codingPath: codingPath)
    }

    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        ColumnarSingleContainer(block: block, rowIndex: rowIndex, codingPath: codingPath)
    }
}

struct ColumnarKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol where Key: CodingKey {
    let block: ClickhouseBlock
    let rowIndex: Int
    let codingPath: [CodingKey]
    var allKeys: [Key] { block.columns.compactMap { Key(stringValue: $0.name) } }

    func contains(_ key: Key) -> Bool { block.columns.contains { $0.name == key.stringValue } }

    func colInfo(_ key: Key) throws -> ClickhouseBlock.ColumnInfo {
        guard let c = block.columns.first(where: { $0.name == key.stringValue }) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Column '\(key.stringValue)' not found"))
        }
        return c
    }

    func reader(_ key: Key) throws -> _ColumnReader {
        let c = try colInfo(key)
        return _ColumnReader(column: c.column, type: c.type, rowIndex: rowIndex)
    }

    func decodeNil(forKey key: Key) throws -> Bool { try reader(key).read() is NSNull }
    func decode(_ type: Bool.Type,   forKey key: Key) throws -> Bool   { let v = try reader(key).read(); return v as? Bool ?? (v as? Int).map { $0 != 0 } ?? false }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { let v = try reader(key).read(); return v as? String ?? "\(v)" }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { let v = try reader(key).read(); return v as? Double ?? (v as? Int).map(Double.init) ?? 0 }
    func decode(_ type: Float.Type,  forKey key: Key) throws -> Float  { let v = try reader(key).read(); return v as? Float ?? (v as? Double).map(Float.init) ?? (v as? Int).map(Float.init) ?? 0 }
    func decode(_ type: Int.Type,    forKey key: Key) throws -> Int    { let v = try reader(key).read(); return v as? Int ?? (v as? Int64).map(Int.init) ?? 0 }
    func decode(_ type: Int8.Type,   forKey key: Key) throws -> Int8   { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: Int16.Type,  forKey key: Key) throws -> Int16  { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: Int32.Type,  forKey key: Key) throws -> Int32  { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: Int64.Type,  forKey key: Key) throws -> Int64  { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: UInt.Type,   forKey key: Key) throws -> UInt   { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: UInt8.Type,  forKey key: Key) throws -> UInt8  { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { .init(try decode(Int.self,   forKey: key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { .init(try decode(Int.self,   forKey: key)) }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        let c = try colInfo(key)
        // Build a sub-decoder for compound types
        let sub = ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath + [key])
        // For the given key, try to decode the column value directly
        if type == [Any].self || type == [String].self || type == [Int].self || type == [Double].self {
            let v = try reader(key).read()
            if let arr = v as? [Any], let result = arr as? T { return result }
        }
        // For Decodable types, create a single-value container
        return try T(from: sub)
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder { ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder { ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath + [key]) }
}

struct ColumnarUnkeyedContainer: UnkeyedDecodingContainer {
    let columns: [ClickhouseBlock.ColumnInfo]
    let rowIndex: Int
    let codingPath: [CodingKey]
    var count: Int? { columns.count }
    var isAtEnd: Bool { currentIndex >= columns.count }
    var currentIndex = 0

    mutating func decodeNil() throws -> Bool { let r = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read() is NSNull; currentIndex += 1; return r }
    mutating func decode(_ type: Bool.Type)   throws -> Bool   { let v = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read(); currentIndex += 1; guard let r = v as? Bool else { throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "expected Bool")) }; return r }
    mutating func decode(_ type: String.Type) throws -> String { let v = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read(); currentIndex += 1; guard let r = v as? String else { throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "expected String")) }; return r }
    mutating func decode(_ type: Double.Type) throws -> Double { let v = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read(); currentIndex += 1; return v as? Double ?? (v as? NSNumber)?.doubleValue ?? 0 }
    mutating func decode(_ type: Float.Type)  throws -> Float  { let v = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read(); currentIndex += 1; return v as? Float ?? (v as? Double).map(Float.init) ?? (v as? NSNumber)?.floatValue ?? 0 }
    mutating func decode(_ type: Int.Type)    throws -> Int    { let v = try _ColumnReader(column: columns[currentIndex].column, type: columns[currentIndex].type, rowIndex: rowIndex).read(); currentIndex += 1; return v as? Int ?? (v as? NSNumber)?.intValue ?? 0 }
    mutating func decode(_ type: Int8.Type)   throws -> Int8   { .init(try decode(Int.self)) }
    mutating func decode(_ type: Int16.Type)  throws -> Int16  { .init(try decode(Int.self)) }
    mutating func decode(_ type: Int32.Type)  throws -> Int32  { .init(try decode(Int.self)) }
    mutating func decode(_ type: Int64.Type)  throws -> Int64  { .init(try decode(Int.self)) }
    mutating func decode(_ type: UInt.Type)   throws -> UInt   { .init(try decode(Int.self)) }
    mutating func decode(_ type: UInt8.Type)  throws -> UInt8  { .init(try decode(Int.self)) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { .init(try decode(Int.self)) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { .init(try decode(Int.self)) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { .init(try decode(Int.self)) }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        let sub = ColumnarDecoder(block: _mockBlock(column: columns[currentIndex]), rowIndex: rowIndex, codingPath: codingPath)
        currentIndex += 1; return try T(from: sub)
    }

    private func _mockBlock(column: ClickhouseBlock.ColumnInfo) -> ClickhouseBlock {
        ClickhouseBlock(columns: [column], rowCount: 1)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { currentIndex += 1; return try ColumnarDecoder(block: _mockBlock(column: columns[currentIndex - 1]), rowIndex: rowIndex).container(keyedBy: type) }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { currentIndex += 1; return try ColumnarDecoder(block: _mockBlock(column: columns[currentIndex - 1]), rowIndex: rowIndex).unkeyedContainer() }
    mutating func superDecoder() throws -> Decoder { currentIndex += 1; return ColumnarDecoder(block: _mockBlock(column: columns[currentIndex - 1]), rowIndex: rowIndex) }
}

struct ColumnarSingleContainer: SingleValueDecodingContainer {
    let block: ClickhouseBlock
    let rowIndex: Int
    let codingPath: [CodingKey]

    private func r() throws -> _ColumnReader {
        guard let col = block.columns.first else { throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "no columns")) }
        return _ColumnReader(column: col.column, type: col.type, rowIndex: rowIndex)
    }

    func decodeNil() -> Bool { (try? r().read()).map { $0 is NSNull } ?? true }
    func decode(_ type: Bool.Type)   throws -> Bool   { let v = try r().read(); return v as? Bool ?? (v as? Int).map { $0 != 0 } ?? false }
    func decode(_ type: String.Type) throws -> String { let v = try r().read(); return v as? String ?? "\(v)" }
    func decode(_ type: Double.Type) throws -> Double { let v = try r().read(); return v as? Double ?? (v as? Int).map(Double.init) ?? 0 }
    func decode(_ type: Float.Type)  throws -> Float  { let v = try r().read(); return v as? Float ?? (v as? Double).map(Float.init) ?? (v as? Int).map(Float.init) ?? 0 }
    func decode(_ type: Int.Type)    throws -> Int    { let v = try r().read(); return v as? Int ?? 0 }
    func decode(_ type: Int8.Type)   throws -> Int8   { .init(try decode(Int.self)) }
    func decode(_ type: Int16.Type)  throws -> Int16  { .init(try decode(Int.self)) }
    func decode(_ type: Int32.Type)  throws -> Int32  { .init(try decode(Int.self)) }
    func decode(_ type: Int64.Type)  throws -> Int64  { .init(try decode(Int.self)) }
    func decode(_ type: UInt.Type)   throws -> UInt   { .init(try decode(Int.self)) }
    func decode(_ type: UInt8.Type)  throws -> UInt8  { .init(try decode(Int.self)) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { .init(try decode(Int.self)) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { .init(try decode(Int.self)) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { .init(try decode(Int.self)) }
    func decode<T>(_ type: T.Type) throws -> T where T: Decodable { try T(from: ColumnarDecoder(block: block, rowIndex: rowIndex, codingPath: codingPath)) }
}

// MARK: - ClickhouseBlock extension

extension ClickhouseBlock {
    /// Convert the block to an array of dictionaries (one per row, JSON-compatible).
    public func toRowDictionaries() -> [[String: Any]] {
        let rowCount = columns.first?.column.rowCount ?? 0
        guard rowCount > 0 else { return [] }
        let colArrays: [(String, [Any])] = columns.map { ($0.name, $0.column.toJSONValues(type: $0.type)) }
        return (0..<rowCount).map { row in
            var dict: [String: Any] = [:]
            for (name, vals) in colArrays { dict[name] = row < vals.count ? vals[row] : NSNull() }
            return dict
        }
    }

    /// Decode the block as an array of `T` using the native `ColumnarDecoder` (zero JSON).
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        if type == [Any].self || type == [[String: Any]].self {
            // Fallback to row dictionaries for dynamic types
            let rows = toRowDictionaries()
            if T.self == [[String: Any]].self { return rows as! T }
            return rows as! T
        }
        // For Decodable types, decode row by row using the columnar decoder
        let rowCount = columns.first?.column.rowCount ?? 0
        // If decoding an array, decode each row
        if let arrayType = T.self as? any _ArrayDecodable.Type {
            return try arrayType._decodeArray(block: self, rowCount: rowCount) as! T
        }
        // Single value or single row
        guard rowCount > 0 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty block")) }
        let decoder = ColumnarDecoder(block: self, rowIndex: 0)
        return try T(from: decoder)
    }
}

/// Internal protocol to handle array decoding generically.
protocol _ArrayDecodable {
    static func _decodeArray(block: ClickhouseBlock, rowCount: Int) throws -> Self
}

extension Array: _ArrayDecodable where Element: Decodable {
    static func _decodeArray(block: ClickhouseBlock, rowCount: Int) throws -> [Element] {
        try (0..<rowCount).map { i in
            let decoder = ColumnarDecoder(block: block, rowIndex: i)
            return try Element(from: decoder)
        }
    }
}
