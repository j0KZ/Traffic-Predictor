#!/usr/bin/env python3
"""Retención: convierte muestras en derivados y borra las crudas.

Mapbox prohíbe almacenar sus resultados y TomTom prohíbe cachearlos más
allá de sus cabeceras. Un tiempo de viaje devuelto por ellos es contenido
suyo; el cociente log(referencia/muestra) es un coeficiente nuestro,
calculado a partir de una observación que ya pasó.

Antes de borrar, cada par muestra-referencia se convierte en ese
coeficiente, que es lo único que la calibración necesita. Después la
muestra cruda se elimina.

Uso: tools/prune-raw.py [--db calib-global.sqlite] [--days 30] [--dry-run]
"""
import argparse
import math
import sqlite3
import time

MAX_PAIRING_GAP = 300      # igual que Calibrator.maxPairingGap
MAX_DISTANCE_GAP = 0.06    # igual que Calibrator.maxDistanceGap

SCHEMA = """
CREATE TABLE IF NOT EXISTS derived_pair (
    id           TEXT PRIMARY KEY,
    route_id     TEXT NOT NULL,
    provider     TEXT NOT NULL,
    captured_at  INTEGER NOT NULL,
    log_ratio    REAL NOT NULL,   -- log(referencia / muestra)
    rel_error    REAL NOT NULL    -- |muestra - referencia| / referencia
);
CREATE INDEX IF NOT EXISTS idx_derived_route ON derived_pair(route_id, captured_at);
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    db = sqlite3.connect(a.db)
    db.executescript(SCHEMA)
    cutoff = int(time.time()) - a.days * 86400

    # Solo las referencias viejas: las recientes siguen emparejándose crudas.
    refs = db.execute(
        "SELECT id, route_id, captured_at, duration_s, distance_m FROM reference WHERE captured_at < ?",
        (cutoff,)).fetchall()

    nuevos = 0
    for rid, route, at, ref_s, ref_m in refs:
        for provider in ("tomtom", "mapbox"):
            row = db.execute(
                "SELECT duration_s, distance_m, abs(captured_at - ?) AS d FROM sample "
                "WHERE route_id = ? AND provider = ? ORDER BY d LIMIT 1",
                (at, route, provider)).fetchone()
            if not row or row[2] > MAX_PAIRING_GAP:
                continue
            if ref_m and abs(row[1] - ref_m) / ref_m > MAX_DISTANCE_GAP:
                continue
            pid = f"{rid}:{provider}"
            if db.execute("SELECT 1 FROM derived_pair WHERE id = ?", (pid,)).fetchone():
                continue
            if not a.dry_run:
                db.execute(
                    "INSERT INTO derived_pair (id, route_id, provider, captured_at, log_ratio, rel_error)"
                    " VALUES (?,?,?,?,?,?)",
                    (pid, route, provider, at,
                     math.log(max(ref_s, 1) / max(row[0], 1)),
                     abs(row[0] - ref_s) / max(ref_s, 1)))
            nuevos += 1

    viejas = db.execute("SELECT count(*) FROM sample WHERE captured_at < ?", (cutoff,)).fetchone()[0]
    if not a.dry_run:
        db.execute("DELETE FROM sample WHERE captured_at < ?", (cutoff,))
        db.commit()
        db.execute("VACUUM")

    verbo = "se convertirían" if a.dry_run else "convertidos"
    print(f"{nuevos} pares {verbo} en derivados; {viejas} muestras crudas "
          f"{'se borrarían' if a.dry_run else 'borradas'} (>{a.days} días)")
    print(f"derivados totales: {db.execute('SELECT count(*) FROM derived_pair').fetchone()[0]}")


if __name__ == "__main__":
    main()
