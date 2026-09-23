#!/usr/bin/env python3
"""Mide el error real de los proveedores contra viajes que ocurrieron.

Chicago publica cada viaje de taxi: hora de inicio, duración en segundos,
millas y los centroides de origen y destino. Son viajes anonimizados, sin
persona detrás, y son la única cosa que teníamos faltando: tiempo real de
viaje contra el reloj, no contra otra app.

Para cada viaje le pedimos a TomTom y a Mapbox su predicción para ese mismo
instante (departAt) y comparamos. Toma los pares origen-destino que más se
repiten, para que después se pueda calibrar por corredor y validar hacia
adelante: entrenar con los viajes viejos y predecir el siguiente.

Dos límites que hay que decir al publicar esto:
  - Chicago redondea la hora de inicio al cuarto de hora, así que la
    predicción se pide con hasta 7 minutos de desfase.
  - El origen y el destino son centroides de sector censal, no direcciones,
    así que el trayecto predicho no es exactamente el que hizo el taxi. Por
    eso se descartan los pares donde la distancia no calza.

Uso:
  set -a && source .env && set +a
  tools/chicago-truth.py --pares 8 --por-par 25
"""
import argparse
import json
import os
import sqlite3
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime
from statistics import median
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typical_eta

API = "https://data.cityofchicago.org/resource/ajtu-isnz.json"
TZ = ZoneInfo("America/Chicago")
ESQUEMA = """
CREATE TABLE IF NOT EXISTS reference (
    id TEXT PRIMARY KEY, route_id TEXT NOT NULL, source TEXT NOT NULL,
    captured_at INTEGER NOT NULL, duration_s INTEGER NOT NULL,
    distance_m INTEGER, note TEXT);
CREATE TABLE IF NOT EXISTS sample (
    id TEXT PRIMARY KEY, route_id TEXT NOT NULL, provider TEXT NOT NULL,
    captured_at INTEGER NOT NULL, duration_s INTEGER NOT NULL,
    free_flow_s INTEGER, distance_m INTEGER, polyline TEXT, traffic_coverage REAL);
"""
FRANJAS = [("madrugada", range(0, 6)), ("punta mañana", range(6, 10)),
           ("mediodía", range(10, 16)), ("punta tarde", range(16, 20)),
           ("noche", range(20, 24))]


def soql(intentos=3, **params):
    """Una consulta, con reintento: bajar mucho de una vez se corta seguido."""
    url = API + "?" + urllib.parse.urlencode({f"${k}": v for k, v in params.items()})
    req = urllib.request.Request(url, headers={"User-Agent": "ETACheck/1.0"})
    for intento in range(1, intentos + 1):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read())
        except Exception as e:
            if intento == intentos:
                raise
            print(f"    reintento {intento}: {type(e).__name__}")


CAMPOS = ("trip_start_timestamp,trip_seconds,trip_miles,"
          "pickup_centroid_latitude,pickup_centroid_longitude,"
          "dropoff_centroid_latitude,dropoff_centroid_longitude")
# Los viajes cortos son inservibles como verdad: Chicago redondea la hora de
# inicio al cuarto de hora y el taxímetro incluye la maniobra de recogida, así
# que en un viaje de 15 minutos el ruido se come la señal. Ajustable.
MIN_S, MAX_S = 420, 5400
MIN_MI, MAX_MI = 2, 40


def descargar(desde, hasta, limite, min_s=MIN_S, min_mi=MIN_MI):
    """Una sola consulta y se filtra acá.

    Los filtros numéricos dentro de SoQL sobre estas columnas devuelven casi
    nada —vienen como texto—, y agrupar en el servidor agota el tiempo de
    espera. Bajar el bloque y trabajarlo en memoria es más rápido y más claro.
    """
    where = (f"trip_start_timestamp between '{desde}' and '{hasta}' "
             "AND pickup_centroid_latitude IS NOT NULL "
             "AND dropoff_centroid_latitude IS NOT NULL")
    filas, pagina = [], 2500
    for offset in range(0, limite, pagina):
        bloque = soql(select=CAMPOS, where=where, limit=pagina, offset=offset,
                      order="trip_start_timestamp")
        filas += bloque
        print(f"  {len(filas)} filas...")
        if len(bloque) < pagina:
            break
    viajes = []
    for f in filas:
        try:
            seg, mi = int(f["trip_seconds"]), float(f["trip_miles"])
            o = (round(float(f["pickup_centroid_latitude"]), 4),
                 round(float(f["pickup_centroid_longitude"]), 4))
            d = (round(float(f["dropoff_centroid_latitude"]), 4),
                 round(float(f["dropoff_centroid_longitude"]), 4))
        except (KeyError, TypeError, ValueError):
            continue
        if not (min_s <= seg <= MAX_S and min_mi <= mi <= MAX_MI) or o == d:
            continue
        viajes.append({"inicio": f["trip_start_timestamp"], "seg": seg,
                       "millas": mi, "o": o, "d": d})
    return viajes


def agrupar(viajes, cuantos, por_par):
    """Los pares más transitados, con sus viajes repartidos entre horas."""
    por_par_dict = defaultdict(list)
    for v in viajes:
        por_par_dict[(v["o"], v["d"])].append(v)
    pares = sorted(por_par_dict.items(), key=lambda kv: -len(kv[1]))[:cuantos]
    salida = []
    for (o, d), vs in pares:
        # Repartir entre horas distintas: veinte viajes de las 8 AM enseñan
        # menos que cinco de cuatro horas distintas.
        vs.sort(key=lambda v: (v["inicio"][11:13], v["inicio"]))
        paso = max(1, len(vs) // por_par)
        salida.append((o, d, len(vs), vs[::paso][:por_par]))
    return salida


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="truth-chicago.sqlite")
    ap.add_argument("--pares", type=int, default=8)
    ap.add_argument("--por-par", type=int, default=25)
    ap.add_argument("--desde", default="2026-08-01T00:00:00")
    ap.add_argument("--hasta", default="2026-09-01T00:00:00")
    ap.add_argument("--bloque", type=int, default=20000, help="filas a bajar")
    ap.add_argument("--min-minutos", type=float, default=7,
                    help="descarta viajes más cortos; los cortos son casi solo ruido")
    ap.add_argument("--min-millas", type=float, default=2)
    ap.add_argument("--desfase-distancia", type=float, default=0.25,
                    help="máxima diferencia entre la distancia predicha y la del taxi")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    db = sqlite3.connect(a.db)
    db.executescript(ESQUEMA)

    crudos = descargar(a.desde, a.hasta, a.bloque,
                       int(a.min_minutos * 60), a.min_millas)
    pares = agrupar(crudos, a.pares, a.por_par)
    print(f"{len(crudos)} viajes utilizables entre {a.desde[:10]} y {a.hasta[:10]}; "
          f"{len(pares)} pares origen-destino, los más transitados\n")

    errores = defaultdict(list)          # proveedor -> [error relativo]
    por_franja = defaultdict(list)       # (proveedor, franja) -> [error]
    cargados = 0

    for i, (o, d, n, viajes) in enumerate(pares, 1):
        rid = f"chi-{o[0]:.4f}_{o[1]:.4f}-{d[0]:.4f}_{d[1]:.4f}"
        ruta = {"origin": {"lat": o[0], "lon": o[1]},
                "destination": {"lat": d[0], "lon": d[1]}}
        print(f"[{i}/{len(pares)}] {o[0]:.3f},{o[1]:.3f} -> {d[0]:.3f},{d[1]:.3f}  "
              f"{n} viajes en el período, tomo {len(viajes)}")
        if a.dry_run:
            continue

        for v in viajes:
            inicio = datetime.fromisoformat(v["inicio"]).replace(tzinfo=TZ)
            real = v["seg"]
            metros = int(v["millas"] * 1609.34)
            at = int(inicio.timestamp())
            db.execute("""INSERT OR REPLACE INTO reference
                (id, route_id, source, captured_at, duration_s, distance_m, note)
                VALUES (?, ?, 'real', ?, ?, ?, 'taxi Chicago')""",
                       (f"real-{rid}-{at}", rid, at, real, metros))
            preds = typical_eta.predict(ruta, inicio)
            typical_eta.store(db, rid, at, preds)
            for prov, (dur, dist) in preds.items():
                # Si el ruteo tomó un camino muy distinto al del taxi, no son
                # el mismo viaje y la comparación no significa nada.
                if abs(dist - metros) / metros > a.desfase_distancia:
                    continue
                err = (dur - real) / real
                errores[prov].append(err)
                for nombre, horas in FRANJAS:
                    if inicio.hour in horas:
                        por_franja[(prov, nombre)].append(err)
            cargados += 1
        db.commit()

    if a.dry_run or not errores:
        return

    print(f"\n{cargados} viajes reales cargados en {a.db}\n")
    print(f"{'proveedor':<16}{'n':>6}{'error medio':>14}{'sesgo':>10}")
    for prov, v in sorted(errores.items()):
        mape = sum(abs(x) for x in v) / len(v)
        sesgo = median(v)
        print(f"{prov:<16}{len(v):>6}{mape * 100:>13.1f}%{sesgo * 100:>9.1f}%")
    print("\nsesgo negativo = promete menos tiempo del que el viaje tomó\n")

    print(f"{'franja':<16}" + "".join(f"{p:>16}" for p in sorted(errores)))
    for nombre, _ in FRANJAS:
        fila = f"{nombre:<16}"
        for prov in sorted(errores):
            v = por_franja.get((prov, nombre), [])
            fila += f"{(sum(abs(x) for x in v) / len(v) * 100):>15.1f}%" if v else f"{'—':>16}"
        print(fila)


if __name__ == "__main__":
    main()
