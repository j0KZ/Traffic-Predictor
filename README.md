# TrafficLens

Comparador multi-fuente de ETA en vivo, calibrado contra Waze.

Fuentes activas (gratis, sin tarjeta): **TomTom** y **Mapbox** (driving-traffic).
HERE y Google Routes quedan implementados pero fuera: exigen tarjeta/billing.
Ruta principal: Maitencillo a Las Condes via Ruta 5 Norte (`route.json`).

## Setup

    cp .env.example .env    # rellenar TRAFFICLENS_TOMTOM_KEY y TRAFFICLENS_MAPBOX_KEY
    set -a && source .env && set +a
    swift build
    swift test

Keys gratis: developer.tomtom.com y account.mapbox.com.

## Uso

    # Muestreo de una ruta (tabla por ronda, incidentes, recuperación)
    swift run trafficlens-cli sample --route route.json --rounds 3 --interval 180

    # Barrido de muchas rutas en paralelo (sin incidentes, ahorra cuota)
    swift run trafficlens-cli sweep --db calib.sqlite --routes routes/*.json route.json

    # Registrar una lectura de referencia (p. ej. Waze web)
    swift run trafficlens-cli reference --route route.json --db calib.sqlite --source waze --eta 2h07m --km 160

    # Informe de calibración: sesgo por franja y ruta + evaluación honesta
    swift run trafficlens-cli calibrate --db calib.sqlite --routes routes/*.json route.json

    # App macOS
    swift run TrafficLensApp

## Lo aprendido calibrando (63 pares, 17 ciudades)

- El sesgo de cada fuente es **propio de cada ruta**; no se traslada entre ciudades.
- Ruta nueva sin lecturas: usar Mapbox crudo (~7% de error vs Waze).
- Con 1 lectura de Waze por ruta y franja el error baja a ~3%; con 2, a ~2%.
- TomTom se dispara en hora punta (hasta x2); pesa poco sin historia propia.
- En Chile el baseline de 1h45 no lo confirma nadie: Waze da ~2h07 sin tráfico.

## Documentos

- docs/TRAFFIC-COMPARATOR-SPEC.md: arquitectura y contratos de API
- docs/CLAUDE-CODE-PROMPT.md: prompts por fase
