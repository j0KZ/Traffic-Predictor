#!/usr/bin/env python3
"""Perfil de un corredor en minutos, para responder el mismo día.

Pedir dos semanas de medición antes de mostrar algo mata la conversación. Con
departAt se le puede preguntar a cada proveedor qué predice para cada hora de
un día típico, y eso ya dice tres cosas útiles: a qué hora el corredor se
cae, cuánto se contradicen las dos fuentes, y cuánto castiga la punta contra
la madrugada.

Lo que NO dice es el margen: eso exige viajes reales. El informe lo declara.

Uso:
  set -a && source .env && set +a
  tools/quick-profile.py --nombre "Bodega Pudahuel a Puente Alto" \\
      --desde=-33.3897,-70.79 --hasta=-33.6118,-70.5758 --tz America/Santiago

Las coordenadas van con = y sin espacio: empiezan con guión y argparse las
confundiría con otra opción. Una dirección entre comillas funciona igual.
"""
import argparse
import json
import os
import re
import statistics
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typical_eta

FRANJAS = [("Madrugada", range(0, 6)), ("Punta mañana", range(6, 10)),
           ("Mediodía", range(10, 16)), ("Punta tarde", range(16, 20)),
           ("Noche", range(20, 24))]


def punto(valor, token):
    if re.fullmatch(r"\s*-?\d+\.?\d*\s*,\s*-?\d+\.?\d*\s*", valor):
        lat, lon = (float(x) for x in valor.split(","))
        return {"lat": lat, "lon": lon}
    q = urllib.parse.quote(valor)
    url = (f"https://api.mapbox.com/geocoding/v5/mapbox.places/{q}.json"
           f"?access_token={token}&limit=1")
    with urllib.request.urlopen(url, timeout=30) as r:
        d = json.loads(r.read())
    if not d.get("features"):
        sys.exit(f"no se pudo geocodificar: {valor}")
    lon, lat = d["features"][0]["center"]
    print(f"  {valor} -> {lat:.4f},{lon:.4f}  ({d['features'][0]['place_name']})")
    return {"lat": lat, "lon": lon}


def dia_tipico(tz, dia_semana=1):
    """El próximo martes (o el día pedido) a medianoche, hora local."""
    hoy = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    return hoy + timedelta(days=(dia_semana - hoy.weekday()) % 7 or 7)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nombre", required=True)
    ap.add_argument("--desde", required=True, help="'lat,lon' o una dirección")
    ap.add_argument("--hasta", required=True)
    ap.add_argument("--tz", default="America/Santiago")
    ap.add_argument("--cliente", default="")
    ap.add_argument("--out", default="reports")
    ap.add_argument("--cada", type=int, default=1, help="horas entre consultas")
    a = ap.parse_args()

    tz = ZoneInfo(a.tz)
    token = os.environ.get("TRAFFICLENS_MAPBOX_KEY", "")
    ruta = {"origin": punto(a.desde, token), "destination": punto(a.hasta, token)}
    base = dia_tipico(tz)
    print(f"\n{a.nombre}  ·  {base:%A %d-%m}, hora local {a.tz}\n")

    filas = []
    for h in range(0, 24, a.cada):
        cuando = base.replace(hour=h)
        preds = typical_eta.predict(ruta, cuando)
        if len(preds) < 2:
            continue
        (na, (da, dista)), (nb, (db, distb)) = sorted(preds.items())
        desac = abs(da - db) / ((da + db) / 2)
        filas.append({"hora": h, "a": da, "b": db, "desac": desac,
                      "km": (dista + distb) / 2000})
        print(f"  {h:02d}:00   A {da // 60:>3} min   B {db // 60:>3} min   "
              f"desacuerdo {desac * 100:5.1f}%")

    if not filas:
        sys.exit("ningún proveedor respondió: revisa las claves")

    rapido = min(filas, key=lambda f: (f["a"] + f["b"]) / 2)
    lento = max(filas, key=lambda f: (f["a"] + f["b"]) / 2)
    castigo = ((lento["a"] + lento["b"]) / (rapido["a"] + rapido["b"]) - 1)
    peor_desac = max(filas, key=lambda f: f["desac"])

    print(f"\n  más rápido  {rapido['hora']:02d}:00  "
          f"{(rapido['a'] + rapido['b']) // 120:>3} min")
    print(f"  más lento   {lento['hora']:02d}:00  "
          f"{(lento['a'] + lento['b']) // 120:>3} min   (+{castigo * 100:.0f}%)")
    print(f"  peor desacuerdo entre fuentes: {peor_desac['desac'] * 100:.1f}% "
          f"a las {peor_desac['hora']:02d}:00")

    por_franja = []
    for nombre, horas in FRANJAS:
        v = [f for f in filas if f["hora"] in horas]
        if not v:
            continue
        por_franja.append((nombre,
                           statistics.mean((f["a"] + f["b"]) / 120 for f in v),
                           statistics.mean(f["desac"] for f in v)))

    coma = lambda x, d=1: f"{x:.{d}f}".replace(".", ",")
    tabla = "\n".join(
        f'        <tr><td>{n}</td><td class="num">{coma(m, 0)} min</td>'
        f'<td class="num {"alto" if dd >= 0.15 else "medio" if dd >= 0.08 else "bajo"}">'
        f'{coma(dd * 100)}%</td></tr>' for n, m, dd in por_franja)
    horas_tabla = "\n".join(
        f'        <tr><td>{f["hora"]:02d}:00</td><td class="num">{f["a"] // 60} min</td>'
        f'<td class="num">{f["b"] // 60} min</td>'
        f'<td class="num {"alto" if f["desac"] >= 0.15 else "medio" if f["desac"] >= 0.08 else "bajo"}">'
        f'{coma(f["desac"] * 100)}%</td></tr>' for f in filas)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    slug = re.sub(r"[^a-z0-9]+", "-", a.nombre.lower()).strip("-")
    destino = out / f"perfil-{slug}.html"
    destino.write_text(PAGE.format(
        nombre=a.nombre, cliente=a.cliente or "—", dia=f"{base:%A %d-%m-%Y}",
        km=coma(statistics.mean(f["km"] for f in filas)),
        rapido=f"{rapido['hora']:02d}:00", rapido_min=coma((rapido['a'] + rapido['b']) / 120, 0),
        lento=f"{lento['hora']:02d}:00", lento_min=coma((lento['a'] + lento['b']) / 120, 0),
        castigo=coma(castigo * 100, 0),
        desac_max=coma(peor_desac["desac"] * 100), desac_hora=f"{peor_desac['hora']:02d}:00",
        tabla=tabla, horas=horas_tabla,
        fecha=datetime.now(tz).strftime("%d-%m-%Y")))
    print(f"\n{destino}")


PAGE = """<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Perfil del corredor · {nombre}</title>
<style>
  :root {{ --bg:#fbfaf8; --surface:#fff; --text:#17171a; --muted:#67665f; --line:#e7e3db;
    --accent:#b4491f; --alto:#b5352a; --medio:#b07d1a; --bajo:#3f6f52; --radius:14px; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
    --bg:#141416; --surface:#1d1d20; --text:#ededea; --muted:#9c9a94; --line:#313137;
    --accent:#e08b62; --alto:#e8776b; --medio:#d4a955; --bajo:#82b394; }} }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text); font:16px/1.6 ui-sans-serif,
    system-ui, -apple-system, "Segoe UI", sans-serif; }}
  .wrap {{ max-width:720px; margin:0 auto; padding:40px 16px 70px; }}
  .eyebrow {{ color:var(--accent); font-size:12px; letter-spacing:.08em; text-transform:uppercase;
    font-weight:600; margin:0 0 8px; }}
  h1 {{ font-size:clamp(25px,4.6vw,34px); line-height:1.15; letter-spacing:-.02em;
    margin:0 0 10px; font-weight:640; }}
  .sub {{ color:var(--muted); margin:0 0 28px; }}
  .hero {{ background:var(--surface); border:1px solid var(--line); border-radius:var(--radius);
    padding:24px; margin-bottom:14px; }}
  .hero .big {{ font-size:clamp(34px,7vw,50px); font-weight:650; letter-spacing:-.03em;
    line-height:1; color:var(--alto); }}
  .hero p {{ margin:10px 0 0; color:var(--muted); }}
  h2 {{ font-size:20px; margin:34px 0 14px; font-weight:640; letter-spacing:-.01em; }}
  table {{ width:100%; border-collapse:collapse; font-size:15px; }}
  th {{ text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.05em;
    color:var(--muted); font-weight:600; padding:0 8px 9px; border-bottom:1px solid var(--line); }}
  td {{ padding:11px 8px; border-bottom:1px solid var(--line); }}
  td.num {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:650; }}
  .alto {{ color:var(--alto); }} .medio {{ color:var(--medio); }} .bajo {{ color:var(--bajo); }}
  .nota {{ background:var(--surface); border:1px solid var(--line); border-left:3px solid var(--accent);
    border-radius:0 var(--radius) var(--radius) 0; padding:16px 18px; margin:22px 0; }}
  .nota strong {{ color:var(--accent); }}
  footer {{ margin-top:36px; padding-top:22px; border-top:1px solid var(--line);
    color:var(--muted); font-size:13px; }}
</style></head><body><div class="wrap">

<p class="eyebrow">Perfil del corredor · {cliente}</p>
<h1>{nombre}</h1>
<p class="sub">{km} km · perfil de tráfico típico para el {dia} · dos fuentes de ruteo
   consultadas hora por hora</p>

<div class="hero">
  <div class="big">+{castigo}%</div>
  <p>más tiempo a las {lento} ({lento_min} min) que a las {rapido} ({rapido_min} min).
     Es el mismo trayecto: lo único que cambia es la hora de salida.</p>
</div>

<h2>Por franja horaria</h2>
<table>
  <thead><tr><th>Franja</th><th class="num">Tiempo típico</th>
    <th class="num">Desacuerdo entre fuentes</th></tr></thead>
  <tbody>
{tabla}
  </tbody>
</table>

<div class="nota">
  <p><strong>Dónde las dos fuentes no se ponen de acuerdo:</strong> el peor momento es
     {desac_hora}, con {desac_max}% de diferencia sobre el mismo trayecto. Cuando dos fuentes
     líderes discrepan así, al menos una le está mintiendo a la operación que la use, y la
     única forma de saber cuál es comparar contra viajes reales.</p>
</div>

<h2>Hora por hora</h2>
<table>
  <thead><tr><th>Salida</th><th class="num">Fuente A</th><th class="num">Fuente B</th>
    <th class="num">Desacuerdo</th></tr></thead>
  <tbody>
{horas}
  </tbody>
</table>

<div class="nota">
  <p><strong>Lo que este perfil no dice.</strong> Acá no hay margen de cumplimiento, y es a
     propósito: el margen exige comparar contra viajes que de verdad ocurrieron. Con los tiempos
     reales de veinte o treinta viajes de este corredor —hora de salida y duración— se calcula
     cuánto margen necesita cada franja para cumplirle al 90%, que es la cifra que decide si la
     ventana se cumple. Cómo se mide y qué salió mal al intentarlo: etacheck.cl/estudio</p>
</div>

<footer>
  ETA Check · {fecha} · contacto@etacheck.cl · etacheck.cl<br>
  Perfil de tráfico típico declarado por dos proveedores de ruteo para un día laboral.
  No se publican sus respuestas: este documento es para uso interno de quien lo recibe.
</footer>

</div></body></html>
"""


if __name__ == "__main__":
    main()
