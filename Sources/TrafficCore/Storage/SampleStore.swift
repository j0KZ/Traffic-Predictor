import Foundation
import GRDB

/// SQLite via GRDB. Las fallas se guardan igual que las muestras: si un
/// proveedor falla el 40% de las rondas, su "consenso" con otro no vale nada.
public actor SampleStore {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrate(dbQueue)
    }

    public static func inMemory() throws -> SampleStore {
        try SampleStore(path: ":memory:")
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sample (
                    id            TEXT PRIMARY KEY,
                    route_id      TEXT NOT NULL,
                    provider      TEXT NOT NULL,
                    captured_at   INTEGER NOT NULL,
                    duration_s    INTEGER NOT NULL,
                    free_flow_s   INTEGER,
                    distance_m    INTEGER NOT NULL,
                    polyline      TEXT
                );
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_sample_route_time
                    ON sample(route_id, captured_at);
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS incident (
                    id            TEXT NOT NULL,
                    sample_id     TEXT NOT NULL REFERENCES sample(id) ON DELETE CASCADE,
                    category      TEXT NOT NULL,
                    description   TEXT,
                    lat REAL, lon REAL,
                    start_time    INTEGER,
                    end_time      INTEGER,
                    delay_s       INTEGER,
                    severity      INTEGER,
                    route_ratio   REAL,
                    PRIMARY KEY (id, sample_id)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS failure (
                    route_id    TEXT NOT NULL,
                    provider    TEXT NOT NULL,
                    occurred_at INTEGER NOT NULL,
                    reason      TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2-traffic-coverage") { db in
            try db.execute(sql: "ALTER TABLE sample ADD COLUMN traffic_coverage REAL;")
        }
        try migrator.migrate(queue)
    }

    public func persist(_ round: SampleRound, routeID: String) async throws {
        try await dbQueue.write { db in
            for sample in round.samples.values {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO sample
                    (id, route_id, provider, captured_at, duration_s, free_flow_s,
                     distance_m, polyline, traffic_coverage)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, arguments: [
                        sample.id.uuidString, routeID, sample.provider.rawValue,
                        Int(sample.capturedAt.timeIntervalSince1970),
                        sample.durationSeconds, sample.freeFlowSeconds,
                        sample.distanceMeters, sample.polyline, sample.trafficCoverage,
                    ])

                for incident in sample.incidents {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO incident
                        (id, sample_id, category, description, lat, lon,
                         start_time, end_time, delay_s, severity, route_ratio)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """, arguments: [
                            incident.id, sample.id.uuidString, incident.category.rawValue,
                            incident.description, incident.location?.lat, incident.location?.lon,
                            incident.startTime.map { Int($0.timeIntervalSince1970) },
                            incident.endTime.map { Int($0.timeIntervalSince1970) },
                            incident.delaySeconds, incident.severity, incident.routeRatio,
                        ])
                }
            }

            for (provider, reason) in round.failures {
                try db.execute(sql: """
                    INSERT INTO failure (route_id, provider, occurred_at, reason)
                    VALUES (?, ?, ?, ?);
                    """, arguments: [
                        routeID, provider.rawValue,
                        Int(round.capturedAt.timeIntervalSince1970), reason,
                    ])
            }
        }
    }

    /// Serie de una ruta en un rango, ordenada por tiempo. Usa el índice.
    public func samples(routeID: String, from: Date, to: Date) async throws -> [ETASample] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM sample
                WHERE route_id = ? AND captured_at BETWEEN ? AND ?
                ORDER BY captured_at;
                """, arguments: [routeID, Int(from.timeIntervalSince1970), Int(to.timeIntervalSince1970)])

            return try rows.map { row in
                let idString: String = row["id"]
                let providerString: String = row["provider"]
                guard let uuid = UUID(uuidString: idString),
                      let provider = ProviderID(rawValue: providerString) else {
                    throw ProviderError.decoding("fila de sample corrupta: \(idString)")
                }
                let incidents = try Self.incidents(db, sampleID: idString)
                return ETASample(
                    id: uuid,
                    provider: provider,
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(row["captured_at"] as Int)),
                    durationSeconds: row["duration_s"],
                    freeFlowSeconds: row["free_flow_s"],
                    distanceMeters: row["distance_m"],
                    polyline: row["polyline"],
                    incidents: incidents,
                    trafficCoverage: row["traffic_coverage"]
                )
            }
        }
    }

    private static func incidents(_ db: Database, sampleID: String) throws -> [TrafficIncident] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM incident WHERE sample_id = ?;", arguments: [sampleID])
        return rows.map { row in
            let lat: Double? = row["lat"]
            let lon: Double? = row["lon"]
            let location: Coordinate? = (lat != nil && lon != nil) ? Coordinate(lat: lat!, lon: lon!) : nil
            let start: Int? = row["start_time"]
            let end: Int? = row["end_time"]
            return TrafficIncident(
                id: row["id"],
                category: IncidentCategory(rawValue: row["category"]) ?? .unknown,
                description: row["description"],
                location: location,
                startTime: start.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                endTime: end.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                delaySeconds: row["delay_s"],
                severity: row["severity"],
                routeRatio: row["route_ratio"]
            )
        }
    }

    public func failureCount(routeID: String, provider: ProviderID) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM failure WHERE route_id = ? AND provider = ?;",
                             arguments: [routeID, provider.rawValue]) ?? 0
        }
    }

    public func incidentCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM incident;") ?? 0
        }
    }

    public func deleteSample(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sample WHERE id = ?;", arguments: [id.uuidString])
        }
    }
}

extension SampleStore {
    /// Expone el plan de la consulta por rango para verificar que usa el índice.
    func queryPlan() async throws -> String {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM sample
                WHERE route_id = ? AND captured_at BETWEEN ? AND ?
                ORDER BY captured_at;
                """, arguments: ["r5n", 0, 1])
            return rows.map { $0.description }.joined(separator: " | ")
        }
    }
}
