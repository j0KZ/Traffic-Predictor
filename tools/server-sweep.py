#!/usr/bin/env python3
"""Barrido de TomTom y Mapbox para el servidor.

Escribe en la misma tabla `sample` que el CLI de Swift, así el Mac puede
traerse la base y calibrar sin convertir nada. No toca Waze: eso sigue
viniendo del navegador.

Uso: server-sweep.py [--db calib-global.sqlite] [--routes DIR]
Claves: TRAFFICLENS_TOMTOM_KEY y TRAFFICLENS_MAPBOX_KEY en el entorno.
"""
import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

TIMEOUT = 30

SCHEMA = """
CREATE TABLE IF NOT EXISTS sample (
    id            TEXT PRIMARY KEY,
    route_id      TEXT NOT NULL,
    provider      TEXT NOT NULL,
    captured_at   INTEGER NOT NULL,
    duration_s    INTEGER NOT NULL,
    free_flow_s   INTEGER,
    distance_m    INTEGER NOT NULL,
    polyline      TEXT,
    traffic_coverage REAL
);
CREATE INDEX IF NOT EXISTS idx_sample_route_time ON sample(route_id, captured_at);
CREATE TABLE IF NOT EXISTS reference (
    id          TEXT PRIMARY KEY,
    route_id    TEXT NOT NULL,
    source      TEXT NOT NULL,
    captured_at INTEGER NOT NULL,
    duration_s  INTEGER NOT NULL,
    distance_m  INTEGER,
    note        TEXT
);
CREATE INDEX IF NOT EXISTS idx_reference_route_time ON reference(route_id, captured_at);
"""


def get(url):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        return json.loads(r.read())


def points(route):
    return [route["origin"]] + route.get("waypoints", []) + [route["destination"]]


def tomtom(route, key):
    locs = ":".join(f"{p['lat']},{p['lon']}" for p in points(route))
    q = urllib.parse.urlencode({
        "key": key,
        "traffic": "true",
        "travelMode": "car",
        "routeType": "fastest",
        "computeTravelTimeFor": "all",
        "sectionType": "traffic",
    })
    url = f"https://api.tomtom.com/routing/1/calculateRoute/{locs}/json?{q}"
    summary = get(url)["routes"][0]["summary"]
    return {
        "duration_s": int(summary["travelTimeInSeconds"]),
        "free_flow_s": summary.get("noTrafficTravelTimeInSeconds"),
        "distance_m": int(summary["lengthInMeters"]),
    }


def mapbox(route, token):
    coords = ";".join(f"{p['lon']},{p['lat']}" for p in points(route))
    q = urllib.parse.urlencode({
        "access_token": token,
        "geometries": "polyline",
        "overview": "full",
        "annotations": "congestion,duration",
        "steps": "false",
    })
    url = f"https://api.mapbox.com/directions/v5/mapbox/driving-traffic/{coords}?{q}"
    data = get(url)
    if not data.get("routes"):
        raise RuntimeError(data.get("message") or data.get("code") or "sin rutas")
    r = data["routes"][0]
    return {
        "duration_s": int(round(r["duration"])),
        # duration_typical es el equivalente al flujo libre de TomTom.
        "free_flow_s": int(round(r["duration_typical"])) if r.get("duration_typical") else None,
        "distance_m": int(round(r["distance"])),
        "polyline": r.get("geometry"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--routes", default="routes")
    ap.add_argument("--extra", default="route.json", help="ruta suelta fuera del directorio")
    args = ap.parse_args()

    tt_key = os.environ.get("TRAFFICLENS_TOMTOM_KEY")
    mb_token = os.environ.get("TRAFFICLENS_MAPBOX_KEY")
    if not tt_key or not mb_token:
        sys.exit("faltan TRAFFICLENS_TOMTOM_KEY o TRAFFICLENS_MAPBOX_KEY")

    files = sorted(Path(args.routes).glob("*.json"))
    if args.extra and Path(args.extra).exists():
        files.append(Path(args.extra))

    db = sqlite3.connect(args.db)
    db.executescript(SCHEMA)
    now = int(time.time())
    ok = failed = 0

    for f in files:
        route = json.loads(f.read_text())
        for name, fn, arg in (("tomtom", tomtom, tt_key), ("mapbox", mapbox, mb_token)):
            try:
                s = fn(route, arg)
            except Exception as e:  # una fuente caída no debe cortar el barrido
                print(f"{route['id']:28} {name:7} ERROR {e}", file=sys.stderr)
                failed += 1
                continue
            db.execute(
                "INSERT INTO sample (id, route_id, provider, captured_at, duration_s,"
                " free_flow_s, distance_m, polyline) VALUES (?,?,?,?,?,?,?,?)",
                (str(uuid.uuid4()).upper(), route["id"], name, now, s["duration_s"],
                 s.get("free_flow_s"), s["distance_m"], s.get("polyline")),
            )
            ok += 1
            print(f"{route['id']:28} {name:7} {s['duration_s']//60}m {s['distance_m']/1000:.1f}km")
    db.commit()
    print(f"\n{ok} muestras guardadas, {failed} fallidas, {len(files)} rutas @ {now}")


if __name__ == "__main__":
    main()
