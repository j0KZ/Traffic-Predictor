#!/usr/bin/env python3
"""Anota un viaje real y lo compara al instante con lo que predijeron.

Un viaje real es la única verdad: hora de salida y duración efectiva. Entra
en la tabla reference con source='real', que es la misma por donde entran
las lecturas de Waze, así que la calibración lo toma sin cambiar nada más.
Manda sobre cualquier otra referencia porque no es otra predicción.

La distancia es opcional pero conviene: sin ella, un viaje que tomó otro
camino se cuenta igual y se aprende como si fuera sesgo del proveedor.

Ejemplos:
  tools/add-real-trip.py --ruta maitencillo-lascondes \\
      --salida "2026-09-22 08:15" --duracion 1:47 --distancia 148
  tools/add-real-trip.py --csv viajes.csv
  tools/add-real-trip.py --ruta santiago-centro --salida "ayer 18:30" \\
      --duracion 52m --nota "con lluvia"

CSV: ruta,salida,duracion[,distancia_km,nota] con encabezado.
"""
import argparse
import csv
import json
import math
import re
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

MAX_PAIRING_GAP = 300      # igual que Calibrator.maxPairingGap


def route_tz(route_id, routes_dir, extra):
    """La zona horaria declarada en el archivo de la ruta."""
    files = list(Path(routes_dir).glob("*.json"))
    if Path(extra).exists():
        files.append(Path(extra))
    for f in files:
        r = json.loads(f.read_text())
        if r.get("id") == route_id:
            return ZoneInfo(r.get("timeZone") or "UTC"), r.get("label", route_id)
    sys.exit(f"no existe la ruta '{route_id}'. Las que hay:\n  " +
             "\n  ".join(sorted(json.loads(f.read_text())["id"] for f in files)))


def parse_duration(text):
    """'49', '49m', '1:47', '1:12:30' -> segundos."""
    t = str(text).strip().lower().rstrip("m")
    if ":" in t:
        parts = [float(p) for p in t.split(":")]
        if len(parts) == 2:          # h:mm si la primera es chica, si no mm:ss
            a, b = parts
            return int(a * 3600 + b * 60) if a < 12 else int(a * 60 + b)
        h, m, s = parts
        return int(h * 3600 + m * 60 + s)
    return int(float(t) * 60)        # minutos a secas


def parse_when(text, tz):
    """Fecha y hora local de la ruta -> epoch. Acepta 'ayer HH:MM' y 'hoy HH:MM'."""
    t = text.strip().lower()
    hoy = datetime.now(tz).date()
    for palabra, dia in (("ayer", hoy - timedelta(days=1)), ("hoy", hoy)):
        if t.startswith(palabra):
            hora = t[len(palabra):].strip()
            t = f"{dia.isoformat()} {hora}"
            break
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%d-%m-%Y %H:%M", "%d/%m/%Y %H:%M"):
        try:
            return int(datetime.strptime(t, fmt).replace(tzinfo=tz).timestamp())
        except ValueError:
            continue
    sys.exit(f"no entiendo la fecha '{text}'. Usa 2026-09-22 08:15")


def compare(db, route_id, at, duration_s):
    """Qué predijeron los proveedores para ese mismo instante."""
    rows = db.execute("""
        SELECT provider, duration_s, distance_m, ABS(captured_at - ?) AS d
        FROM sample WHERE route_id = ? AND d <= ?
        ORDER BY provider, d
    """, (at, route_id, MAX_PAIRING_GAP)).fetchall()
    visto = {}
    for prov, pred, dist, _ in rows:
        visto.setdefault(prov, (pred, dist))
    return visto


def insert(db, route_id, at, duration_s, distance_m, note):
    rid = f"real-{route_id}-{at}"
    db.execute("""
        INSERT OR REPLACE INTO reference
            (id, route_id, source, captured_at, duration_s, distance_m, note)
        VALUES (?, ?, 'real', ?, ?, ?, ?)
    """, (rid, route_id, at, duration_s, distance_m, note))
    return rid


def one(db, route_id, salida, duracion, distancia_km, nota, routes_dir, extra):
    tz, label = route_tz(route_id, routes_dir, extra)
    at = parse_when(salida, tz)
    dur = parse_duration(duracion)
    dist = int(float(distancia_km) * 1000) if distancia_km else None

    insert(db, route_id, at, dur, dist, nota)
    local = datetime.fromtimestamp(at, tz).strftime("%Y-%m-%d %H:%M")
    print(f"\n{label}  ·  salida {local}  ·  {dur // 60} min"
          + (f"  ·  {dist / 1000:.1f} km" if dist else "  ·  sin distancia"))

    preds = compare(db, route_id, at, dur)
    if not preds:
        print("  Sin predicción a menos de 5 minutos de esa hora: queda anotado,")
        print("  pero no forma par. Solo sirve si había un barrido a esa hora.")
        return
    for prov, (pred, pdist) in sorted(preds.items()):
        err = (pred - dur) / dur
        signo = "optimista" if err < 0 else "pesimista"
        linea = (f"  {prov:<8} predijo {pred // 60:>3} min   "
                 f"error {abs(err) * 100:5.1f}%  {signo}")
        if dist and pdist:
            gap = abs(pdist - dist) / dist
            if gap > 0.06:
                linea += f"   ojo: ruteó {gap * 100:.0f}% más larga, no es el mismo viaje"
        print(linea)
    if not dist:
        print("  Sin distancia no se puede descartar que hayan ruteado otro camino.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--routes", default="routes")
    ap.add_argument("--extra", default="route.json")
    ap.add_argument("--ruta")
    ap.add_argument("--salida", help="'2026-09-22 08:15', 'hoy 18:30', 'ayer 8:00'")
    ap.add_argument("--duracion", help="minutos, o h:mm")
    ap.add_argument("--distancia", help="kilómetros recorridos")
    ap.add_argument("--nota", default=None)
    ap.add_argument("--csv", help="carga varios: ruta,salida,duracion[,distancia_km,nota]")
    a = ap.parse_args()

    db = sqlite3.connect(a.db)
    if a.csv:
        with open(a.csv, newline="") as f:
            for row in csv.DictReader(f):
                one(db, row["ruta"], row["salida"], row["duracion"],
                    row.get("distancia_km"), row.get("nota"), a.routes, a.extra)
    else:
        if not (a.ruta and a.salida and a.duracion):
            sys.exit("faltan --ruta, --salida y --duracion (o usa --csv)")
        one(db, a.ruta, a.salida, a.duracion, a.distancia, a.nota, a.routes, a.extra)
    db.commit()
    total = db.execute("SELECT COUNT(*) FROM reference WHERE source='real'").fetchone()[0]
    plural = "viaje real anotado" if total == 1 else "viajes reales anotados"
    print(f"\n{total} {plural} en total.")


if __name__ == "__main__":
    main()
