# TrafficLens: comparador multi-fuente de ETA con mapa offline

App macOS (SwiftUI). Compara ETA en vivo de tres proveedores sobre una ruta fija,
registra la serie temporal, muestra incidentes con causa, y dibuja todo sobre un
mapa base descargado (PMTiles/MapLibre).

Ruta de prueba: Maitencillo (-32.6558, -71.4390) → Las Condes (-33.4089, -70.5680)
Vía **Ruta 5 Norte**, forzada con waypoint intermedio en La Calera (-32.7870, -71.1890).

Baseline conocido por el operador: **1h45 en flujo libre**. Toda ETA por sobre
ese valor es delay real, no variación de ruteo. Si un proveedor devuelve una
distancia muy distinta a las demás, está ruteando por la costa (F-30-E / Ruta 68)
y ese resultado se descarta, no se promedia.

---

## 1. Arquitectura

```
TrafficLens/
├── Package.swift
├── Sources/
│   ├── TrafficCore/                 # Sin UI, sin red en tests
│   │   ├── Models/
│   │   │   ├── RouteQuery.swift
│   │   │   ├── ETASample.swift
│   │   │   ├── TrafficIncident.swift
│   │   │   └── ProviderID.swift
│   │   ├── Providers/
│   │   │   ├── TrafficProvider.swift        # protocolo
│   │   │   ├── GoogleRoutesProvider.swift
│   │   │   ├── TomTomProvider.swift
│   │   │   └── HereProvider.swift
│   │   ├── Engine/
│   │   │   ├── SamplingEngine.swift
│   │   │   ├── DivergenceAnalyzer.swift
│   │   │   └── RecoveryEstimator.swift
│   │   ├── Storage/
│   │   │   └── SampleStore.swift            # SQLite via GRDB
│   │   └── Config/
│   │       └── CredentialStore.swift        # Keychain
│   └── TrafficLensApp/              # SwiftUI + MapLibre
├── Tests/
│   └── TrafficCoreTests/
│       ├── Fixtures/                # JSON real capturado de cada API
│       └── *Tests.swift
└── Maps/
    └── corridor.pmtiles             # generado, no versionado
```

**Regla de capas:** `TrafficCore` no importa SwiftUI ni MapLibre. Toda su
superficie de red pasa por un `URLSessionProtocol` inyectable, así los tests
corren con fixtures y sin salir a internet.

---

## 2. Modelo normalizado

Los tres proveedores devuelven formas distintas. Todo se normaliza a esto.

```swift
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case google, tomtom, here
}

public struct RouteQuery: Sendable, Equatable {
    public let origin: Coordinate
    public let destination: Coordinate
    public let waypoints: [Coordinate]  // fuerza el corredor; vacío = libre
    public let departAt: Date?          // nil = ahora
    public let freeFlowBaselineSeconds: Int?  // 6300 para Ruta 5 Norte
}

public struct Coordinate: Codable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double
}

public struct ETASample: Codable, Sendable, Identifiable {
    public let id: UUID
    public let provider: ProviderID
    public let capturedAt: Date
    public let durationSeconds: Int          // con tráfico
    public let freeFlowSeconds: Int?         // sin tráfico, si el proveedor lo da
    public let distanceMeters: Int
    public let polyline: String?             // encoded, para dibujar
    public let incidents: [TrafficIncident]

    /// Sobrecosto por tráfico. nil si no hay free-flow de referencia.
    public var delaySeconds: Int? {
        guard let ff = freeFlowSeconds else { return nil }
        return max(0, durationSeconds - ff)
    }
}

public struct TrafficIncident: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let category: IncidentCategory
    public let description: String?          // el "por qué"
    public let location: Coordinate?
    public let startTime: Date?
    public let endTime: Date?                // solo confiable en eventos programados
    public let delaySeconds: Int?
    public let severity: Int?                // 0-4 normalizado

    /// Solo los eventos programados traen fin confiable.
    public var hasReliableEnd: Bool {
        endTime != nil && category.isScheduled
    }
}

public enum IncidentCategory: String, Codable, Sendable {
    case accident, congestion, roadworks, closure, weather, hazard, event, unknown

    public var isScheduled: Bool {
        self == .roadworks || self == .closure || self == .event
    }
}
```

---

## 3. Contratos por proveedor

### 3.1 Google Routes API

```
POST https://routes.googleapis.com/directions/v2:computeRoutes
Headers:
  X-Goog-Api-Key: <key>
  X-Goog-FieldMask: routes.duration,routes.staticDuration,routes.distanceMeters,
                    routes.polyline.encodedPolyline,routes.travelAdvisory,
                    routes.legs.travelAdvisory.speedReadingIntervals
Body:
{
  "origin":      {"location":{"latLng":{"latitude":-32.6558,"longitude":-71.4390}}},
  "destination": {"location":{"latLng":{"latitude":-33.4089,"longitude":-70.5680}}},
  "intermediates": [
    {"location":{"latLng":{"latitude":-32.7870,"longitude":-71.1890}},"via":true}
  ],
  "travelMode": "DRIVE",
  "routingPreference": "TRAFFIC_AWARE_OPTIMAL",
  "departureTime": "<ISO8601 UTC, ahora + 30s>",
  "extraComputations": ["TRAFFIC_ON_POLYLINE"]
}
```

Mapeo:
- `routes[0].duration` → `durationSeconds`. Viene como string `"8340s"`, hay que parsear el sufijo.
- `routes[0].staticDuration` → `freeFlowSeconds`. Mismo formato.
- `speedReadingIntervals` → segmentos con `speed` en {NORMAL, SLOW, TRAFFIC_JAM} e índices sobre el polyline. **Esto responde "dónde", no "por qué".** Google no entrega causa.
- Google no devuelve incidentes discretos por esta vía. `incidents` queda vacío.

Notas: `departureTime` debe ser futuro o el request falla. Usa ahora + 30s.
El SKU con tráfico es Pro. Trae 5.000 eventos gratis mensuales.

### 3.2 TomTom

Dos llamadas.

```
GET https://api.tomtom.com/routing/1/calculateRoute/
    {lat0},{lon0}:{latW},{lonW}:{lat1},{lon1}/json
    ?key=<key>&traffic=true&travelMode=car&routeType=fastest
    &computeTravelTimeFor=all&sectionType=traffic
```
Mapeo:
- `routes[0].summary.travelTimeInSeconds` → `durationSeconds`
- `routes[0].summary.noTrafficTravelTimeInSeconds` → `freeFlowSeconds`
- `routes[0].summary.trafficDelayInSeconds` → cruce de validación
- `routes[0].sections` con `sectionType: "TRAFFIC"` → tramos afectados

```
GET https://api.tomtom.com/traffic/services/5/incidentDetails
    ?key=<key>&bbox={minLon},{minLat},{maxLon},{maxLat}
    &fields={incidents{type,geometry{type,coordinates},properties{iconCategory,
             magnitudeOfDelay,events{description,code},startTime,endTime,delay}}}
    &language=es-ES&categoryFilter=0,1,2,3,4,5,6,7,8,9,10,11,14
```
Mapeo:
- `events[].description` → `description`. **Esta es tu mejor fuente del "por qué".**
- `iconCategory` → `IncidentCategory` (tabla abajo)
- `magnitudeOfDelay` 0-4 → `severity`
- `endTime` presente sobre todo en `roadworks`

Tabla `iconCategory`:
```
0 unknown | 1 accident | 2 fog | 3 dangerousConditions | 4 rain | 5 ice
6 jam→congestion | 7 laneClosed→closure | 8 roadClosed→closure
9 roadWorks→roadworks | 10 wind | 11 flooding | 14 brokenDownVehicle→hazard
```

El bbox se calcula del bounding box de la ruta más un margen de 0.05 grados.
Filtra después por distancia al polyline (ver sección 5).

### 3.3 HERE

Dos llamadas.

```
GET https://router.hereapi.com/v8/routes
    ?apiKey=<key>&transportMode=car&origin={lat0},{lon0}&destination={lat1},{lon1}
    &via={latW},{lonW}!passThrough=true
    &return=summary,polyline,travelSummary&departureTime=now
```
Mapeo:
- `routes[0].sections[].summary.duration` → sumar todas las secciones
- `sections[].summary.baseDuration` → sumar → `freeFlowSeconds`
- `polyline` está en **HERE flexible polyline**, no en Google encoded. Requiere
  decodificador propio. Hay implementación de referencia en el repo oficial
  `heremaps/flexible-polyline`.

```
GET https://data.traffic.hereapi.com/v7/incidents
    ?apiKey=<key>&in=bbox:{west},{south},{east},{north}&locationReferencing=shape
```
Mapeo:
- `results[].incidentDetails.description.value` → `description`
- `.type` → categoría
- `.criticality` → `severity`
- `.startTime` / `.endTime`

---

## 4. Protocolo y motor de muestreo

```swift
public protocol TrafficProvider: Sendable {
    var id: ProviderID { get }
    func fetch(_ query: RouteQuery) async throws -> ETASample
}

public enum ProviderError: Error, Sendable {
    case missingCredential(ProviderID)
    case http(status: Int, body: String)
    case decoding(String)
    case noRoute
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
}
```

`SamplingEngine` corre las tres fuentes en paralelo con `withTaskGroup`,
**aislando fallas por proveedor**: si una revienta, las otras dos se guardan igual.

```swift
public struct SampleRound: Sendable {
    public let capturedAt: Date
    public let samples: [ProviderID: ETASample]
    public let failures: [ProviderID: String]
}

public struct SamplingCadence: Sendable {
    public var stableInterval: TimeInterval   = 300   // ETA quieta
    public var activeInterval: TimeInterval   = 120   // ETA moviéndose
    public var movementThreshold: TimeInterval = 180  // 3 min entre rondas
    public var adaptive: Bool = true                  // false = siempre 300s
}

public actor SamplingEngine {
    private let providers: [any TrafficProvider]
    private let store: SampleStore
    private var cadence: SamplingCadence
    private var lastMedian: Int?
    private var task: Task<Void, Never>?

    /// Decide el intervalo hasta la próxima ronda.
    /// Compara la mediana de esta ronda contra la anterior.
    func nextInterval(after round: SampleRound) -> TimeInterval {
        guard cadence.adaptive else { return cadence.stableInterval }

        let durations = round.samples.values.map(\.durationSeconds).sorted()
        guard !durations.isEmpty else {
            // Sin datos: no aceleres contra una API caída.
            return cadence.stableInterval
        }
        let median = durations[durations.count / 2]
        defer { lastMedian = median }

        guard let previous = lastMedian else {
            // Primera ronda: sin referencia, muestrea rápido para formar serie.
            return cadence.activeInterval
        }
        let delta = abs(median - previous)
        return Double(delta) >= cadence.movementThreshold
            ? cadence.activeInterval
            : cadence.stableInterval
    }

    public func runOnce(_ query: RouteQuery) async -> SampleRound {
        var samples: [ProviderID: ETASample] = [:]
        var failures: [ProviderID: String] = [:]

        await withTaskGroup(of: (ProviderID, Result<ETASample, Error>).self) { group in
            for p in providers {
                group.addTask {
                    do {
                        // timeout duro por proveedor
                        let s = try await withThrowingTaskGroup(of: ETASample.self) { tg -> ETASample in
                            tg.addTask { try await p.fetch(query) }
                            tg.addTask {
                                try await Task.sleep(for: .seconds(15))
                                throw ProviderError.transport("timeout 15s")
                            }
                            let first = try await tg.next()!
                            tg.cancelAll()
                            return first
                        }
                        return (p.id, .success(s))
                    } catch {
                        return (p.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let s): samples[id] = s
                case .failure(let e): failures[id] = String(describing: e)
                }
            }
        }

        let round = SampleRound(capturedAt: .now, samples: samples, failures: failures)
        try? await store.persist(round)
        return round
    }
}
```

**Backoff:** ante `rateLimited` o 5xx, ese proveedor salta las siguientes N rondas
con backoff exponencial (1, 2, 4, 8 rondas, tope 8). Los otros siguen normal.

---

## 5. Filtrado de incidentes sobre la ruta

El bbox trae incidentes de toda la región, no solo de tu camino. Sin filtrar,
vas a ver choques en Valparaíso que no te afectan.

Algoritmo: decodifica el polyline, submuestrea a un punto cada ~500 m, y para
cada incidente calcula la distancia mínima a esos puntos con haversine. Descarta
todo lo que quede a más de 300 m. Guarda el índice del punto más cercano, que te
da la **posición del incidente sobre la ruta** (0.0 = origen, 1.0 = destino).

Ese ratio es el dato que decide si te afecta:
- ratio < 0.33 y sales ahora → casi seguro lo enfrentas
- ratio > 0.66 y faltan 2 horas para llegar ahí → probablemente ya no exista

---

## 6. Análisis de divergencia y recuperación

### DivergenceAnalyzer

Con tres ETAs de la misma ronda:

```swift
public struct Divergence: Sendable {
    public let median: Int
    public let spreadSeconds: Int          // max - min
    public let spreadRatio: Double         // spread / median
    public let outlier: ProviderID?        // el que se aleja > 15% de la mediana
    public let verdict: Verdict
}

public enum Verdict: String, Sendable {
    case consensus       // spreadRatio < 0.08
    case minorSpread     // 0.08 - 0.20
    case majorSpread     // > 0.20, hay un outlier claro
    case insufficient    // menos de 2 fuentes vivas
}
```

Regla operativa: en `majorSpread`, **confía en la mediana, no en el mínimo.**
El modo de falla de las fuentes optimistas es asumir flujo libre donde no hay datos.

### RecoveryEstimator

Acá no se inventa. Tres caminos, en orden de preferencia:

1. **Evento programado con `endTime`** → se reporta el dato tal cual, marcado
   como fuente del proveedor. Confianza alta.
2. **Serie temporal con 4+ muestras** → regresión lineal sobre `delaySeconds`.
   Si la pendiente es negativa, proyecta cuándo cruza cero y reporta ese tiempo
   con el R² como medida de confianza. Si R² < 0.5, marca "tendencia poco clara".
3. **Menos de 4 muestras o pendiente plana/positiva** → **no estima**. Devuelve
   `.insufficient` o `.worsening`. No se muestra un número inventado.

```swift
public enum Recovery: Sendable {
    case scheduled(endsAt: Date, source: ProviderID)
    case trending(estimatedClearAt: Date, rSquared: Double)
    case unclear(reason: String)
    case worsening(slopeSecondsPerMinute: Double)
    case insufficient(samplesNeeded: Int)
}
```

Esto es la pieza que ninguna app te da y es la razón de ser del proyecto.

---

## 7. Persistencia

SQLite con GRDB.

```sql
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
CREATE INDEX IF NOT EXISTS idx_sample_route_time ON sample(route_id, captured_at);

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

CREATE TABLE IF NOT EXISTS failure (
    route_id    TEXT NOT NULL,
    provider    TEXT NOT NULL,
    occurred_at INTEGER NOT NULL,
    reason      TEXT NOT NULL
);
```

Guardar las fallas importa: si un proveedor falla el 40% de las rondas, su
"consenso" con otro no vale nada.

---

## 8. Mapa offline

```bash
brew install protomaps/tap/pmtiles

# Corredor Maitencillo-Santiago con margen
pmtiles extract \
  https://build.protomaps.com/20260901.pmtiles \
  corridor.pmtiles \
  --bbox=-71.60,-33.55,-70.45,-32.55 \
  --maxzoom=13
```

Zoom 13 alcanza para ver calles principales y ubicar incidentes. Si quieres
detalle de calle menor sube a 14, pero el archivo crece rápido.

En Swift: MapLibre Native vía SPM (`maplibre/maplibre-gl-native-distribution`).
Registra el protocolo `pmtiles://` con un handler que lee el archivo local por
rangos de bytes. El style JSON apunta a `pmtiles://corridor.pmtiles`.

Capas encima del base: polyline de la ruta coloreado por `speedReadingIntervals`
de Google, y marcadores de incidentes de TomTom/HERE.

**Esto es v2.** No bloquea nada de lo anterior.

---

## 9. Credenciales

Nunca en el código, nunca en el repo.

```swift
public struct CredentialStore {
    public static func apiKey(for provider: ProviderID) throws -> String {
        // 1. Keychain (servicio "dev.j0kz.trafficlens", cuenta = provider.rawValue)
        // 2. Fallback a variable de entorno TRAFFICLENS_<PROVIDER>_KEY
        // 3. throw ProviderError.missingCredential
    }
}
```

`.gitignore`: `*.pmtiles`, `.env`, `*.sqlite`, `Fixtures/live/`.

---

## 10. Tests obligatorios

Todos corren sin red, contra fixtures.

| Suite | Qué cubre |
|---|---|
| `GoogleParsingTests` | Parseo de `"8340s"`, `speedReadingIntervals`, respuesta sin rutas |
| `TomTomParsingTests` | Mapeo de `iconCategory`, incidente sin `endTime`, `magnitudeOfDelay` |
| `HereParsingTests` | Suma de secciones múltiples, decodificación de flexible polyline |
| `DivergenceTests` | Consenso, outlier claro, dos fuentes, una fuente, cero fuentes |
| `RecoveryTests` | Pendiente negativa con buen R², pendiente plana, empeorando, 3 muestras |
| `RouteFilterTests` | Incidente a 100 m se conserva, a 5 km se descarta, cálculo de ratio |
| `EngineTests` | Una fuente falla y las otras dos persisten igual; timeout por proveedor |
| `CadenceTests` | Primera ronda usa activeInterval; salto de 5 min acelera; deriva de 1 min mantiene stable; ronda vacía no acelera; adaptive=false siempre 300s |
| `StoreTests` | Round-trip, cascada de borrado, índice en consulta por rango |

Casos borde que **deben** estar cubiertos:
- Respuesta 200 con `routes: []` (sin ruta viable)
- `departureTime` en el pasado → 400 de Google
- Incidente con coordenadas nulas
- Polyline vacío
- Las tres fuentes caídas simultáneamente
- Reloj del sistema con drift (usar `capturedAt` del cliente, no del servidor)

---

## 11. Verificación contra la realidad

El test que importa no es unitario.

1. Corre el muestreo sobre Maitencillo → Las Condes durante 45 minutos.
2. En paralelo, anota la ETA de Waze cada 5 minutos a mano.
3. Compara: ¿alguna de las tres reproduce la curva de Waze? ¿O las tres se
   parecen a Apple?

**Si las tres coinciden entre sí y difieren de Waze de forma consistente**, el
sistema tiene el mismo punto ciego y hay que decirlo sin adornos. Ese resultado
es información valiosa, no un fracaso del proyecto.

Guarda esa sesión de 45 minutos como dataset de referencia. Es lo que te permite
calibrar cuánto creerle a cada fuente en viajes futuros.
