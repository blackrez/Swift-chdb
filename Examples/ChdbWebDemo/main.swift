import Foundation
import Swift_chdb
import Network

// MARK: - Run the server

/// Start the chDB web demo server.
///
/// Serves:
///   GET  /              — HTML form to submit SQL queries
///   GET  /query?sql=... — execute SQL, return JSON
///   GET  /stream?sql=.. — stream CSV results using chunked transfer encoding
///
/// Usage:
///   swift run chdb-web-demo
///   # then open http://localhost:8080

if #available(macOS 10.15, *) {
    try await WebDemoServer().run()
} else {
    print("Web demo requires macOS 10.15+")
    exit(1)
}

// MARK: - Server implementation

@available(macOS 10.15, *)
struct WebDemoServer {
    let port: UInt16
    let db: ChdbConnection

    init(port: UInt16 = 8080) throws {
        self.port = port
        self.db = try ChdbConnection()

        try await db.query("""
            CREATE TABLE IF NOT EXISTS web_demo (
                id    Int32,
                city  String,
                temp  Float64,
                ts    DateTime
            ) ENGINE = Memory
            """)

        try await db.query("TRUNCATE TABLE web_demo")
        print("  Seeding demo data...")
        try await db.query("""
            INSERT INTO web_demo VALUES
                (1, 'Paris',   22.5, now()),
                (2, 'London',  18.0, now()),
                (3, 'Tokyo',   30.2, now()),
                (4, 'New York', 15.8, now()),
                (5, 'Sydney',  26.1, now())
            """)
    }

    func run() async throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [db] connection in
            let handler = ConnectionHandler(db: db, connection: connection)
            handler.start()
        }
        listener.start(queue: .main)
        print("🌐 chDB web demo running at http://localhost:\(port)")
        print("   Try:  curl http://localhost:\(port)/query?sql=SELECT+city,temp+FROM+web_demo")
        print("   Try:  curl http://localhost:\(port)/stream?sql=SELECT+number+FROM+system.numbers+LIMIT+100")

        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}

// MARK: - Connection handler

@available(macOS 10.15, *)
final class ConnectionHandler: @unchecked Sendable {
    let db: ChdbConnection
    let connection: NWConnection
    let queue: DispatchQueue
    var buffer = Data()
    /// Self-reference kept alive while the connection is open.
    private var selfRef: ConnectionHandler?
    /// Active streaming task, cancelled on connection close.
    private var streamTask: Task<Void, Never>?

    init(db: ChdbConnection, connection: NWConnection) {
        self.db = db
        self.connection = connection
        self.queue = DispatchQueue(
            label: "chdb-web-conn.\(ObjectIdentifier(connection).hashValue)")
    }

    func start() {
        selfRef = self
        connection.start(queue: queue)
        queue.async { self.receive() }
    }

    /// Release all resources — allows deallocation.
    private func cleanup() {
        queue.async { [weak self] in
            guard let self else { return }
            streamTask?.cancel()
            streamTask = nil
            connection.cancel()
            selfRef = nil
        }
    }

    // MARK: - Receive HTTP request

    private func receive() {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            if let request = String(data: self.buffer, encoding: .utf8),
               request.contains("\r\n\r\n") {
                self.handleRequest(request)
                self.buffer.removeAll()
                return
            }

            if isComplete || error != nil {
                self.cleanup()
                return
            }

            self.receive()
        }
    }

    // MARK: - Route handling

    private func handleRequest(_ raw: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let requestLine = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { sendResponse(status: 400, body: "Bad request"); return }

        let method = String(parts[0])
        let pathAndQuery = String(parts[1])

        guard method == "GET" else { sendResponse(status: 405, body: "Method not allowed"); return }

        let urlComponents = URLComponents(string: pathAndQuery)
        let path = urlComponents?.path ?? pathAndQuery
        let sql = urlComponents?.queryItems?.first(where: { $0.name == "sql" })?.value

        switch path {
        case "/":
            sendResponse(status: 200, body: htmlPage, contentType: "text/html; charset=utf-8")
        case "/query":
            guard let sql else { sendResponse(status: 400, body: #"{"error":"Missing ?sql= parameter"}"#); return }
            handleQuery(sql)
        case "/stream":
            guard let sql else { sendResponse(status: 400, body: "Missing ?sql= parameter"); return }
            handleStream(sql)
        default:
            sendResponse(status: 404, body: "Not found")
        }
    }

    // MARK: - JSON query endpoint

    private func handleQuery(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            let result = try await db.query(sql, format: .json)
            sendResponse(status: 200, body: result.text ?? "[]",
                         contentType: "application/json")
        } catch {
            sendResponse(status: 500, body: #"{"error":"\#(String(describing: error))"}"#,
                         contentType: "application/json")
        }
    }

    // MARK: - Streaming endpoint

    private func handleStream(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(queue))

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain; charset=utf-8",
            "Transfer-Encoding: chunked",
            "Connection: keep-alive",
            "",
            ""
        ].joined(separator: "\r\n")
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })

        // The handler stays alive via selfRef until cleanup() is called,
        // so it's safe to capture self strongly in the streaming Task.
        streamTask = Task { [self] in
            do {
                for try await chunk in db.streamQuery(sql, format: .csv) {
                    guard !Task.isCancelled else { break }
                    if let text = chunk.text, !text.isEmpty {
                        let chunkData = text.data(using: .utf8) ?? Data()
                        let hexSize = String(chunkData.count, radix: 16)
                        let frame = "\(hexSize)\r\n".data(using: .utf8)! + chunkData + "\r\n".data(using: .utf8)!
                        queue.async {
                            self.connection.send(content: frame, completion: .contentProcessed { _ in })
                        }
                    }
                }
                queue.async {
                    self.connection.send(content: "0\r\n\r\n".data(using: .utf8),
                                         completion: .contentProcessed { [weak self] _ in
                        self?.cleanup()
                    })
                }
            } catch {
                queue.async {
                    self.connection.send(content: "0\r\n\r\n".data(using: .utf8),
                                         completion: .contentProcessed { [weak self] _ in
                        self?.cleanup()
                    })
                }
            }
        }
    }

    // MARK: - Response helpers

    private func sendResponse(status: Int, body: String,
                              contentType: String = "text/plain; charset=utf-8") {
        dispatchPrecondition(condition: .onQueue(queue))
        streamTask?.cancel()
        let data = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            body
        ].joined(separator: "\r\n").data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.cleanup()
        })
    }
}

// MARK: - HTML page

private let htmlPage = """
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <title>chDB Web Demo</title>
        <style>
            body { font: 14px/1.4 -apple-system, sans-serif; max-width: 800px; margin: 2em auto; padding: 0 1em; }
            textarea, pre { width: 100%; font: 13px Menlo, monospace; }
            textarea { height: 5em; }
            pre { background: #f5f5f5; padding: 1em; overflow-x: auto; min-height: 3em; }
            button { font-size: 14px; padding: 0.5em 1.5em; cursor: pointer; }
            .error { color: #c00; }
            nav a { margin-right: 1em; }
        </style>
    </head>
    <body>
        <h1>🔍 chDB Web Demo</h1>
        <nav>
            <a href="/">Home</a>
            <a href="/query?sql=SELECT+city,temp,ts+FROM+web_demo+ORDER+BY+temp+DESC">Sample query</a>
            <a href="/stream?sql=SELECT+number+FROM+system.numbers+LIMIT+100">Stream 100 rows</a>
        </nav>

        <form onsubmit="runQuery(event)">
            <p><label>SQL query:
                <textarea id="sql">SELECT city, temp, ts FROM web_demo ORDER BY temp DESC</textarea>
            </label></p>
            <p>
                <button type="submit" id="btn-query">▶ JSON query</button>
                <button type="submit" id="btn-stream" onclick="useStream()">▶ Stream CSV</button>
            </p>
        </form>
        <pre id="output">Results appear here...</pre>

        <script>
            async function runQuery(e) {
                e.preventDefault()
                const sql = encodeURIComponent(document.getElementById('sql').value)
                const isStream = document.activeElement?.id === 'btn-stream'
                const out = document.getElementById('output')
                out.className = ''

                if (isStream) {
                    out.textContent = 'Connecting...'
                    const url = `/stream?sql=${sql}`
                    try {
                        const resp = await fetch(url)
                        const reader = resp.body.getReader()
                        const decoder = new TextDecoder()
                        let text = ''
                        while (true) {
                            const { done, value } = await reader.read()
                            if (done) break
                            text += decoder.decode(value, { stream: true })
                        }
                        out.textContent = text
                    } catch (e) {
                        out.className = 'error'
                        out.textContent = 'Error: ' + e
                    }
                } else {
                    try {
                        const resp = await fetch(`/query?sql=${sql}`)
                        const data = await resp.json()
                        out.textContent = JSON.stringify(data, null, 2)
                    } catch (e) {
                        out.className = 'error'
                        out.textContent = 'Error: ' + e
                    }
                }
            }

            function useStream() {
                document.activeElement?.click()
            }
        </script>
    </body>
    </html>
    """
