#!/usr/bin/env python3
"""Publica lo que medimos en Santiago, con cifras reales y sin nombrar proveedores.

Es la pieza de venta: en vez de prometer que medimos, muestra la medición.
Compara dos fuentes de ruteo entre sí sobre el mismo trayecto y el mismo
instante, y publica la mediana del desacuerdo por franja horaria.

No nombra a ninguna de las dos fuentes y no publica ninguna respuesta suya,
solo un agregado propio, que es el mismo criterio que ya usa metodo.html.
Tampoco dice "error": el desacuerdo no es error contra la realidad, y
confundirlos es lo único que nos puede costar la credibilidad.

Uso: tools/build-santiago.py [--db calib-global.sqlite] [--out site]
"""
import argparse
import json
import statistics
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Santiago")
MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
# Nombre en la tabla, horario, horas locales, y cómo se lee en una frase.
FRANJAS = [("Madrugada", "00–06", range(0, 6), "madrugada"),
           ("Punta mañana", "06–10", range(6, 10), "punta de la mañana"),
           ("Mediodía", "10–16", range(10, 16), "franja del mediodía"),
           ("Punta tarde", "16–20", range(16, 20), "punta de la tarde"),
           ("Noche", "20–24", range(20, 24), "noche")]
PROSA = {n: p for n, _, _, p in FRANJAS}


def fmt(x):
    """Porcentaje con coma decimal, como se escribe en Chile."""
    return f"{x * 100:.1f}%".replace(".", ",")


def santiago_routes(routes_dir, extra):
    """Corredores urbanos de Santiago, por la convención label "(santiago)".

    Deja fuera el interurbano Maitencillo-Las Condes: en carretera las dos
    fuentes casi no discrepan, y promediarlo con la ciudad escondería justo
    lo que importa.
    """
    files = list(Path(routes_dir).glob("*.json"))
    if Path(extra).exists():
        files.append(Path(extra))
    out = {}
    for f in files:
        r = json.loads(f.read_text())
        label = r.get("label", r["id"])
        if label.strip().endswith("(santiago)"):
            out[r["id"]] = label.replace("(santiago)", "").strip()
    return out


def disagreement(db, route_id):
    """(hora local -> lista de desacuerdos relativos) sobre muestras simultáneas."""
    rows = db.execute("""
        SELECT a.captured_at, a.duration_s, b.duration_s
        FROM sample a JOIN sample b
          ON a.route_id = b.route_id AND a.captured_at = b.captured_at
        WHERE a.provider < b.provider AND a.route_id = ?
    """, (route_id,)).fetchall()
    by_hour = {}
    for at, x, y in rows:
        h = datetime.fromtimestamp(at, TZ).hour
        by_hour.setdefault(h, []).append(abs(x - y) / ((x + y) / 2))
    return by_hour


def pct(values):
    return fmt(statistics.median(values)) if values else "—"


def tone(values):
    if not values:
        return "nulo"
    g = statistics.median(values)
    return "alto" if g >= 0.15 else "medio" if g >= 0.08 else "bajo"


def build(db_path, out_dir, routes_dir, extra):
    import sqlite3
    db = sqlite3.connect(db_path)
    labels = santiago_routes(routes_dir, extra)

    medido, pendientes, todo = [], [], []
    for rid, label in sorted(labels.items()):
        by_hour = disagreement(db, rid)
        n = sum(len(v) for v in by_hour.values())
        if n == 0:
            pendientes.append(label)
            continue
        flat = [x for v in by_hour.values() for x in v]
        medido.append((label, n, by_hour, flat))
        todo += flat

    if not todo:
        raise SystemExit("todavía no hay pares simultáneos en Santiago")

    filas = ""
    for label, n, by_hour, flat in sorted(medido, key=lambda r: -statistics.median(r[3])):
        celdas = ""
        for _, _, horas, _ in FRANJAS:
            v = [x for h in horas for x in by_hour.get(h, [])]
            celdas += f'<td class="num {tone(v)}">{pct(v)}</td>'
        filas += (f'      <tr><td><strong>{label}</strong></td>'
                  f'<td class="num muted">{n}</td>{celdas}</tr>\n')
    for label in pendientes:
        filas += (f'      <tr><td><strong>{label}</strong></td>'
                  f'<td class="num muted">0</td>'
                  f'<td class="nulo" colspan="5">recién dado de alta, midiendo</td></tr>\n')

    # El titular compara corredores DENTRO de la misma franja, no franjas
    # entre sí: mezclar una franja que solo tiene datos de un corredor con
    # otra que los tiene de cuatro daría una cifra que no significa nada.
    mejor_contraste = None
    for nombre, _, horas, prosa in FRANJAS:
        por_ruta = []
        for label, _, by_hour, _ in medido:
            v = [x for h in horas for x in by_hour.get(h, [])]
            if len(v) >= 3:
                por_ruta.append((statistics.median(v), label))
        if len(por_ruta) < 3:
            continue
        por_ruta.sort()
        (bajo, ruta_baja), (alto, ruta_alta) = por_ruta[0], por_ruta[-1]
        if bajo > 0 and (mejor_contraste is None or alto / bajo > mejor_contraste[0]):
            mejor_contraste = (alto / bajo, prosa, alto, ruta_alta, bajo, ruta_baja, len(por_ruta))
    if mejor_contraste is None:
        raise SystemExit("todavía no hay tres corredores con datos en una misma franja")
    _, franja_prosa, alto, ruta_alta, bajo, ruta_baja, cuantos = mejor_contraste
    veces = alto / bajo
    now = datetime.now(timezone.utc)

    html = PAGE.format(
        periodo=f"{MESES[now.month - 1]} {now.year}",
        actualizado=datetime.now(TZ).strftime("%d-%m-%Y %H:%M"),
        corredores=len(medido),
        pares=f"{len(todo):,}".replace(",", "."),
        mediana=fmt(statistics.median(todo)),
        maximo=fmt(max(todo)),
        hero_valor=fmt(alto),
        hero_ruta=ruta_alta,
        hero_bajo=fmt(bajo),
        hero_ruta_baja=ruta_baja,
        hero_franja=franja_prosa,
        hero_veces=f"{veces:.1f}".replace(".", ","),
        hero_cuantos=cuantos,
        corredores_label="corredor con datos" if len(medido) == 1 else "corredores con datos",
        encabezados="".join(f'<th class="num">{n}<span>{h}</span></th>' for n, h, _, _ in FRANJAS),
        filas=filas.rstrip(),
    )
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "santiago.html").write_text(html)
    print(f"{out}/santiago.html — {len(medido)} corredores con datos, "
          f"{len(pendientes)} midiendo, {len(todo)} pares, "
          f"mediana {fmt(statistics.median(todo))}")


PAGE = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Santiago medido — ETA Check</title>
<meta name="description" content="Cuánto se contradicen dos fuentes de tiempo de viaje en corredores de Santiago, medido cada 30 minutos y desglosado por franja horaria.">
<link rel="canonical" href="https://etacheck.cl/santiago">
<style>
  :root {{
    --bg: #fbfaf8; --surface: #fff; --text: #17171a; --muted: #67665f;
    --line: #e7e3db; --accent: #b4491f; --accent-soft: #f5e7e0;
    --alto: #b5352a; --medio: #b07d1a; --bajo: #3f6f52; --radius: 14px;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg: #141416; --surface: #1d1d20; --text: #ededea; --muted: #9c9a94;
      --line: #313137; --accent: #e08b62; --accent-soft: #2a211d;
      --alto: #e8776b; --medio: #d4a955; --bajo: #82b394;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #141416; --surface: #1d1d20; --text: #ededea; --muted: #9c9a94;
    --line: #313137; --accent: #e08b62; --accent-soft: #2a211d;
    --alto: #e8776b; --medio: #d4a955; --bajo: #82b394;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text);
    font: 17px/1.65 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased; }}
  .wrap {{ max-width: 860px; margin: 0 auto; padding: 0 16px; }}
  header {{ padding: 28px 0; border-bottom: 1px solid var(--line); display: flex;
           justify-content: space-between; align-items: center; gap: 16px; }}
  .brand {{ font-weight: 650; font-size: 17px; text-decoration: none; color: var(--text); }}
  .brand span {{ color: var(--accent); }}
  header a.volver {{ color: var(--muted); text-decoration: none; font-size: 15px; }}
  .eyebrow {{ color: var(--accent); font-size: 13px; letter-spacing: .08em;
             text-transform: uppercase; font-weight: 600; margin: 40px 0 8px; }}
  h1 {{ font-size: clamp(28px, 5vw, 40px); line-height: 1.13; letter-spacing: -.025em;
       margin: 0 0 14px; font-weight: 640; }}
  .lead {{ font-size: 19px; color: var(--muted); margin: 0 0 32px; max-width: 62ch; }}
  .hero {{ background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius);
          padding: 26px; margin-bottom: 14px; }}
  .hero .big {{ font-size: clamp(38px, 8vw, 56px); font-weight: 650; letter-spacing: -.03em;
               line-height: 1; color: var(--alto); }}
  .hero p {{ margin: 12px 0 0; color: var(--muted); }}
  .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
           gap: 12px; margin-bottom: 40px; }}
  .stat {{ background: var(--surface); border: 1px solid var(--line);
          border-radius: 10px; padding: 16px; }}
  .stat b {{ display: block; font-size: 25px; font-weight: 650; letter-spacing: -.02em; }}
  .stat span {{ font-size: 13px; color: var(--muted); }}
  section {{ padding: 40px 0; border-top: 1px solid var(--line); }}
  h2 {{ font-size: clamp(20px, 3vw, 25px); letter-spacing: -.02em; margin: 0 0 16px; font-weight: 640; }}
  p {{ margin: 0 0 16px; }} p:last-child {{ margin-bottom: 0; }}
  .scroll {{ overflow-x: auto; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 15px; min-width: 620px; }}
  th {{ text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: .05em;
       color: var(--muted); font-weight: 600; padding: 0 8px 10px;
       border-bottom: 1px solid var(--line); vertical-align: bottom; }}
  th span {{ display: block; font-size: 11px; letter-spacing: 0; text-transform: none; opacity: .75; }}
  td {{ padding: 13px 8px; border-bottom: 1px solid var(--line); }}
  td.num {{ text-align: right; font-variant-numeric: tabular-nums; font-weight: 650; }}
  td.muted {{ color: var(--muted); font-weight: 400; }}
  .alto {{ color: var(--alto); }} .medio {{ color: var(--medio); }} .bajo {{ color: var(--bajo); }}
  .nulo {{ color: var(--muted); font-weight: 400; }}
  .nota {{ background: var(--surface); border: 1px solid var(--line);
          border-left: 3px solid var(--accent); border-radius: 0 var(--radius) var(--radius) 0;
          padding: 18px 20px; margin: 0 0 18px; }}
  .nota strong {{ color: var(--accent); }}
  .cierre {{ background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius);
            padding: 32px 28px; text-align: center; }}
  .btn {{ display: inline-block; background: var(--accent); color: #fff; text-decoration: none;
         padding: 13px 24px; border-radius: 9px; font-weight: 600; }}
  footer {{ padding: 34px 0 60px; color: var(--muted); font-size: 14px; border-top: 1px solid var(--line); }}
  footer a {{ color: var(--muted); }}
</style>
</head>
<body>

<header class="wrap">
  <a class="brand" href="/">ETA<span>Check</span></a>
  <a class="volver" href="/">← Volver</a>
</header>

<div class="wrap">

  <p class="eyebrow">Medición en curso · {periodo}</p>
  <h1>Santiago, medido cada 30 minutos</h1>
  <p class="lead">Consultamos el mismo trayecto, en el mismo instante, a dos de las fuentes de
     tiempo de viaje más usadas del mercado. Cuando las dos no coinciden, al menos una le está
     mintiendo a la operación que la usa. Esto es lo que llevamos medido, corredor por corredor:
     el desacuerdo no se parece entre rutas ni entre horas.</p>

  <div class="hero">
    <div class="big">{hero_valor}</div>
    <p>de desacuerdo en <strong>{hero_ruta}</strong>, en la {hero_franja}. A la misma hora y en la misma
       ciudad, <strong>{hero_ruta_baja}</strong> marca {hero_bajo}: {hero_veces} veces menos.
       Por eso un factor de corrección no se copia de una ruta a la de al lado.</p>
  </div>

  <div class="stats">
    <div class="stat"><b>{mediana}</b><span>desacuerdo mediano</span></div>
    <div class="stat"><b>{maximo}</b><span>el peor caso registrado</span></div>
    <div class="stat"><b>{corredores}</b><span>{corredores_label}</span></div>
    <div class="stat"><b>{pares}</b><span>comparaciones simultáneas</span></div>
  </div>

  <section>
    <h2>Corredor por corredor, franja por franja</h2>
    <div class="scroll">
      <table>
        <thead><tr><th>Corredor</th><th class="num">Comp.</th>{encabezados}</tr></thead>
        <tbody>
{filas}
        </tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>Qué es y qué no es esta cifra</h2>
    <div class="nota">
      <p><strong>No es error, es desacuerdo.</strong> Mide cuánto se separan dos fuentes entre sí,
         no cuánto se equivoca alguna contra la realidad. Es un límite inferior del problema: si
         dos fuentes difieren 15%, al menos una se equivoca en algo cercano a eso, pero para saber
         cuál hace falta el tiempo real del viaje. Eso es lo que medimos con cada cliente.</p>
    </div>
    <p>La cifra de cada celda es la mediana de las comparaciones de esa franja, no el promedio: una
       medición rara no la mueve. La columna "Comp." es cuántas comparaciones simultáneas lleva ese
       corredor, y conviene mirarla: con pocas, la celda es una señal, no un resultado.</p>
    <p>Los puntos son a nivel de comuna, que es la unidad con la que se cotiza el despacho en Chile.
       En tu operación el origen es una bodega concreta, y ahí las cifras cambian: por eso el informe
       se hace sobre tus corredores y no sobre estos.</p>
    <p>No nombramos a las dos fuentes ni publicamos ninguna respuesta suya. Lo que se publica acá es
       un agregado calculado por nosotros. El método completo está en
       <a href="/metodo">etacheck.cl/metodo</a>.</p>
  </section>

  <section>
    <div class="cierre">
      <h2>¿Y en tus corredores?</h2>
      <p>Dime una comuna donde más te reclamen y mido ese corredor dos semanas, sin costo.
         Te mando el desglose por hora como esta tabla, pero con tus rutas.</p>
      <a class="btn" href="mailto:contacto@etacheck.cl?subject=Quiero%20medir%20mi%20corredor">Escribir a contacto@etacheck.cl</a>
    </div>
  </section>

</div>

<footer class="wrap">
  Actualizado el {actualizado} · <a href="/metodo">El método</a> ·
  <a href="/ejemplo">Informe de ejemplo</a> ·
  <a href="mailto:contacto@etacheck.cl">contacto@etacheck.cl</a>
</footer>

</body>
</html>
"""


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--out", default="site")
    ap.add_argument("--routes", default="routes")
    ap.add_argument("--extra", default="route.json")
    a = ap.parse_args()
    build(a.db, a.out, a.routes, a.extra)
