import AWSLambdaEvents
import AWSLambdaRuntime
import Swift_chdb
import ClickhouseNative
import Foundation

// MARK: - Request / Response

struct QueryRequest: Decodable {
    let sql: String
    let format: String?

    var outputFormat: ChdbFormat {
        format.flatMap { ChdbFormat(rawValue: $0) } ?? .native
    }
}

struct QueryResponse: Encodable {
    let columns: [ColumnInfo]?
    let rows: [[JsonValue]]?
    let result: String?
    let row_count: UInt64?
    let elapsed: Double
    let bytes_read: UInt64
    let error: String?
}

struct ColumnInfo: Encodable {
    let name: String
    let type: String
}

enum JsonValue: Encodable {
    case null
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .int(let v):  try c.encode(v)
        case .uint(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

// MARK: - Native format → structured JSON

func convertColumn(_ col: ClickhouseColumn, row: Int) -> JsonValue {
    // Fast path: typed accessors
    if let vals = col.int32Values, row < vals.count { return .int(Int64(vals[row])) }
    if let vals = col.int64Values, row < vals.count { return .int(vals[row]) }
    if let vals = col.uint64Values, row < vals.count { return .uint(vals[row]) }
    if let vals = col.floatValues, row < vals.count { return .double(Double(vals[row])) }
    if let vals = col.doubleValues, row < vals.count { return .double(vals[row]) }
    if let vals = col.stringValues, row < vals.count { return .string(vals[row]) }
    if let vals = col.nullableStringValues, row < vals.count { return vals[row].map(JsonValue.string) ?? .null }
    if let vals = col.nullableUInt64Values, row < vals.count { return vals[row].map(JsonValue.uint) ?? .null }

    // Fallback: JSON string representation
    let all = col.toJSONValues()
    guard row < all.count else { return .null }
    let v = all[row]
    if v is NSNull { return .null }
    if let s = v as? String { return .string(s) }
    if let n = v as? NSNumber {
        let d = n.doubleValue
        if d == floor(d), d <= Double(Int64.max), d >= Double(Int64.min) {
            return .int(Int64(d))
        }
        return .double(d)
    }
    return .string("\(v)")
}

func runNativeQuery(_ sql: String) -> QueryResponse {
    let result = ChdbConnection.query(sql: sql, format: .native)
    if let error = result.errorMessage {
        return QueryResponse(columns: nil, rows: nil, result: nil, row_count: nil,
                             elapsed: result.elapsed, bytes_read: result.bytesRead, error: error)
    }
    guard let data = result.rawData,
          let block = try? ClickhouseBlock.read(from: data) else {
        return QueryResponse(columns: nil, rows: nil, result: nil, row_count: nil,
                             elapsed: result.elapsed, bytes_read: result.bytesRead, error: "Failed to parse native block")
    }

    let columns: [ColumnInfo] = zip(block.columnNames, block.columnTypes).map { name, type in
        ColumnInfo(name: name, type: type.name)
    }

    let rows: [[JsonValue]] = (0..<block.rowCount).map { row in
        block.columnNames.map { name -> JsonValue in
            guard let col = block[name] else { return .null }
            return convertColumn(col, row: row)
        }
    }

    return QueryResponse(columns: columns, rows: rows, result: nil,
                         row_count: UInt64(block.rowCount),
                         elapsed: result.elapsed, bytes_read: result.bytesRead, error: nil)
}

func runTextQuery(_ sql: String, format: ChdbFormat) -> QueryResponse {
    let result = ChdbConnection.query(sql: sql, format: format)
    return QueryResponse(columns: nil, rows: nil, result: result.text, row_count: nil,
                         elapsed: result.elapsed, bytes_read: result.bytesRead, error: result.errorMessage)
}

// MARK: - Lambda handler

let runtime = LambdaRuntime {
    (event: APIGatewayV2Request, context: LambdaContext) -> APIGatewayV2Response in

    var headers = HTTPHeaders()
    headers["content-type"] = "application/json"

    guard let body = event.body,
          let data = body.data(using: .utf8),
          let request = try? JSONDecoder().decode(QueryRequest.self, from: data) else {
        return APIGatewayV2Response(statusCode: .badRequest, headers: headers,
                                     body: #"{"error":"Missing or invalid JSON"}"#)
    }

    context.logger.info("Query [\(request.outputFormat)]: \(request.sql)")

    let response = request.outputFormat == .native
        ? runNativeQuery(request.sql)
        : runTextQuery(request.sql, format: request.outputFormat)

    if let error = response.error {
        context.logger.error("Error: \(error)")
    } else if let rows = response.rows {
        context.logger.info("OK — \(rows.count) rows, \(String(format: "%.3f", response.elapsed))s")
    } else {
        context.logger.info("OK — \(String(format: "%.3f", response.elapsed))s")
    }

    let status: HTTPResponseStatus = response.error == nil ? .ok : .internalServerError
    return try APIGatewayV2Response(statusCode: status, headers: headers, encodableBody: response)
}

try await runtime.run()
