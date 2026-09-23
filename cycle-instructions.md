# Ciclo de calibración de TrafficLens

Instrucciones para el agente que corre el ciclo. Objetivo: sumar lecturas de
Waze en algunas ciudades, refrescar las cifras públicas y reportar en dos o
tres líneas en español. Nada de análisis largos: gasta tokens y no aporta.

## Qué corre solo y no hay que tocar

En el servidor (`j0kz@100.64.43.101`, `~/trafficlens-sweep/`), por crontab:

- barrido de TomTom y Mapbox cada 30 minutos (`run.sh`)
- poda de muestras crudas a los 30 días, 04:00 (`prune-raw.py`)
- agente de correo cada 15 minutos, que solo deja borradores (`mail-agent.py`)

Si las muestras suben, eso está sano. No hace falta revisarlo cada vez.

## 1. Traer lo medido

    bash tools/pull-server-db.sh

Necesita salir del sandbox (`dangerouslyDisableSandbox: true`): es ssh a la
red local. Imprime cuántas muestras entraron y la última.

## 2. Lecturas de Waze, en tandas

Waze corta si se le piden 25 ciudades de una vez. Tandas de unas 8.

    set -a && source .env && set +a && python3 tools/waze-receiver.py --db calib-global.sqlite

El receptor expone `/routes`, hace `/sweep` justo antes de cada lectura —ese
orden importa: si el barrido corre más de 5 minutos antes, el par no se forma—
y manda cada lectura a `trafficlens-cli reference`.

Después, con la extensión de `tools/waze-reader/` cargada en el navegador, leer
las ciudades de la tanda. Si una ciudad devuelve "No hay forma de conducir" en
todas, es límite de tasa: esperar y seguir con otra tanda.

Elegir ciudades donde sea hora punta en ese momento, y preferir las que tengan
una o dos lecturas: la segunda medición es la que baja el error, la tercera
casi no aporta.

## 3. Refrescar las cifras públicas

    tools/build-santiago.py
    tools/build-estudio.py     # solo si se ampliaron los viajes reales

Si las cifras se movieron, commitear `site/santiago.html` y hacer push: el
sitio se republica solo con el push. **Si el titular cambia de corredor o de
franja, avisarlo en el reporte**: el correo de venta cita esas cifras y hay que
mantenerlo igual a la tabla.

`tools/build-index.py` queda fuera hasta que TomTom y Mapbox respondan los
correos de permiso: esa página nombra proveedores.

## 4. Calibración, para el reporte

    swift run trafficlens-cli calibrate --routes routes/*.json route.json --db calib-global.sqlite

La cifra que se reporta es la de validación hacia adelante, no la de dejar una
fuera, que es optimista.

## 5. Reportar

Dos o tres líneas en español: ciudades con lecturas nuevas, error calibrado
contra Mapbox crudo, y cualquier cosa rara (una ciudad que no responde, una
lectura que contradice a las anteriores). No leer ni analizar nada más.
