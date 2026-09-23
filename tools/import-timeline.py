#!/usr/bin/env python3
"""Convierte tus viajes de Google Maps Timeline en verdad de terreno.

Cada viaje en auto que ya hiciste tiene hora de salida, duración y distancia:
eso es exactamente lo que necesitamos y no exige conducir de nuevo. Para
compararlo, le pedimos a cada proveedor su predicción para ese mismo instante
(ver typical_eta.py), que es la que habrías tenido al prometer una ventana.

Acepta los dos formatos de exportación: el de Google Takeout
(Semantic Location History, 'timelineObjects') y el del teléfono
('semanticSegments' o una lista suelta).

Uso:
  set -a && source .env && set +a
  tools/import-timeline.py --export ~/Downloads/Timeline.json --dry-run
  tools/import-timeline.py --export ~/Downloads/Timeline.json --desde 2026-06-01
"""
import argparse
import json
import math
import os
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typical_eta

EN_AUTO = {"IN_PASSENGER_VEHICLE", "DRIVING", "IN_VEHICLE", "MOTORIZED"}
MIN_SEGUNDOS = 240          # menos de 4 minutos no dice nada del tráfico
MAX_SEGUNDOS = 6 * 3600


def haversine_km(a_lat, a_lon, b_lat, b_lon):
    R = 6371.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def punto(valor):
    """Las exportaciones traen el punto en tres formatos distintos."""
    if valor is None:
        return None
    if isinstance(valor, dict):
        if "latitudeE7" in valor:
            return valor["latitudeE7"] / 1e7, valor["longitudeE7"] / 1e7
        for k in ("latLng", "point", "location"):
            if k in valor:
                return punto(valor[k])
        return None
    m = re.findall(r"-?\d+\.\d+", str(valor))
    return (float(m[0]), float(m[1])) if len(m) >= 2 else None


def instante(valor):
    if not valor:
        return None
    t = str(valor).replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(t)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def segmentos(export_path):
    """Viajes en auto, de cualquiera de los formatos de exportación."""
    data = json.loads(Path(export_path).read_text())
    crudos = []
    if isinstance(data, list):
        crudos = data
    else:
        for clave in ("semanticSegments", "timelineObjects", "timelineSegments"):
            if clave in data:
                crudos = data[clave]
                break
    for item in crudos:
        seg = item.get("activitySegment") or item.get("activity") or item
        tipo = (seg.get("activityType")
                or (seg.get("topCandidate") or {}).get("type")
                or seg.get("type") or "")
        if str(tipo).upper().replace(" ", "_") not in EN_AUTO:
            continue
        inicio = instante(item.get("startTime") or seg.get("startTime")
                          or (seg.get("duration") or {}).get("startTimestamp"))
        fin = instante(item.get("endTime") or seg.get("endTime")
                       or (seg.get("duration") or {}).get("endTimestamp"))
        desde = punto(seg.get("start") or seg.get("startLocation"))
        hasta = punto(seg.get("end") or seg.get("endLocation"))
        if not (inicio and fin and desde and hasta):
            continue
        dur = int((fin - inicio).total_seconds())
        if not MIN_SEGUNDOS <= dur <= MAX_SEGUNDOS:
            continue
        metros = seg.get("distanceMeters") or seg.get("distance")
        yield {"inicio": inicio, "dur": dur, "desde": desde, "hasta": hasta,
               "metros": int(float(metros)) if metros else None}


def rutas(routes_dir, extra):
    out = {}
    files = list(Path(routes_dir).glob("*.json"))
    if Path(extra).exists():
        files.append(Path(extra))
    for f in files:
        r = json.loads(f.read_text())
        out[r["id"]] = r
    return out


def emparejar(seg, catalogo, tolerancia_km):
    """La ruta cuyo origen Y destino coinciden con los del viaje."""
    mejor, mejor_d = None, None
    for rid, r in catalogo.items():
        d1 = haversine_km(seg["desde"][0], seg["desde"][1],
                          r["origin"]["lat"], r["origin"]["lon"])
        d2 = haversine_km(seg["hasta"][0], seg["hasta"][1],
                          r["destination"]["lat"], r["destination"]["lon"])
        if d1 <= tolerancia_km and d2 <= tolerancia_km and (mejor_d is None or d1 + d2 < mejor_d):
            mejor, mejor_d = rid, d1 + d2
    return mejor


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", required=True, help="JSON de Timeline o de Takeout")
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--routes", default="routes")
    ap.add_argument("--extra", default="route.json")
    ap.add_argument("--km", type=float, default=3.0, help="tolerancia de coincidencia")
    ap.add_argument("--desde", help="ignora viajes anteriores a esta fecha (YYYY-MM-DD)")
    ap.add_argument("--max", type=int, default=150, help="tope de viajes a cargar")
    ap.add_argument("--dry-run", action="store_true", help="no consulta ni escribe")
    a = ap.parse_args()

    catalogo = rutas(a.routes, a.extra)
    corte = instante(a.desde + "T00:00:00+00:00") if a.desde else None
    db = sqlite3.connect(a.db)

    hallados = list(segmentos(a.export))
    sin_ruta, cargados = Counter(), 0
    print(f"{len(hallados)} viajes en auto en la exportación\n")

    for seg in hallados:
        if corte and seg["inicio"] < corte:
            continue
        if cargados >= a.max:
            print(f"\ntope de {a.max} viajes alcanzado")
            break
        rid = emparejar(seg, catalogo, a.km)
        if not rid:
            # Redondear a centésimas de grado agrupa los pares que se repiten.
            sin_ruta[(round(seg["desde"][0], 2), round(seg["desde"][1], 2),
                      round(seg["hasta"][0], 2), round(seg["hasta"][1], 2))] += 1
            continue

        at = int(seg["inicio"].timestamp())
        local = seg["inicio"].astimezone().strftime("%d-%m %H:%M")
        km = f"{seg['metros'] / 1000:.1f} km" if seg["metros"] else "sin distancia"
        print(f"{rid:<28} {local}  {seg['dur'] // 60:>3} min  {km}")
        if a.dry_run:
            cargados += 1
            continue

        db.execute("""
            INSERT OR REPLACE INTO reference
                (id, route_id, source, captured_at, duration_s, distance_m, note)
            VALUES (?, ?, 'real', ?, ?, ?, 'Google Maps Timeline')
        """, (f"real-{rid}-{at}", rid, at, seg["dur"], seg["metros"]))

        preds = typical_eta.predict(catalogo[rid], seg["inicio"])
        typical_eta.store(db, rid, at, preds)
        for prov, (dur, _) in sorted(preds.items()):
            err = (dur - seg["dur"]) / seg["dur"]
            print(f"    {prov:<16} predijo {dur // 60:>3} min   "
                  f"error {abs(err) * 100:5.1f}%  "
                  f"{'optimista' if err < 0 else 'pesimista'}")
        db.commit()
        cargados += 1

    verbo = "detectado" if a.dry_run else "cargado"
    print(f"\n{cargados} viaje{'' if cargados == 1 else 's'} "
          f"{verbo}{'' if cargados == 1 else 's'}.")
    if sin_ruta:
        print(f"\n{sum(sin_ruta.values())} viajes sin corredor dado de alta. "
              f"Los pares que más se repiten:")
        for (o_lat, o_lon, d_lat, d_lon), n in sin_ruta.most_common(6):
            print(f"  {n:>3} viaje{'' if n == 1 else 's'}  "
                  f"{o_lat},{o_lon} -> {d_lat},{d_lon}")
        print("Si alguno es tuyo de todos los días, vale la pena darlo de alta:")
        print("  tools/add-client-corridor.py --cliente propio --nombre <nombre> "
              "--desde 'lat,lon' --hasta 'lat,lon' --tz America/Santiago")


if __name__ == "__main__":
    main()
