# TrafficLens

Comparador multi-fuente de ETA en vivo con mapa base offline.

Fuentes: TomTom, HERE, Mapbox (driving-traffic). Google Routes queda
implementado pero fuera del set por defecto: exige billing con tarjeta.
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
