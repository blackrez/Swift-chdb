import Foundation
import Swift_chdb

/// Example: S3-backed storage with chDB.
///
/// Works with any S3-compatible storage: AWS S3, MinIO, Garage, Ceph, etc.
///
/// Prerequisites:
///   - An S3-compatible bucket
///   - Set env vars: S3_ENDPOINT (or AWS endpoint), S3_BUCKET,
///     AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
///   - For AWS S3:     set S3_ENDPOINT="https://s3.<region>.amazonaws.com"
///   - For Garage:     set S3_ENDPOINT="http://localhost:3900"
///   - For MinIO:      set S3_ENDPOINT="http://localhost:9000"
///
/// Run:
///   # Garage
///   S3_ENDPOINT=http://localhost:3900 \
///   S3_BUCKET=chdb-demo \
///   AWS_ACCESS_KEY_ID=GK... \
///   AWS_SECRET_ACCESS_KEY=... \
///   swift run ChdbS3Demo
///
///   # MinIO
///   S3_ENDPOINT=http://localhost:9000 \
///   S3_BUCKET=chdb-demo \
///   AWS_ACCESS_KEY_ID=minioadmin \
///   AWS_SECRET_ACCESS_KEY=minioadmin \
///   swift run ChdbS3Demo
///
///   # AWS S3
///   S3_BUCKET=my-bucket \
///   AWS_ACCESS_KEY_ID=AKIA... \
///   AWS_SECRET_ACCESS_KEY=... \
///   AWS_REGION=eu-west-1 \
///   swift run ChdbS3Demo
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
    let endpoint: String       // full endpoint URL incl. bucket path, e.g. "http://localhost:3900/chdb-demo/data/"
    let accessKey: String
    let secretKey: String
    let isAWS: Bool

    static func fromEnvironment() -> S3Config? {
        guard let bucket = ProcessInfo.processInfo.environment["S3_BUCKET"] else {
            print("⚠️  Set S3_BUCKET, S3_ENDPOINT (or AWS_REGION), AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
            return nil
        }
        let accessKey = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] ?? ""
        let secretKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] ?? ""

        let endpoint: String
        let region: String
        let isAWS: Bool

        if let customEP = ProcessInfo.processInfo.environment["S3_ENDPOINT"] {
            // Non-AWS S3-compatible: Garage, MinIO, Ceph, etc.
            endpoint = "\(customEP)/\(bucket)/"
            region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "garage"
            isAWS = false
        } else if let awsRegion = ProcessInfo.processInfo.environment["AWS_REGION"] {
            // AWS S3
            endpoint = "https://s3.\(awsRegion).amazonaws.com/\(bucket)/data/"
            region = awsRegion
            isAWS = true
        } else {
            print("⚠️  Set either S3_ENDPOINT (for Garage/MinIO/Ceph) or AWS_REGION (for AWS S3)")
            return nil
        }

        return S3Config(bucket: bucket, region: region, endpoint: endpoint,
                        accessKey: accessKey, secretKey: secretKey, isAWS: isAWS)
    }
}

// MARK: - Config XML generation

func createS3ConfigXML(_ s3: S3Config) -> String {
    // Non-AWS endpoints (Garage, MinIO, Ceph): no region, explicit credentials.
    // AWS S3: virtual-hosted style with region and metadata support.
    let extraConfig: String
    if !s3.isAWS {
        extraConfig = "                    <region>\(s3.region)</region>\n                    <use_environment_credentials>false</use_environment_credentials>\n"
    } else {
        extraConfig = """
                    <send_metadata>true</send_metadata>
                    <region>\(s3.region)</region>

        """
    }

    return """
    <clickhouse>
        <storage_configuration>
            <disks>
                <s3_disk>
                    <type>s3</type>
                    <endpoint>\(s3.endpoint)</endpoint>
                    <access_key_id>\(s3.accessKey)</access_key_id>
                    <secret_access_key>\(s3.secretKey)</secret_access_key>
        \(extraConfig)        </s3_disk>
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
        // Use stderr for unbuffered output (stdout is lost on fatalError)
        func log(_ msg: String) { fputs("\(msg)\n", stderr) }

        log("=== chDB S3 Storage Demo ===")

        guard let s3 = S3Config.fromEnvironment() else {
            log("❌ Missing S3 configuration. Set environment variables and try again.")
            return
        }

        // Write config to a temp file
        let configXML = createS3ConfigXML(s3)
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chdb_s3_config_\(UUID().uuidString.prefix(8)).xml")
        try configXML.write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }

        log("📝 Config written to \(configURL.path)")
        log("📦 S3 endpoint: \(s3.endpoint)")
        log("📦 Provider: \(s3.isAWS ? "AWS S3" : "S3-compatible (Garage/MinIO/etc.)")")
        log("📄 Region: \(s3.region)")

        // ──────────────────────────────────────
        // Instance A — create data on S3
        // ──────────────────────────────────────
        log("─── Instance A: writing data ───")
        let dbA = try Chdb(path: "/tmp/chdb-s3-demo-a", config: .file(configURL.path))
        log("✅ Connected (Instance A)")

        _ = try await dbA.query("DROP TABLE IF EXISTS s3_events")
        try await dbA.query("""
            CREATE TABLE s3_events (
                event_time DateTime,
                event_type String,
                value UInt64
            ) ENGINE = MergeTree()
            ORDER BY (event_type, event_time)
            SETTINGS storage_policy = 's3_policy'
        """)
        log("✅ Created s3_events table on S3")

        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 00:00:00', 'click', 42)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 01:00:00', 'view', 100)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 02:00:00', 'click', 55)")
        try await dbA.query("INSERT INTO s3_events VALUES ('2024-01-01 03:00:00', 'purchase', 1)")
        log("✅ Inserted 4 rows")

        let countA = try await dbA.query("SELECT count(*) FROM s3_events", format: ChdbFormat.tsv)
        log("📊 Instance A count: \(countA.text ?? "?")")

        // Close A before opening B (chDB: one connection per process)
        await dbA.close()
        log("🔒 Instance A closed")

        // ──────────────────────────────────────
        // Instance B — read the same data from S3
        // ──────────────────────────────────────
        log("─── Instance B: reading same data ───")
        let dbB = try Chdb(path: "/tmp/chdb-s3-demo-b", config: .file(configURL.path))
        log("✅ Connected (Instance B)")

        // Recreate table with same schema — discovers existing S3 parts
        _ = try await dbB.query("DROP TABLE IF EXISTS s3_events")
        try await dbB.query("""
            CREATE TABLE s3_events (
                event_time DateTime,
                event_type String,
                value UInt64
            ) ENGINE = MergeTree()
            ORDER BY (event_type, event_time)
            SETTINGS storage_policy = 's3_policy'
        """)

        let rowsB = try await dbB.query("SELECT event_type, count(*) AS cnt, sum(value) AS total FROM s3_events GROUP BY event_type ORDER BY cnt DESC", format: ChdbFormat.prettyCompact)
        log("📊 Shared data from S3:\n\(rowsB.text ?? "")")

        await dbB.close()

        log("─── Summary ───")
        log("✅ Data persisted on S3 — accessible from any instance")
        if !s3.isAWS {
            log("💡 Using S3-compatible storage.")
        }
    }
}
