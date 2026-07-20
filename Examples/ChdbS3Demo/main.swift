import Foundation
import Swift_chdb

/// Example: S3-backed storage with chDB.
///
/// Prerequisites:
///   - An S3-compatible bucket (AWS S3, MinIO, etc.)
///   - Set env vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION (or equivalent)
///   - For MinIO: also set MINIO_ENDPOINT
///
/// Run:
///   swift run --target ChdbS3Demo
///
/// This demo:
///   1. Creates a config XML for S3 disk
///   2. Connects with S3 as the storage policy
///   3. Creates tables that live on S3
///   4. Inserts and queries data
///   5. Shows how a second instance sharing the same S3 bucket sees the same data

// MARK: - Configuration

struct S3Config {
    let bucket: String
    let region: String
    let endpoint: String       // e.g. "https://s3.eu-west-1.amazonaws.com/data/"
    let accessKey: String
    let secretKey: String

    static func fromEnvironment() -> S3Config? {
        guard let bucket = ProcessInfo.processInfo.environment["S3_BUCKET"] else {
            print("⚠️  Set S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION")
            print("    For MinIO: also set MINIO_ENDPOINT")
            return nil
        }
        let region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "eu-west-1"
        let accessKey = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] ?? ""
        let secretKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] ?? ""

        // Auto-detect endpoint: MinIO vs AWS
        let endpoint: String
        if let minioEP = ProcessInfo.processInfo.environment["MINIO_ENDPOINT"] {
            endpoint = "https://\(minioEP)/\(bucket)/data/"
        } else {
            endpoint = "https://s3.\(region).amazonaws.com/\(bucket)/data/"
        }
        return S3Config(bucket: bucket, region: region, endpoint: endpoint,
                        accessKey: accessKey, secretKey: secretKey)
    }
}

// MARK: - Config XML generation

func createS3ConfigXML(_ s3: S3Config) -> String {
    return """
    <clickhouse>
        <storage_configuration>
            <disks>
                <s3_disk>
                    <type>s3</type>
                    <endpoint>\(s3.endpoint)</endpoint>
                    <access_key_id>\(s3.accessKey)</access_key_id>
                    <secret_access_key>\(s3.secretKey)</secret_access_key>
                    <region>\(s3.region)</region>
                    <send_metadata>true</send_metadata>
                </s3_disk>
            </disks>
            <policies>
                <s3_policy>
                    <volumes>
                        <main>
                            <disk>s3_disk</disk>
                        </main>
                    </volumes>
                </s3_policy>
            </policies>
        </storage_configuration>
    </clickhouse>
    """
}

// MARK: - Main

@main
enum Main {
    static func main() async throws {
        print("=== chDB S3 Storage Demo ===\n")

        guard let s3 = S3Config.fromEnvironment() else {
            print("❌ Missing S3 configuration. Set environment variables and try again.")
            return
        }

        // Write config to a temp file
        let configXML = createS3ConfigXML(s3)
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chdb_s3_config_\(UUID().uuidString.prefix(8)).xml")
        try configXML.write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }

        print("📝 Config written to \(configURL.path)")
        print("📦 S3 endpoint: \(s3.endpoint)")
        print("")

        // ──────────────────────────────────────
        // Instance A — create data on S3
        // ──────────────────────────────────────
        print("─── Instance A: writing data ───")
        let dbA = try Chdb(path: "/tmp/chdb-s3-demo-a", config: configURL.path)

        try await dbA.query("DROP TABLE IF EXISTS s3_events")
        try await dbA.query("""
            CREATE TABLE s3_events (
                event_time DateTime,
                event_type String,
                value UInt64
            ) ENGINE = MergeTree()
            ORDER BY (event_type, event_time)
            SETTINGS storage_policy = 's3_policy'
        """)
        print("✅ Created s3_events table on S3")

        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 00:00:00', 'click', 42)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 01:00:00', 'view', 100)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 02:00:00', 'click', 55)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 03:00:00', 'purchase', 1)")
        print("✅ Inserted 4 rows")

        let countA = try await dbA.query("SELECT count(*) FROM s3_events", format: .tsv)
        print("📊 Instance A count: \(countA.text ?? "?")")
        print("")

        // ──────────────────────────────────────
        // Instance B — read the same data from S3
        // ──────────────────────────────────────
        print("─── Instance B: reading same data ───")
        let dbB = try Chdb(path: "/tmp/chdb-s3-demo-b", config: configURL.path)

        // ATTACH TABLE discovers existing S3 parts
        try await dbB.query("DROP TABLE IF EXISTS s3_events")
        try await dbB.query("""
            CREATE TABLE s3_events (
                event_time DateTime,
                event_type String,
                value UInt64
            ) ENGINE = MergeTree()
            ORDER BY (event_type, event_time)
            SETTINGS storage_policy = 's3_policy'
        """)

        let rowsB = try await dbA.query("SELECT event_type, count(*) AS cnt, sum(value) AS total FROM s3_events GROUP BY event_type ORDER BY cnt DESC", format: .prettyCompact)
        print("📊 Shared data from S3:\n\(rowsB.text ?? "")")
        print("")

        print("─── Summary ───")
        print("✅ Data persisted on S3 — accessible from any instance")
        print("💡 Cost: ~$0.023/GB/month vs ~$0.10+/GB/month for local SSD")
        print("")
        print("🔗 For production: add local cache to avoid repeated S3 reads:")
        print("""
            <s3_cache>
                <type>cache</type>
                <disk>s3_disk</disk>
                <path>s3_cache/</path>
                <max_size>10000000000</max_size>
            </s3_cache>
        """)
    }
}
