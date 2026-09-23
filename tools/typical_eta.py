"""Predicción para una hora dada, que es la que usa un TMS al prometer.

TomTom y Mapbox aceptan pedir el tiempo de viaje para un instante concreto,
pasado o futuro, y responden con su perfil de tráfico típico para ese día y
esa hora. No es la predicción en vivo: es la que habrías tenido al prometer
una ventana con anticipación, que para vender es lo pertinente.

Se guarda con nombre de proveedor propio ('tomtom-tipico') para no mezclarla
con la serie en vivo.
"""
import json
import os
import urllib.parse
import urllib.request
from datetime import datetime

SUFIJO = "-tipico"


def _get(url):
    # Sin User-Agent, TomTom corta la respuesta a medias (IncompleteRead).
    req = urllib.request.Request(url, headers={"User-Agent": "ETACheck/1.0",
                                              "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def tomtom(origin, destination, when, key):
    loc = f"{origin['lat']},{origin['lon']}:{destination['lat']},{destination['lon']}"
    q = urllib.parse.urlencode({"key": key, "traffic": "true",
                                # Solo el resumen: la respuesta completa trae
                                # la geometría entera y no la necesitamos.
                                "routeRepresentation": "summaryOnly",
                                "departAt": when.strftime("%Y-%m-%dT%H:%M:%S")})
    s = _get(f"https://api.tomtom.com/routing/1/calculateRoute/{loc}/json?{q}")
    s = s["routes"][0]["summary"]
    return int(s["travelTimeInSeconds"]), int(s["lengthInMeters"])


def mapbox(origin, destination, when, token):
    coords = f"{origin['lon']},{origin['lat']};{destination['lon']},{destination['lat']}"
    q = urllib.parse.urlencode({"access_token": token, "overview": "false",
                                "depart_at": when.strftime("%Y-%m-%dT%H:%M")})
    d = _get(f"https://api.mapbox.com/directions/v5/mapbox/driving-traffic/{coords}?{q}")
    if not d.get("routes"):
        raise RuntimeError(f"mapbox sin ruta: {d.get('code')}")
    r = d["routes"][0]
    return int(round(r["duration"])), int(round(r["distance"]))


def predict(route, when):
    """{proveedor: (segundos, metros)} para ese instante. Salta el que falle."""
    out = {}
    for nombre, fn, env in (("tomtom", tomtom, "TRAFFICLENS_TOMTOM_KEY"),
                            ("mapbox", mapbox, "TRAFFICLENS_MAPBOX_KEY")):
        key = os.environ.get(env)
        if not key:
            continue
        try:
            out[nombre + SUFIJO] = fn(route["origin"], route["destination"], when, key)
        except Exception as e:                      # una falla no bota la carga
            print(f"    {nombre}: {e}")
    return out


def store(db, route_id, at, preds):
    """Guarda como muestras, para que el emparejamiento las tome igual."""
    for provider, (dur, dist) in preds.items():
        db.execute("""
            INSERT OR REPLACE INTO sample
                (id, route_id, provider, captured_at, duration_s, distance_m)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (f"{provider}-{route_id}-{at}", route_id, provider, at, dur, dist))
