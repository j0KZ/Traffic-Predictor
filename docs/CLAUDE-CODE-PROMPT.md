# Prompt para Claude Code

Pegar tal cual en la raíz del proyecto, con `TRAFFIC-COMPARATOR-SPEC.md` presente.

---

## Fase 1: núcleo sin UI

```
Lee TRAFFIC-COMPARATOR-SPEC.md completo antes de escribir nada.

Construye el paquete TrafficCore según las secciones 2 a 7 y 9 del spec.
Sin UI, sin MapLibre, sin dependencias de SwiftUI.

Requisitos no negociables:
- Package.swift con swift-tools-version 5.9, plataforma .macOS(.v14)
- Dependencias: GRDB.swift únicamente
- Toda la red entra por un protocolo HTTPClient inyectable. El default usa
  URLSession; los tests inyectan un stub que lee de Tests/Fixtures/
- Cada provider maneja explícitamente: 200 con cuerpo vacío, 200 sin rutas,
  400, 401, 403, 429 con Retry-After, 5xx, timeout, y JSON malformado
- Nada de try! ni force unwrap fuera de tests
- Errores tipados con ProviderError, nunca NSError genérico

Antes de implementar los providers, escribe fixtures JSON representativos para
cada uno en Tests/TrafficCoreTests/Fixtures/, incluyendo un caso feliz y al
menos tres casos borde por proveedor.

Al terminar corre `swift test` y muéstrame la salida real. Si algo falla,
arréglalo antes de decir que está listo. No me reportes éxito sin la salida
de los tests pegada.
```

## Fase 2: validación contra APIs reales

```
Crea Sources/trafficlens-cli/main.swift: un ejecutable que toma origen,
destino e intervalo por argumentos, corre SamplingEngine, imprime cada ronda
en tabla y persiste en SQLite.

Salida por ronda:
- Una fila por proveedor: ETA, delay sobre free-flow, estado (ok/error)
- Veredicto de divergencia
- Incidentes filtrados sobre la ruta, con descripción y route_ratio
- Estimación de recuperación, o la razón de por qué no se puede estimar

Luego corre esto de verdad:

swift run trafficlens-cli --route route.json --rounds 3 --interval 180

La ruta va en route.json, con waypoint en La Calera para forzar Ruta 5 Norte.
El baseline de flujo libre es 6300 segundos (1h45), dato del operador que
maneja la ruta. Si un proveedor devuelve una distancia muy distinta a las
otras dos, está ruteando por la costa: márcalo como ruta divergente y
excluyelo del cálculo de mediana en vez de promediarlo.

Las keys salen de las variables TRAFFICLENS_GOOGLE_KEY, TRAFFICLENS_TOMTOM_KEY,
TRAFFICLENS_HERE_KEY.

Pégame la salida cruda de las tres rondas. Si un proveedor falla, quiero ver
el error exacto, no un resumen. Con esa salida real, actualiza los fixtures
de los tests para que reflejen la forma verdadera de cada respuesta.
```

## Fase 3: UI

```
App SwiftUI de ventana única.

Columna izquierda: las tres ETAs como tarjetas grandes, ordenadas por valor.
Cada una con delay sobre free-flow y badge de estado. La mediana destacada.
Veredicto de divergencia debajo.

Centro: gráfico de líneas de las tres ETAs contra el tiempo, usando Swift
Charts. Eje Y en minutos. Este es el elemento principal de la pantalla.

Columna derecha: lista de incidentes ordenada por route_ratio, con categoría,
descripción, y distinción visual clara entre los que tienen fin confiable y
los que no.

Abajo: bloque de recuperación. Si no hay estimación posible, dice exactamente
por qué en lugar de mostrar un guion.

Sin animaciones decorativas. Esto es un instrumento de medición.
```

## Fase 4: mapa offline

```
Sección 8 del spec. MapLibre Native por SPM, handler para pmtiles://, style
JSON local. Ruta coloreada por congestión, marcadores de incidentes.

Verifica que la app arranca sin red y muestra el mapa base. Ese es el criterio
de aceptación del offline.
```

---

## Orden de los commits

```
feat(core): modelos y protocolo de proveedor
feat(core): provider Google Routes con manejo de errores
feat(core): provider TomTom (routing + incidents)
feat(core): provider HERE (routing v8 + traffic v7 + flexible polyline)
feat(core): filtrado de incidentes sobre polyline
feat(core): motor de muestreo con aislamiento de fallas
feat(core): analizador de divergencia
feat(core): estimador de recuperación
feat(core): persistencia SQLite
feat(cli): ejecutable de validación
test(core): fixtures reales capturados de las tres APIs
feat(ui): ventana principal
feat(map): mapa base offline con PMTiles
```

## Criterio de terminado por fase

No avanzar a la siguiente sin esto:

- **F1:** `swift test` pasa, salida pegada. Cobertura de los casos borde
  listados en la sección 10 del spec.
- **F2:** tres rondas reales ejecutadas, salida cruda pegada, fixtures
  actualizados con la forma verdadera de las respuestas.
- **F3:** app compila y corre, captura de pantalla.
- **F4:** app arranca con la red apagada y el mapa se dibuja.
