#!/usr/bin/env bash
# TrafficLens: bootstrap
# Uso: bash bootstrap.sh

set -euo pipefail

PROJECT="trafficlens"
ROOT="$HOME/Projects/$PROJECT"

if [ -d "$ROOT" ]; then
  echo "ERROR: $ROOT ya existe. Borra o renombra antes de continuar." >&2
  exit 1
fi

command -v swift >/dev/null 2>&1 || { echo "ERROR: swift no está en PATH. Instala Xcode Command Line Tools." >&2; exit 1; }
command -v git   >/dev/null 2>&1 || { echo "ERROR: git no está en PATH." >&2; exit 1; }

echo "Swift: $(swift --version 2>&1 | head -1)"

mkdir -p "$ROOT"
cd "$ROOT"

mkdir -p Sources/TrafficCore/{Models,Providers,Engine,Storage,Config}
mkdir -p Sources/trafficlens-cli
mkdir -p Tests/TrafficCoreTests/Fixtures/{google,tomtom,here}
mkdir -p Maps docs

cat > Package.swift <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "trafficlens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrafficCore", targets: ["TrafficCore"]),
        .executable(name: "trafficlens-cli", targets: ["trafficlens-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TrafficCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "trafficlens-cli",
            dependencies: [
                "TrafficCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TrafficCoreTests",
            dependencies: ["TrafficCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
EOF

cat > .gitignore <<'EOF'
.build/
.swiftpm/
*.xcodeproj
*.xcworkspace
DerivedData/
*.pmtiles
*.sqlite
*.sqlite-wal
*.sqlite-shm
.env
.env.*
Tests/TrafficCoreTests/Fixtures/live/
.DS_Store
EOF

cat > .env.example <<'EOF'
# Copiar a .env y rellenar. .env está en .gitignore.
# Cargar con: set -a && source .env && set +a
TRAFFICLENS_GOOGLE_KEY=
TRAFFICLENS_TOMTOM_KEY=
TRAFFICLENS_HERE_KEY=
EOF

cat > route.json <<'EOF'
{
  "id": "maitencillo-lascondes-r5n",
  "label": "Maitencillo a Las Condes via Ruta 5 Norte",
  "origin":      { "lat": -32.6558, "lon": -71.4390 },
  "destination": { "lat": -33.4089, "lon": -70.5680 },
  "waypoints": [
    { "lat": -32.7870, "lon": -71.1890, "note": "La Calera, fuerza Ruta 5 Norte" }
  ],
  "freeFlowBaselineSeconds": 6300,
  "notes": "Baseline 1h45 en flujo libre, dato del operador. Descartar rutas con distancia muy distinta: significa ruteo por la costa."
}
EOF

cat > README.md <<'EOF'
# TrafficLens

Comparador multi-fuente de ETA en vivo con mapa base offline.

Fuentes: Google Routes API, TomTom, HERE.
Ruta de referencia: Maitencillo a Las Condes via Ruta 5 Norte. Baseline 1h45.

## Setup

    cp .env.example .env    # rellenar las tres keys
    set -a && source .env && set +a
    swift build
    swift test

## Validación real

    swift run trafficlens-cli --route route.json --rounds 3 --interval 180

## Documentos

- docs/TRAFFIC-COMPARATOR-SPEC.md: arquitectura y contratos de API
- docs/CLAUDE-CODE-PROMPT.md: prompts por fase
EOF

git init -q
git add -A
git commit -qm "chore: scaffold inicial de trafficlens"

echo ""
echo "Listo: $ROOT"
echo ""
echo "Siguiente:"
echo "  1. Copia TRAFFIC-COMPARATOR-SPEC.md y CLAUDE-CODE-PROMPT.md a $ROOT/docs/"
echo "  2. cp .env.example .env  y rellena las tres keys"
echo "  3. cd $ROOT && claude"
