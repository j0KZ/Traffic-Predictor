#!/usr/bin/env python3
"""Da de alta el corredor de un cliente y lo deja midiéndose en el servidor.

Acepta coordenadas o direcciones (geocodifica con Mapbox). Crea el JSON de
ruta con prefijo cliente- y lo sube al servidor, que lo toma en el próximo
barrido sin tocar nada más.

Ejemplos:
  tools/add-client-corridor.py --cliente "Acme" --nombre bodega-centro \\
      --desde "-33.4489,-70.6693" --hasta "-33.4172,-70.6060" --tz America/Santiago
  tools/add-client-corridor.py --cliente "Acme" --nombre planta-puerto \\
      --desde "Av. Americo Vespucio 1001, Santiago" --hasta "Valparaiso, Chile"
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HOST = "j0kz@100.64.43.101"


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def point(value, token):
    """'lat,lon' tal cual, o una dirección que se geocodifica."""
    if re.fullmatch(r"\s*-?\d+\.?\d*\s*,\s*-?\d+\.?\d*\s*", value):
        lat, lon = (float(x) for x in value.split(","))
        return {"lat": lat, "lon": lon}
    q = urllib.parse.quote(value)
    url = (f"https://api.mapbox.com/geocoding/v5/mapbox.places/{q}.json"
           f"?access_token={token}&limit=1")
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())
    if not data.get("features"):
        sys.exit(f"no se pudo geocodificar: {value}")
    lon, lat = data["features"][0]["center"]
    print(f"  {value} -> {lat:.4f},{lon:.4f}  ({data['features'][0]['place_name']})")
    return {"lat": lat, "lon": lon}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cliente", required=True)
    ap.add_argument("--nombre", required=True, help="nombre corto del corredor")
    ap.add_argument("--desde", required=True, help="lat,lon o dirección")
    ap.add_argument("--hasta", required=True, help="lat,lon o dirección")
    ap.add_argument("--tz", default="America/Santiago")
    ap.add_argument("--no-subir", action="store_true", help="no copiar al servidor")
    a = ap.parse_args()

    token = os.environ.get("TRAFFICLENS_MAPBOX_KEY")
    if not token:
        sys.exit("falta TRAFFICLENS_MAPBOX_KEY (set -a && . ./.env && set +a)")

    root = Path(__file__).resolve().parent.parent
    rid = f"cliente-{slug(a.cliente)}-{slug(a.nombre)}"
    route = {
        "id": rid,
        "label": f"{a.nombre} ({a.cliente})",
        "origin": point(a.desde, token),
        "destination": point(a.hasta, token),
        "waypoints": [],
        "notes": f"Corredor de cliente: {a.cliente}. Medición contratada.",
        "timeZone": a.tz,
    }
    path = root / "routes" / f"{rid}.json"
    path.write_text(json.dumps(route, indent=2, ensure_ascii=False) + "\n")
    print(f"creado {path.relative_to(root)}")

    if not a.no_subir:
        subprocess.run(["rsync", "-a", str(path), f"{HOST}:trafficlens-sweep/routes/"], check=True)
        print(f"subido al servidor; entra en el próximo barrido (máx. 30 min)")


if __name__ == "__main__":
    main()
