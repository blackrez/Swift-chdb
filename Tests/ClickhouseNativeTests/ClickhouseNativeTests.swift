import Testing
import Foundation
@testable import ClickhouseNative
import Cclickhouse

// MARK: - Column Accessor Tests

@Suite("ClickhouseColumn accessors")
struct ColumnAccessorTests {

    // MARK: stringValues

    @Test("stringValues — bare String column")
    func bareString() {
        let col = ClickhouseColumn.string(["Paris", "Lyon", "Marseille"])
        #expect(col.stringValues == ["Paris", "Lyon", "Marseille"])
    }

    @Test("stringValues — Nullable(String), all non-null")
    func nullableStringAllPresent() {
        let col = ClickhouseColumn.nullable(
            nulls: [false, false, false],
            inner: .string(["Paris", "Lyon", "Marseille"])
        )
        #expect(col.stringValues == ["Paris", "Lyon", "Marseille"])
    }

    @Test("stringValues — Nullable(String), partial nulls")
    func nullableStringPartialNulls() {
        let col = ClickhouseColumn.nullable(
            nulls: [false, true, false],
            inner: .string(["Paris", "", "Marseille"])
        )
        // stringValues drops null-awareness and returns the raw inner strings
        #expect(col.stringValues == ["Paris", "", "Marseille"])
    }

    @Test("stringValues — LowCardinality(String)")
    func lcString() {
        let col = ClickhouseColumn.lowCardinality(
            keys: [0, 1, 0, 2],
            dict: .string(["Paris", "Lyon", "Marseille"])
        )
        #expect(col.stringValues == ["Paris", "Lyon", "Paris", "Marseille"])
    }

    @Test("stringValues — LowCardinality(Nullable(String))")
    func lcNullableString() {
        // LC(Nullable(String)): slot 0 is NULL sentinel → ""
        let col = ClickhouseColumn.lowCardinality(
            keys: [1, 0, 2, 0],
            dict: .nullable(
                nulls: [true, false, false],
                inner: .string(["", "Paris", "Lyon"])
            )
        )
        // Keys: 1→"Paris", 0→"" (null sentinel), 2→"Lyon", 0→"" (null sentinel)
        #expect(col.stringValues == ["Paris", "", "Lyon", ""])
    }

    @Test("stringValues — returns nil for non-string types")
    func stringValuesNonString() {
        let intCol = ClickhouseColumn.fixed(Data([0x01, 0x00, 0x00, 0x00]), elemSize: 4)
        #expect(intCol.stringValues == nil)
    }

    @Test("stringValues — returns nil for unsupported wrappers")
    func stringValuesUnsupported() {
        let arrayCol = ClickhouseColumn.array(
            offsets: [2],
            values: .string(["a", "b"])
        )
        #expect(arrayCol.stringValues == nil)
    }

    @Test("stringValues — empty String column")
    func emptyStringColumn() {
        let col = ClickhouseColumn.string([])
        #expect(col.stringValues == [])
    }

    @Test("stringValues — empty Nullable(String)")
    func emptyNullableString() {
        let col = ClickhouseColumn.nullable(nulls: [], inner: .string([]))
        #expect(col.stringValues == [])
    }

    // MARK: nullableStringValues

    @Test("nullableStringValues — Nullable(String), partial nulls")
    func nullableStringNullablePartial() {
        let col = ClickhouseColumn.nullable(
            nulls: [false, true, false, true],
            inner: .string(["Paris", "", "Lyon", ""])
        )
        #expect(col.nullableStringValues == ["Paris", nil, "Lyon", nil])
    }

    @Test("nullableStringValues — Nullable(String), all non-null")
    func nullableStringAllNonNull() {
        let col = ClickhouseColumn.nullable(
            nulls: [false, false, false],
            inner: .string(["a", "b", "c"])
        )
        #expect(col.nullableStringValues == ["a", "b", "c"])
    }

    @Test("nullableStringValues — Nullable(String), all null")
    func nullableStringAllNull() {
        let col = ClickhouseColumn.nullable(
            nulls: [true, true],
            inner: .string(["", ""])
        )
        #expect(col.nullableStringValues == [nil, nil])
    }

    @Test("nullableStringValues — returns nil for bare String")
    func nullableStringBareString() {
        let col = ClickhouseColumn.string(["hello"])
        #expect(col.nullableStringValues == nil)
    }

    @Test("nullableStringValues — LowCardinality(Nullable(String))")
    func nullableLCNullableString() {
        // Slot 0 = NULL sentinel, slot 1 = "Paris", slot 2 = "Lyon"
        let col = ClickhouseColumn.lowCardinality(
            keys: [1, 0, 2],
            dict: .nullable(
                nulls: [true, false, false],
                inner: .string(["", "Paris", "Lyon"])
            )
        )
        #expect(col.nullableStringValues == ["Paris", nil, "Lyon"])
    }

    @Test("nullableStringValues — returns nil for non-string nullable")
    func nullableStringNonString() {
        let col = ClickhouseColumn.nullable(
            nulls: [false],
            inner: .fixed(Data([0x01, 0x00, 0x00, 0x00]), elemSize: 4)
        )
        #expect(col.nullableStringValues == nil)
    }

    @Test("nullableStringValues — empty columns")
    func nullableStringEmpty() {
        let col1 = ClickhouseColumn.nullable(nulls: [], inner: .string([]))
        #expect(col1.nullableStringValues == [])

        let col2 = ClickhouseColumn.lowCardinality(
            keys: [],
            dict: .nullable(nulls: [], inner: .string([]))
        )
        #expect(col2.nullableStringValues == [])
    }

    // MARK: Row count

    @Test("rowCount — string column")
    func rowCountString() {
        #expect(ClickhouseColumn.string(["a", "b", "c"]).rowCount == 3)
        #expect(ClickhouseColumn.string([]).rowCount == 0)
    }

    @Test("rowCount — nullable column delegates to inner")
    func rowCountNullable() {
        let col = ClickhouseColumn.nullable(nulls: [false, true], inner: .string(["a", "b"]))
        #expect(col.rowCount == 2)
    }

    @Test("rowCount — lowCardinality uses keys count")
    func rowCountLC() {
        let col = ClickhouseColumn.lowCardinality(keys: [0, 1, 2, 0], dict: .string(["a", "b", "c"]))
        #expect(col.rowCount == 4)
    }

    // MARK: JSON conversion

    @Test("toJSONValues — string column")
    func jsonString() {
        let col = ClickhouseColumn.string(["Paris", "Lyon"])
        let type = try! ClickhouseType.parse("String")
        let json = col.toJSONValues(type: type)
        #expect(json as? [String] == ["Paris", "Lyon"])
    }

    @Test("toJSONValues — Nullable(String)")
    func jsonNullableString() {
        let col = ClickhouseColumn.nullable(
            nulls: [false, true],
            inner: .string(["Paris", ""])
        )
        let type = try! ClickhouseType.parse("Nullable(String)")
        let json = col.toJSONValues(type: type)
        #expect(json.count == 2)
        #expect(json[0] as? String == "Paris")
        #expect(json[1] is NSNull)
    }

    @Test("toJSONValues — LowCardinality(String)")
    func jsonLCString() {
        let col = ClickhouseColumn.lowCardinality(
            keys: [0, 1, 0],
            dict: .string(["Paris", "Lyon"])
        )
        let type = try! ClickhouseType.parse("LowCardinality(String)")
        let json = col.toJSONValues(type: type)
        #expect(json as? [String] == ["Paris", "Lyon", "Paris"])
    }

    @Test("toJSONValues — LowCardinality(Nullable(String))")
    func jsonLCNullableString() {
        let col = ClickhouseColumn.lowCardinality(
            keys: [1, 0, 2],
            dict: .nullable(
                nulls: [true, false, false],
                inner: .string(["", "Paris", "Lyon"])
            )
        )
        let type = try! ClickhouseType.parse("LowCardinality(Nullable(String))")
        let json = col.toJSONValues(type: type)
        #expect(json.count == 3)
        #expect(json[0] as? String == "Paris")
        #expect(json[1] is NSNull)
        #expect(json[2] as? String == "Lyon")
    }
}

// MARK: - Native Format Binary Parsing Tests

@Suite("ClickhouseBlock Native binary parsing")
struct NativeFormatParsingTests {

    // MARK: - Helpers

    /// Write a ClickHouse varuint (unsigned LEB128).
    func writeVaruint(_ value: UInt64) -> Data {
        var v = value
        var data = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
        return data
    }

    /// Write a ClickHouse string (varuint length prefix + UTF-8 bytes).
    func writeString(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        return writeVaruint(UInt64(bytes.count)) + bytes
    }

    /// Write a fixed-size integer in little-endian.
    func writeUInt64LE(_ value: UInt64) -> Data {
        var v = value
        return Data(bytes: &v, count: MemoryLayout<UInt64>.size)
    }

    func writeUInt32LE(_ value: UInt32) -> Data {
        var v = value
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    /// Build a complete native block with column names, types and data.
    func buildBlock(
        columns: [(name: String, type: String, data: Data)]
    ) -> Data {
        var block = Data()
        block.append(writeVaruint(UInt64(columns.count)))  // ncols
        block.append(writeVaruint(UInt64(columns.first?.data.isEmpty == false ? 0 : 0)))  // nrows placeholder

        let nrows: UInt64
        if columns.isEmpty {
            nrows = 0
        } else {
            // Infer nrows from the first column's data
            // For fixed-size: nrows = data.count / elem_size
            // For others, we set it explicitly
            nrows = 0  // will be overridden
        }

        block = Data()  // restart
        block.append(writeVaruint(UInt64(columns.count)))
        // We'll compute nrows after building column headers
        // For now, rebuild properly below
        return Data()
    }

    /// Build a complete native block with proper row count.
    func buildBlock(nrows: UInt64, columns: [(name: String, type: String, data: Data)]) -> Data {
        var block = Data()
        block.append(writeVaruint(UInt64(columns.count)))  // ncols
        block.append(writeVaruint(nrows))                   // nrows

        for col in columns {
            block.append(writeString(col.name))
            block.append(writeString(col.type))
            block.append(col.data)
        }
        return block
    }

    /// Build string column data: one varuint-prefixed string per row.
    func buildStringData(_ values: [String]) -> Data {
        var data = Data()
        for v in values {
            data.append(writeString(v))
        }
        return data
    }

    /// Build Nullable(String) column data: null_map + inner string data.
    func buildNullableStringData(nulls: [Bool], values: [String]) -> Data {
        precondition(nulls.count == values.count)
        var data = Data()
        // Null map: 1 byte per row
        for n in nulls {
            data.append(n ? UInt8(1) : UInt8(0))
        }
        // Inner string data
        data.append(buildStringData(values))
        return data
    }

    /// Build LowCardinality(String) column data.
    /// Wire format: key version prefix (uint64 LE = 1), flags, dict_n, dict data, key_rows, keys.
    func buildLCStringData(dictStrings: [String], keys: [UInt8]) -> Data {
        var data = Data()
        // Key version prefix (required by chc__col_read_prefix)
        data.append(writeUInt64LE(1))
        // flags: HasAdditionalKeys (0x200) | index_type = 0 (UInt8 keys)
        data.append(writeUInt64LE(0x200))
        // dict_n
        data.append(writeUInt64LE(UInt64(dictStrings.count)))
        // dict data: string column
        data.append(buildStringData(dictStrings))
        // key_rows
        data.append(writeUInt64LE(UInt64(keys.count)))
        // keys: 1 byte per row (key_size = 1)
        data.append(Data(keys))
        return data
    }
}

// MARK: - Basic String Parsing

extension NativeFormatParsingTests {

    @Test("Parse a single String column with multiple rows")
    func parseSimpleStringColumn() throws {
        let strings = ["Paris", "Lyon", "Marseille"]
        let colData = buildStringData(strings)
        let block = buildBlock(
            nrows: 3,
            columns: [("ville", "String", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.rowCount == 3)
        #expect(parsed.columns.count == 1)
        #expect(parsed.columns[0].name == "ville")
        #expect(parsed.columns[0].type.name == "String")

        let col = parsed.columns[0].column
        #expect(col.stringValues == strings)
    }

    @Test("Parse multiple columns including String and numeric")
    func parseMixedColumns() throws {
        let colData = buildStringData(["Paris", "Lyon"])
        // Two Int32 values: 42 and 99
        var intData = Data()
        intData.append(writeUInt32LE(42))
        intData.append(writeUInt32LE(99))

        let block = buildBlock(
            nrows: 2,
            columns: [
                ("ville", "String", colData),
                ("code", "Int32", intData)
            ]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.rowCount == 2)
        #expect(parsed.columns.count == 2)

        let villes = parsed.columns[0].column
        #expect(villes.stringValues == ["Paris", "Lyon"])

        let codes = parsed.columns[1].column
        #expect(codes.int32Values == [42, 99])
    }

    @Test("Parse empty String column")
    func parseEmptyStringColumn() throws {
        let colData = buildStringData([])
        let block = buildBlock(
            nrows: 0,
            columns: [("ville", "String", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.rowCount == 0)
        // Empty block has .nothing(rows: 0) column — no string data
        #expect(parsed.columns[0].column.stringValues == nil)
    }

    @Test("Parse String column with empty strings")
    func parseEmptyStrings() throws {
        let strings = ["", "hello", "", "world"]
        let colData = buildStringData(strings)
        let block = buildBlock(
            nrows: 4,
            columns: [("s", "String", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.columns[0].column.stringValues == strings)
    }

    @Test("Parse String column with Unicode text")
    func parseUnicodeStrings() throws {
        let strings = ["Marseille", "Tōkyō", "北京", "Москва", "🇫🇷"]
        let colData = buildStringData(strings)
        let block = buildBlock(
            nrows: UInt64(strings.count),
            columns: [("name", "String", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.columns[0].column.stringValues == strings)
    }
}

// MARK: - Nullable(String) Parsing

extension NativeFormatParsingTests {

    @Test("Parse Nullable(String) — all non-null")
    func parseNullableStringAllNonNull() throws {
        let strings = ["Paris", "Lyon", "Marseille"]
        let nulls = [false, false, false]
        let colData = buildNullableStringData(nulls: nulls, values: strings)
        let block = buildBlock(
            nrows: 3,
            columns: [("ville", "Nullable(String)", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        let col = parsed.columns[0].column
        #expect(col.stringValues == strings)
        #expect(col.nullableStringValues == ["Paris", "Lyon", "Marseille"])
    }

    @Test("Parse Nullable(String) — partial nulls")
    func parseNullableStringPartialNulls() throws {
        let strings = ["Paris", "", "Marseille"]
        let nulls = [false, true, false]
        let colData = buildNullableStringData(nulls: nulls, values: strings)
        let block = buildBlock(
            nrows: 3,
            columns: [("ville", "Nullable(String)", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        let col = parsed.columns[0].column
        // stringValues drops null-awareness
        #expect(col.stringValues == strings)

        // nullableStringValues preserves nulls
        let expected: [String?] = ["Paris", nil, "Marseille"]
        #expect(col.nullableStringValues == expected)
    }

    @Test("Parse Nullable(String) — all null")
    func parseNullableStringAllNull() throws {
        let strings = ["", ""]
        let nulls = [true, true]
        let colData = buildNullableStringData(nulls: nulls, values: strings)
        let block = buildBlock(
            nrows: 2,
            columns: [("ville", "Nullable(String)", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        let col = parsed.columns[0].column
        #expect(col.nullableStringValues == [nil, nil])
    }
}

// MARK: - LowCardinality(String) Parsing

extension NativeFormatParsingTests {

    @Test("Parse LowCardinality(String)")
    func parseLCString() throws {
        let dict = ["Paris", "Lyon", "Marseille"]
        let keys: [UInt8] = [0, 1, 0, 2]
        let colData = buildLCStringData(dictStrings: dict, keys: keys)
        let block = buildBlock(
            nrows: 4,
            columns: [("ville", "LowCardinality(String)", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        let col = parsed.columns[0].column
        #expect(col.stringValues == ["Paris", "Lyon", "Paris", "Marseille"])
    }

    @Test("Parse LowCardinality(String) with large dictionary")
    func parseLCStringLargeDict() throws {
        let dict = (0..<10).map { "city_\($0)" }
        let keys: [UInt8] = [3, 7, 0, 9, 5]
        let colData = buildLCStringData(dictStrings: dict, keys: keys)
        let block = buildBlock(
            nrows: 5,
            columns: [("ville", "LowCardinality(String)", colData)]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        let col = parsed.columns[0].column
        #expect(col.stringValues == ["city_3", "city_7", "city_0", "city_9", "city_5"])
    }

    @Test("Parse LowCardinality(String) — empty")
    func parseLCStringEmpty() throws {
        // When nrows=0, the LC column body is empty (no prefix, no data)
        let block = buildBlock(
            nrows: 0,
            columns: [("ville", "LowCardinality(String)", Data())]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        // Empty block has .nothing(rows: 0) column — no string data
        #expect(parsed.columns[0].column.stringValues == nil)
    }
}

// MARK: - Mixed Column Parsing (simulating file() output)

extension NativeFormatParsingTests {

    @Test("Parse mixed Nullable(String) + Float64 — simulates file() with aggregate")
    func parseFileLikeMixedQuery() throws {
        // Simulates: SELECT ville, prix FROM file('stations.csv')
        let strings = ["Paris", "Lyon", "Marseille"]
        let nulls = [false, false, false]
        let strData = buildNullableStringData(nulls: nulls, values: strings)

        // Float64 values
        var floatData = Data()
        var v1: Double = 1.95; floatData.append(Data(bytes: &v1, count: 8))
        var v2: Double = 1.88; floatData.append(Data(bytes: &v2, count: 8))
        var v3: Double = 1.92; floatData.append(Data(bytes: &v3, count: 8))

        let block = buildBlock(
            nrows: 3,
            columns: [
                ("ville", "Nullable(String)", strData),
                ("prix", "Float64", floatData)
            ]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.rowCount == 3)
        #expect(parsed.columns[0].column.stringValues == ["Paris", "Lyon", "Marseille"])
        #expect(parsed.columns[1].column.doubleValues == [1.95, 1.88, 1.92])
    }

    @Test("Parse block with multiple column types — simulates file() GROUP BY")
    func parseFileLikeGroupByQuery() throws {
        // Simulates: SELECT ville, adresse, avg(Gazole) FROM file('stations.csv') GROUP BY ville, adresse
        let villes = ["Paris", "Lyon"]
        let adresses = ["1 rue A", "2 rue B"]
        let nulls = [false, false]
        let villeData = buildNullableStringData(nulls: nulls, values: villes)
        let adresseData = buildNullableStringData(nulls: nulls, values: adresses)

        // avg(Gazole) → Float64
        var floatData = Data()
        var v1: Double = 1.95; floatData.append(Data(bytes: &v1, count: 8))
        var v2: Double = 1.88; floatData.append(Data(bytes: &v2, count: 8))

        let block = buildBlock(
            nrows: 2,
            columns: [
                ("ville", "Nullable(String)", villeData),
                ("adresse", "Nullable(String)", adresseData),
                ("avg(Gazole)", "Float64", floatData)
            ]
        )

        guard let parsed = try ClickhouseBlock.read(from: block) else {
            Issue.record("Expected a block, got nil")
            return
        }

        #expect(parsed.rowCount == 2)

        let villesCol = parsed["ville"]!
        #expect(villesCol.stringValues == ["Paris", "Lyon"])

        let adressesCol = parsed["adresse"]!
        #expect(adressesCol.stringValues == ["1 rue A", "2 rue B"])

        let gazoleCol = parsed["avg(Gazole)"]!
        #expect(gazoleCol.doubleValues == [1.95, 1.88])
    }
}

// MARK: - Decodable Tests

@Suite("ColumnarDecoder with string types")
struct ColumnarDecoderTests {

    @Test("Decode struct with String from Nullable(String) column")
    func decodeStringFromNullable() throws {
        let block = ClickhouseBlock(
            columns: [
                .init(name: "ville", type: try ClickhouseType.parse("Nullable(String)"),
                      column: .nullable(nulls: [false, false], inner: .string(["Paris", "Lyon"])))
            ],
            rowCount: 2
        )

        struct Row: Decodable {
            let ville: String
        }

        let rows: [Row] = try block.decode()
        #expect(rows.count == 2)
        #expect(rows[0].ville == "Paris")
        #expect(rows[1].ville == "Lyon")
    }

    @Test("Decode struct with optional String from Nullable(String)")
    func decodeOptionalStringFromNullable() throws {
        let block = ClickhouseBlock(
            columns: [
                .init(name: "ville", type: try ClickhouseType.parse("Nullable(String)"),
                      column: .nullable(nulls: [false, true], inner: .string(["Paris", ""])))
            ],
            rowCount: 2
        )

        struct Row: Decodable {
            let ville: String?
        }

        let rows: [Row] = try block.decode()
        #expect(rows[0].ville == "Paris")
        #expect(rows[1].ville == nil)
    }

    @Test("Decode struct with String from LowCardinality(String)")
    func decodeStringFromLC() throws {
        let block = ClickhouseBlock(
            columns: [
                .init(name: "ville", type: try ClickhouseType.parse("LowCardinality(String)"),
                      column: .lowCardinality(keys: [0, 1, 0], dict: .string(["Paris", "Lyon"])))
            ],
            rowCount: 3
        )

        struct Row: Decodable {
            let ville: String
        }

        let rows: [Row] = try block.decode()
        #expect(rows[0].ville == "Paris")
        #expect(rows[1].ville == "Lyon")
        #expect(rows[2].ville == "Paris")
    }

    @Test("Decode struct with multiple types — simulates file() usage")
    func decodeFileLikeQuery() throws {
        func float64Data(_ values: [Double]) -> Data {
            values.withUnsafeBytes { Data($0) }
        }
        let block = ClickhouseBlock(
            columns: [
                .init(name: "ville", type: try ClickhouseType.parse("Nullable(String)"),
                      column: .nullable(nulls: [false, false, true], inner: .string(["Paris", "Lyon", ""]))),
                .init(name: "prix", type: try ClickhouseType.parse("Float64"),
                      column: .fixed(float64Data([1.23, 1.88, 1.92]), elemSize: 8))
            ],
            rowCount: 3
        )

        struct Station: Decodable {
            let ville: String?
            let prix: Double
        }

        let stations: [Station] = try block.decode()
        #expect(stations.count == 3)
        #expect(stations[0].ville == "Paris")
        #expect(stations[0].prix == 1.23)
        #expect(stations[1].ville == "Lyon")
        #expect(stations[2].ville == nil)
    }
}
