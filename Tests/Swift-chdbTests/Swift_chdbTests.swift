import Testing
@testable import Swift_chdb

// chDB only supports one connection per process, so all tests must share
// a single connection. We use a serialized suite to avoid parallelism.

@Suite(.serialized)
struct ChdbTests {
    @Test("Initialize an in-memory chDB connection")
    func initConnection() async throws {
        let db = try Chdb()
        let closed = await db.isClosed
        #expect(!closed)
        await db.close()
    }

    @Test("Execute a simple SELECT query")
    func simpleQuery() async throws {
        let db = try Chdb()
        let result = try await db.query("SELECT 1 AS n, 'hello' AS s", format: .csv)
        #expect(result.text != nil)
        #expect(result.text!.contains("1"))
        #expect(result.text!.contains("hello"))
        #expect(result.elapsed > 0)
        await db.close()
    }

    @Test("Execute query with parameter binding")
    func queryWithParams() async throws {
        let db = try Chdb()
        let result = try await db.query(
            "SELECT {x:Int32} AS val, {y:String} AS label",
            format: .csv,
            params: ["x": "42", "y": "answer"]
        )
        #expect(result.text != nil)
        #expect(result.text!.contains("42"))
        #expect(result.text!.contains("answer"))
        await db.close()
    }

    @Test("Query with JSON output format")
    func jsonOutput() async throws {
        let db = try Chdb()
        let result = try await db.query("SELECT 1 AS col", format: .json)
        #expect(result.text != nil)
        #expect(result.text!.contains("\"col\""))
        #expect(result.text!.contains("1"))
        await db.close()
    }

    @Test("Query with CSV format and multiple rows")
    func multipleRows() async throws {
        let db = try Chdb()
        let result = try await db.query(
            "SELECT number, number * 2 AS doubled FROM system.numbers LIMIT 5",
            format: .csv
        )
        #expect(result.text != nil)
        let rows = result.text!.split(separator: "\n")
        #expect(rows.count == 5)
        #expect(result.rowsRead == 5)
        #expect(result.bytesRead > 0)
        await db.close()
    }

    @Test("Invalid SQL throws error")
    func invalidQuery() async throws {
        let db = try Chdb()
        do {
            try await db.query("SELECT invalid_syntax_123")
            Issue.record("Expected ChdbError to be thrown")
        } catch {
            #expect(error is ChdbError)
        }
        await db.close()
    }

    @Test("Close connection prevents further queries")
    func closeConnection() async throws {
        let db = try Chdb()
        await db.close()
        let closed = await db.isClosed
        #expect(closed)
        do {
            try await db.query("SELECT 1")
            Issue.record("Expected ChdbError.connectionClosed")
        } catch ChdbError.connectionClosed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Deinitialization closes connection gracefully")
    func deinitCloses() async throws {
        var db: Chdb? = try Chdb()
        let closed = await db!.isClosed
        #expect(!closed)
        db = nil
        #expect(Bool(true))
    }

    @Test("Handle larger result sets")
    func largerResult() async throws {
        let db = try Chdb()
        let result = try await db.query(
            "SELECT number FROM system.numbers LIMIT 1000",
            format: .csv
        )
        #expect(result.text != nil)
        let rows = result.text!.split(separator: "\n")
        #expect(rows.count >= 1000)
        #expect(result.rowsRead >= 1000)
        await db.close()
    }

    // MARK: - Query pipeline tests (DDL, DML, formats)

    @Test("DDL CREATE TABLE and INSERT")
    func ddlCreateTable() async throws {
        let db = try Chdb()
        _ = try await db.query("CREATE TABLE IF NOT EXISTS test_ddl (id Int32) ENGINE = Memory")
        _ = try await db.query("INSERT INTO test_ddl VALUES (1), (2), (3)")

        let result = try await db.query("SELECT * FROM test_ddl ORDER BY id", format: .csv)
        #expect(result.rowsRead == 3)
        #expect(result.text?.contains("1") == true)

        _ = try await db.query("DROP TABLE test_ddl")
        await db.close()
    }

    @Test("Native format returns binary data")
    func nativeFormat() async throws {
        let db = try Chdb()
        _ = try await db.query("CREATE TABLE test_native (id Int32, name String) ENGINE = Memory")
        _ = try await db.query("INSERT INTO test_native VALUES (1, 'alice'), (2, 'bob')")

        let result = try await db.query("SELECT * FROM test_native ORDER BY id", format: .native)
        #expect(result.rawData != nil)
        #expect(result.rowsRead == 2)

        _ = try await db.query("DROP TABLE test_native")
        await db.close()
    }

    @Test("Error propagation on invalid SQL")
    func errorPropagation() async throws {
        let db = try Chdb()
        do {
            _ = try await db.query("SELECT * FROM nonexistent_table_xyz")
            Issue.record("Expected ChdbError to be thrown")
        } catch {
            #expect(error is ChdbError)
        }
        await db.close()
    }

    @Test("Empty result set")
    func emptyResult() async throws {
        let db = try Chdb()
        _ = try await db.query("CREATE TABLE test_empty (id Int32) ENGINE = Memory")

        let result = try await db.query("SELECT * FROM test_empty", format: .csv)
        #expect(result.rowsRead == 0)

        _ = try await db.query("DROP TABLE test_empty")
        await db.close()
    }

    @Test("JSONEachRow format")
    func jsonFormat() async throws {
        let db = try Chdb()
        let result = try await db.query(
            "SELECT number FROM system.numbers LIMIT 3",
            format: .jsonEachRow
        )
        #expect(result.rowsRead == 3)
        #expect(result.text != nil)
        #expect(result.text!.contains(#""number":"#))
        await db.close()
    }
}
