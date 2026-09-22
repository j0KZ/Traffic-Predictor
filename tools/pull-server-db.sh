#!/usr/bin/env bash
# Trae la base del servidor y la mezcla con la local.
#
# El servidor barre TomTom y Mapbox cada 30 min con el Mac apagado; las
# lecturas de Waze se toman acá. Este script junta las dos mitades.
# Las filas se identifican por id, así que correrlo dos veces no duplica.
#
# Uso: tools/pull-server-db.sh [usuario@host]

set -euo pipefail

HOST="${1:-j0kz@100.64.43.101}"
REMOTE_DB="trafficlens-sweep/calib-global.sqlite"
LOCAL_DB="calib-global.sqlite"
TMP="${TMPDIR:-/tmp}/server-calib.sqlite"

cd "$(dirname "$0")/.."

# Copia por backup() en vez de scp directo: la base puede estar a medio
# escribir si el cron dispara justo ahora. El servidor no trae el binario
# sqlite3, así que va por el módulo de Python.
ssh "$HOST" "python3 -c \"
import sqlite3
src = sqlite3.connect('$REMOTE_DB')
dst = sqlite3.connect('/tmp/calib-snapshot.sqlite')
src.backup(dst)
dst.close(); src.close()
\""
scp -q "$HOST:/tmp/calib-snapshot.sqlite" "$TMP"
ssh "$HOST" "rm -f /tmp/calib-snapshot.sqlite"

before=$(sqlite3 "$LOCAL_DB" "select count(*) from sample")

sqlite3 "$LOCAL_DB" <<EOF
ATTACH DATABASE '$TMP' AS remoto;
INSERT OR IGNORE INTO sample
    (id, route_id, provider, captured_at, duration_s, free_flow_s, distance_m, polyline)
SELECT id, route_id, provider, captured_at, duration_s, free_flow_s, distance_m, polyline
FROM remoto.sample;
INSERT OR IGNORE INTO reference
    (id, route_id, source, captured_at, duration_s, distance_m, note)
SELECT id, route_id, source, captured_at, duration_s, distance_m, note
FROM remoto.reference;
DETACH DATABASE remoto;
EOF

after=$(sqlite3 "$LOCAL_DB" "select count(*) from sample")
rm -f "$TMP"

echo "muestras: $before -> $after (+$((after - before)))"
sqlite3 "$LOCAL_DB" "select '  ultima muestra: ' || datetime(max(captured_at),'unixepoch') || ' UTC' from sample"
