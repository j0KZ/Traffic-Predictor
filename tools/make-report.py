#!/usr/bin/env python3
"""Informe de auditoría de ETA para un cliente.

Dos modos:

  Perfil (sin verdad de terreno): cómo se comporta el corredor por franja,
  cuánto varía, y qué ventana de promesa aguanta ese comportamiento.

  Auditoría (con --viajes): compara el ETA del proveedor contra los viajes
  REALES del cliente. Es el modo que vale, porque la verdad es suya: mide
  error por franja, el margen que exige cada una para cumplir el 90% y el costo de
  seguir como está.

CSV de viajes: corredor,inicio_utc,duracion_s
  cliente-acme-bodega-centro,2026-09-15T13:40:00Z,2280

Uso:
  tools/make-report.py --cliente "Acme" --viajes viajes.csv \\
      --entregas-dia 800 --costo-atraso 2500 --moneda CLP
"""
import argparse
import csv
import json
import math
import sqlite3
import statistics
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

BANDAS = [(0, 6, "madrugada"), (6, 10, "punta mañana"), (10, 16, "mediodía"),
          (16, 20, "punta tarde"), (20, 24, "noche")]
MAX_GAP = 900  # el viaje real y la muestra no siempre caen en el mismo minuto


def banda(ts, tz):
    h = datetime.fromtimestamp(ts, ZoneInfo(tz)).hour
    return next(n for lo, hi, n in BANDAS if lo <= h < hi)


def cargar_rutas(root):
    out = {}
    for f in list((root / "routes").glob("*.json")) + [root / "route.json"]:
        if f.exists():
            r = json.loads(f.read_text())
            out[r["id"]] = r
    return out


def muestras(db, route_id, at, provider):
    row = db.execute(
        "SELECT duration_s, abs(captured_at - ?) d FROM sample "
        "WHERE route_id = ? AND provider = ? ORDER BY d LIMIT 1",
        (at, route_id, provider)).fetchone()
    return row[0] if row and row[1] <= MAX_GAP else None


def auditar(db, viajes, rutas):
    """Error del proveedor contra los viajes reales, por corredor y franja."""
    out = {}
    for corridor, ts, real in viajes:
        tz = rutas.get(corridor, {}).get("timeZone", "UTC")
        b = banda(ts, tz)
        for prov in ("tomtom", "mapbox"):
            s = muestras(db, corridor, ts, prov)
            if not s:
                continue
            out.setdefault((corridor, prov, b), []).append((s, real))
    return out


def perfil(db, rutas, desde):
    """Variabilidad por franja cuando todavía no hay viajes del cliente."""
    out = {}
    for corridor in rutas:
        rows = db.execute(
            "SELECT captured_at, duration_s FROM sample "
            "WHERE route_id = ? AND provider = 'mapbox' AND captured_at >= ?",
            (corridor, desde)).fetchall()
        tz = rutas[corridor].get("timeZone", "UTC")
        for ts, d in rows:
            out.setdefault((corridor, banda(ts, tz)), []).append(d)
    return out


def miles(x, decimales=0):
    """Formato chileno: punto para miles, coma para decimales."""
    t = f"{x:,.{decimales}f}"
    return t.replace(",", "@").replace(".", ",").replace("@", ".")


def fmt_min(s):
    return f"{int(round(s / 60))} min"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cliente", required=True)
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--viajes", help="CSV de viajes reales: corredor,inicio_utc,duracion_s")
    ap.add_argument("--entregas-dia", type=int, default=0)
    ap.add_argument("--costo-atraso", type=float, default=0, help="costo de una entrega tarde")
    ap.add_argument("--moneda", default="CLP")
    ap.add_argument("--margen-actual", type=float, default=1.25,
                    help="el margen plano que la operación usa hoy sobre el ETA")
    ap.add_argument("--dias", type=int, default=30)
    ap.add_argument("--out", default="reports")
    a = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    db = sqlite3.connect(a.db)
    rutas = cargar_rutas(root)
    desde = int(datetime.now(timezone.utc).timestamp()) - a.dias * 86400

    filas, resumen, modo = [], {}, "perfil"

    if a.viajes:
        modo = "auditoría"
        viajes = []
        with open(a.viajes) as f:
            for row in csv.DictReader(f):
                ts = int(datetime.fromisoformat(
                    row["inicio_utc"].replace("Z", "+00:00")).timestamp())
                viajes.append((row["corredor"], ts, int(row["duracion_s"])))
        datos = auditar(db, viajes, rutas)
        errores_todos, todas_razones = [], []
        for (corridor, prov, b), v in sorted(datos.items()):
            if len(v) < 2:
                continue
            errs = [abs(s - r) / r for s, r in v]
            # Lo que decide si se cumple la ventana no es el error medio: es
            # cuántas veces el viaje tardó más que lo prometido, y cuánto
            # margen hace falta para cubrir al 90%. Medido contra viajes
            # reales, corregir el ETA no reduce el error (ver metodo.html).
            razones = sorted(r / s for s, r in v)
            todas_razones += razones
            tarde = sum(1 for x in razones if x > 1) / len(razones)
            margen = razones[max(0, int(len(razones) * 0.9) - 1)]
            errores_todos += errs
            filas.append({
                "corredor": rutas.get(corridor, {}).get("label", corridor),
                "prov": prov, "banda": b, "n": len(v),
                "error": statistics.mean(errs) * 100,
                "tarde": tarde * 100,
                "margen": margen,
            })
        resumen["error"] = statistics.mean(errores_todos) * 100 if errores_todos else 0
        resumen["tarde"] = statistics.mean([f["tarde"] for f in filas]) if filas else 0
        resumen["margen"] = max([f["margen"] for f in filas], default=1.0)
        resumen["razones"] = sorted(todas_razones)
        resumen["viajes"] = len(viajes)
    else:
        datos = perfil(db, rutas, desde)
        for (corridor, b), v in sorted(datos.items()):
            if len(v) < 3:
                continue
            med = statistics.median(v)
            p90 = sorted(v)[int(len(v) * 0.9) - 1]
            filas.append({
                "corredor": rutas.get(corridor, {}).get("label", corridor),
                "prov": "—", "banda": b, "n": len(v),
                "error": (p90 - med) / med * 100,
                "factor": med, "corregido": p90,
            })
        resumen["error"] = statistics.mean([f["error"] for f in filas]) if filas else 0

    # Plata: cuántas entregas se caen por el error actual, y cuántas se salvan.
    plata = ""
    if a.entregas_dia and a.costo_atraso and modo == "auditoría":
        # Contra el margen que la operación ya usa, no contra el ETA crudo:
        # nadie promete el ETA pelado, y suponerlo infla la cifra hasta el
        # ridículo. El escenario con el margen medido incumple el 10% por
        # construcción del percentil.
        razones = resumen.get("razones") or [1.0]
        falla_hoy = sum(1 for x in razones if x > a.margen_actual) / len(razones)
        tarde_hoy = a.entregas_dia * falla_hoy
        tarde_calib = a.entregas_dia * 0.10
        ahorro = max(0, tarde_hoy - tarde_calib) * a.costo_atraso * 30
        plata = f"""
  <div class="hero">
    <div class="big">{miles(ahorro)} {a.moneda}</div>
    <p>al mes en entregas que dejarían de salirse de la ventana, con {miles(a.entregas_dia)}
       entregas diarias y un costo de {miles(a.costo_atraso)} {a.moneda} por reprogramación.
       Con el margen plano de ×{miles(a.margen_actual, 2)} que se usa hoy se caen unas
       {miles(tarde_hoy)} al día; con el margen medido por franja, {miles(tarde_calib)}.</p>
  </div>"""

    rows = "\n".join(
        f"""      <tr><td>{f['corredor']}</td><td>{f['banda']}</td><td>{f['prov']}</td>
        <td class="num">{f['n']}</td><td class="num">{f['error']:.1f}%</td>
        <td class="num alto">{f['tarde']:.0f}%</td>
        <td class="num bajo">×{f['margen']:.2f}</td></tr>""".replace(".", ",")
        for f in filas) if modo == "auditoría" else "\n".join(
        f"""      <tr><td>{f['corredor']}</td><td>{f['banda']}</td><td class="num">{f['n']}</td>
        <td class="num">{fmt_min(f['factor'])}</td><td class="num">{fmt_min(f['corregido'])}</td>
        <td class="num alto">+{f['error']:.0f}%</td></tr>""" for f in filas)

    encabezados = ("<th>Corredor</th><th>Franja</th><th>Fuente</th><th class='num'>Viajes</th>"
                   "<th class='num'>Error</th><th class='num'>Llegan tarde</th>"
                   "<th class='num'>Margen 90%</th>") if modo == "auditoría" else (
                   "<th>Corredor</th><th>Franja</th><th class='num'>Muestras</th>"
                   "<th class='num'>Típico</th><th class='num'>Peor caso (p90)</th>"
                   "<th class='num'>Margen</th>")

    intro = (f"Comparamos {resumen.get('viajes', 0)} viajes reales suyos contra lo que "
             f"predecía el proveedor en ese mismo momento."
             if modo == "auditoría" else
             f"Medimos sus corredores cada 30 minutos durante {a.dias} días. "
             f"Todavía sin viajes reales: este es el comportamiento observado.")

    titular = (f"{resumen['tarde']:.0f}%" if modo == "auditoría" else f"{len(filas)}")
    subtitular = ("de sus viajes tardaron más que el ETA del proveedor."
                  if modo == "auditoría" else "combinaciones de corredor y franja medidas.")

    html = PAGE.format(
        cliente=a.cliente, modo=modo.title(), intro=intro, plata=plata,
        titular=titular, subtitular=subtitular, encabezados=encabezados, rows=rows,
        fecha=datetime.now(timezone.utc).strftime("%d-%m-%Y"),
        corregido=(f"<p><strong>El margen que exige su corredor más difícil es "
                   f"×{resumen['margen']:.2f}".replace(".", ",") + f" para cumplirle al 90%.</strong> Un margen plano "
                   f"más chico incumple ahí, y uno más grande regala capacidad en las franjas "
                   f"tranquilas. El error medio del proveedor es {resumen['error']:.1f}%, y "
                   f"corregirlo no lo reduce: lo que cambia el cumplimiento es el margen.</p>"
                   if modo == "auditoría" else ""))

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    f = out / f"informe-{a.cliente.lower().replace(' ', '-')}.html"
    f.write_text(html)
    print(f"{f} — {len(filas)} filas, modo {modo}")


PAGE = """<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Auditoría de ETA · {cliente}</title>
<style>
  :root {{ --bg:#fbfaf8; --surface:#fff; --text:#1a1a18; --muted:#6b6a66; --line:#e6e3dd;
           --accent:#b8562f; --alto:#c0392b; --bajo:#4a7c59; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
    --bg:#17171a; --surface:#1f1f23; --text:#ececea; --muted:#9a9a96; --line:#32323a;
    --accent:#e0916a; --alto:#e8776b; --bajo:#7bb08c; }} }}
  :root[data-theme="dark"] {{ --bg:#17171a; --surface:#1f1f23; --text:#ececea;
    --muted:#9a9a96; --line:#32323a; --accent:#e0916a; --alto:#e8776b; --bajo:#7bb08c; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text);
    font:16px/1.6 ui-sans-serif, system-ui, -apple-system, sans-serif; }}
  .wrap {{ max-width:880px; margin:0 auto; padding:48px 16px 80px; }}
  .eyebrow {{ color:var(--accent); font-size:13px; letter-spacing:.08em; text-transform:uppercase;
              font-weight:600; margin:0 0 8px; }}
  h1 {{ font-size:clamp(26px,5vw,38px); margin:0 0 14px; letter-spacing:-.02em; }}
  .lead {{ font-size:17px; color:var(--muted); margin:0 0 36px; max-width:62ch; }}
  .hero {{ background:var(--surface); border:1px solid var(--line); border-radius:14px;
           padding:26px; margin-bottom:32px; }}
  .hero .big {{ font-size:clamp(34px,8vw,56px); font-weight:650; letter-spacing:-.03em;
                color:var(--alto); line-height:1; }}
  .hero p {{ margin:12px 0 0; color:var(--muted); }}
  table {{ width:100%; border-collapse:collapse; font-size:15px; }}
  th {{ text-align:left; font-size:12px; text-transform:uppercase; letter-spacing:.05em;
        color:var(--muted); padding:0 8px 10px; border-bottom:1px solid var(--line); }}
  td {{ padding:12px 8px; border-bottom:1px solid var(--line); }}
  .num {{ text-align:right; font-variant-numeric:tabular-nums; }}
  .alto {{ color:var(--alto); font-weight:600; }}
  .bajo {{ color:var(--bajo); font-weight:600; }}
  .method {{ margin-top:44px; padding-top:26px; border-top:1px solid var(--line);
             color:var(--muted); font-size:14px; }}
  .method h2 {{ font-size:16px; color:var(--text); margin:0 0 10px; }}
  @media (max-width:560px) {{ table {{ font-size:13px; }} td,th {{ padding:9px 5px; }} }}
</style></head><body><div class="wrap">
  <p class="eyebrow">{modo} de ETA · {fecha}</p>
  <h1>{cliente}</h1>
  <p class="lead">{intro}</p>
  <div class="hero"><div class="big">{titular}</div><p>{subtitular}</p></div>
  {plata}
  {corregido}
  <table><thead><tr>{encabezados}</tr></thead><tbody>
{rows}
  </tbody></table>
  <div class="method">
    <h2>Cómo se midió</h2>
    <p>Cada corredor se consulta cada 30 minutos a dos proveedores de ruteo. En modo auditoría,
       cada viaje real informado se compara con la predicción vigente en ese mismo momento,
       tolerando hasta 15 minutos de diferencia entre ambos registros. El margen es el
       percentil 90 de la razón entre lo real y lo predicho: multiplicar la predicción por ese
       número deja fuera de la ventana solo a uno de cada diez viajes.</p>
    <p>Las franjas son hora local del corredor. Las entregas tarde de hoy no se estiman: es el
       porcentaje medido de viajes que tardaron más que lo prometido. El escenario con margen
       incumple el 10% por construcción del percentil.</p>
  </div>
</div></body></html>
"""


if __name__ == "__main__":
    main()
