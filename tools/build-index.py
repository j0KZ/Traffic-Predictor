#!/usr/bin/env python3
"""Genera el índice público de desacuerdo entre proveedores de ETA.

Solo usa TomTom y Mapbox, nunca Waze: el índice es publicable porque
compara dos fuentes licenciadas entre sí y publica un agregado, no sus
respuestas. La medida es |tomtom - mapbox| / promedio, sobre pares
tomados en el mismo instante y el mismo corredor.

Uso: tools/build-index.py [--db calib-global.sqlite] [--out site]
"""
import argparse
import json
import sqlite3
import statistics
from datetime import datetime, timezone
from pathlib import Path

MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre"]


def city_labels(routes_dir: Path, extra: Path):
    """route_id -> nombre legible, desde los archivos de ruta."""
    out = {}
    files = list(routes_dir.glob("*.json"))
    if extra.exists():
        files.append(extra)
    for f in files:
        r = json.loads(f.read_text())
        label = r.get("label", r["id"])
        # "silom-chatuchak (bangkok)" -> corredor + ciudad
        if "(" in label:
            corridor, city = label.split("(", 1)
            out[r["id"]] = (corridor.strip(), city.rstrip(")").strip().title())
        else:
            out[r["id"]] = (label, "")
    return out


def measure(db):
    """Desacuerdo por corredor, sobre muestras simultáneas."""
    rows = db.execute("""
        SELECT a.route_id, a.captured_at, a.duration_s, b.duration_s
        FROM sample a
        JOIN sample b ON a.route_id = b.route_id AND a.captured_at = b.captured_at
        WHERE a.provider = 'tomtom' AND b.provider = 'mapbox'
    """).fetchall()
    by = {}
    for rid, _, tt, mb in rows:
        by.setdefault(rid, []).append(abs(tt - mb) / ((tt + mb) / 2))
    return {rid: (len(v), statistics.median(v)) for rid, v in by.items() if len(v) >= 3}


def row_html(rank, corridor, city, n, gap):
    # El color marca la gravedad sin necesidad de leyenda.
    tone = "alto" if gap >= 0.20 else "medio" if gap >= 0.10 else "bajo"
    return f"""      <tr>
        <td class="rank">{rank}</td>
        <td><strong>{city}</strong><span class="corridor">{corridor}</span></td>
        <td class="num">{n}</td>
        <td class="num gap {tone}">{gap * 100:.1f}%</td>
      </tr>"""


def build(db_path, out_dir, routes_dir, extra):
    db = sqlite3.connect(db_path)
    data = measure(db)
    labels = city_labels(Path(routes_dir), Path(extra))
    ranked = sorted(data.items(), key=lambda kv: -kv[1][1])

    total_pairs = sum(n for n, _ in data.values())
    worst = ranked[0] if ranked else None
    median_gap = statistics.median([g for _, g in data.values()]) if data else 0
    now = datetime.now(timezone.utc)
    period = f"{MESES[now.month - 1]} {now.year}"

    rows = "\n".join(
        row_html(i + 1, *labels.get(rid, (rid, "")), n, g)
        for i, (rid, (n, g)) in enumerate(ranked)
    )
    worst_city = labels.get(worst[0], ("", ""))[1] if worst else "—"
    worst_gap = f"{worst[1][1] * 100:.0f}%" if worst else "—"

    html = PAGE.format(
        period=period,
        updated=now.strftime("%d-%m-%Y %H:%M UTC"),
        worst_city=worst_city,
        worst_gap=worst_gap,
        median_gap=f"{median_gap * 100:.1f}%",
        corridors=len(data),
        pairs=f"{total_pairs:,}".replace(",", "."),
        rows=rows,
    )

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(html)
    (out / "data.json").write_text(json.dumps({
        "period": period,
        "updated": now.isoformat(),
        "corridors": [
            {"id": rid, "corridor": labels.get(rid, (rid, ""))[0],
             "city": labels.get(rid, ("", ""))[1], "samples": n, "disagreement": round(g, 4)}
            for rid, (n, g) in ranked
        ],
    }, ensure_ascii=False, indent=2))
    print(f"{out}/index.html — {len(data)} corredores, {total_pairs} pares")


PAGE = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Índice de Desacuerdo de ETA</title>
<meta name="description" content="Cuánto se contradicen los principales proveedores de tiempo de viaje, medido cada 30 minutos en corredores de todo el mundo.">
<style>
  :root {{
    --bg: #fbfaf8; --surface: #fff; --text: #1a1a18; --muted: #6b6a66;
    --line: #e6e3dd; --accent: #b8562f; --alto: #c0392b; --medio: #b8860b; --bajo: #4a7c59;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg: #17171a; --surface: #1f1f23; --text: #ececea; --muted: #9a9a96;
      --line: #32323a; --accent: #e0916a; --alto: #e8776b; --medio: #d4a955; --bajo: #7bb08c;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #17171a; --surface: #1f1f23; --text: #ececea; --muted: #9a9a96;
    --line: #32323a; --accent: #e0916a; --alto: #e8776b; --medio: #d4a955; --bajo: #7bb08c;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; background: var(--bg); color: var(--text);
    font: 16px/1.6 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
  }}
  .wrap {{ max-width: 860px; margin: 0 auto; padding: 48px 16px 80px; }}
  .eyebrow {{ color: var(--accent); font-size: 13px; letter-spacing: .08em;
              text-transform: uppercase; font-weight: 600; margin: 0 0 8px; }}
  h1 {{ font-size: clamp(28px, 5vw, 42px); line-height: 1.15; margin: 0 0 16px; letter-spacing: -.02em; }}
  .lead {{ font-size: 18px; color: var(--muted); margin: 0 0 40px; max-width: 60ch; }}
  .hero {{ background: var(--surface); border: 1px solid var(--line); border-radius: 14px;
           padding: 28px; margin-bottom: 40px; }}
  .hero .big {{ font-size: clamp(40px, 9vw, 64px); font-weight: 650; letter-spacing: -.03em;
                color: var(--alto); line-height: 1; }}
  .hero p {{ margin: 12px 0 0; color: var(--muted); }}
  .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 12px; margin-bottom: 44px; }}
  .stat {{ background: var(--surface); border: 1px solid var(--line);
           border-radius: 10px; padding: 16px; }}
  .stat b {{ display: block; font-size: 26px; font-weight: 650; letter-spacing: -.02em; }}
  .stat span {{ font-size: 13px; color: var(--muted); }}
  table {{ width: 100%; border-collapse: collapse; font-size: 15px; }}
  th {{ text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: .06em;
        color: var(--muted); font-weight: 600; padding: 0 8px 10px; border-bottom: 1px solid var(--line); }}
  td {{ padding: 13px 8px; border-bottom: 1px solid var(--line); vertical-align: middle; }}
  .rank {{ color: var(--muted); width: 32px; font-variant-numeric: tabular-nums; }}
  .corridor {{ display: block; font-size: 13px; color: var(--muted); }}
  .num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  .gap {{ font-weight: 650; }}
  .gap.alto {{ color: var(--alto); }}
  .gap.medio {{ color: var(--medio); }}
  .gap.bajo {{ color: var(--bajo); }}
  .method {{ margin-top: 48px; padding-top: 28px; border-top: 1px solid var(--line);
             color: var(--muted); font-size: 14px; }}
  .method h2 {{ font-size: 16px; color: var(--text); margin: 0 0 10px; }}
  .cta {{ background: var(--surface); border: 1px solid var(--line); border-radius: 14px;
          padding: 28px; margin-top: 44px; }}
  .cta h2 {{ margin: 0 0 10px; font-size: 20px; }}
  .cta p {{ margin: 0 0 18px; color: var(--muted); }}
  .btn {{ display: inline-block; background: var(--accent); color: #fff; text-decoration: none;
          padding: 12px 22px; border-radius: 8px; font-weight: 600; }}
  @media (max-width: 480px) {{ .wrap {{ padding: 32px 16px 60px; }} }}
</style>
</head>
<body>
<div class="wrap">
  <p class="eyebrow">Índice mensual · {period}</p>
  <h1>Los proveedores de ETA no se ponen de acuerdo</h1>
  <p class="lead">Medimos el mismo viaje, en el mismo minuto, con TomTom y con Mapbox.
     Cuando las dos fuentes líderes se contradicen, una de las dos le está mintiendo a tu operación.</p>

  <div class="hero">
    <div class="big">{worst_gap}</div>
    <p>de diferencia entre ambos proveedores en {worst_city}, sobre el mismo trayecto
       y el mismo instante. El peor corredor de este mes.</p>
  </div>

  <div class="stats">
    <div class="stat"><b>{median_gap}</b><span>desacuerdo mediano</span></div>
    <div class="stat"><b>{corridors}</b><span>corredores medidos</span></div>
    <div class="stat"><b>{pairs}</b><span>comparaciones simultáneas</span></div>
    <div class="stat"><b>30 min</b><span>frecuencia de medición</span></div>
  </div>

  <table>
    <thead><tr><th></th><th>Corredor</th><th class="num">Muestras</th><th class="num">Desacuerdo</th></tr></thead>
    <tbody>
{rows}
    </tbody>
  </table>

  <div class="cta">
    <h2>¿Cuánto se equivoca tu proveedor en tus rutas?</h2>
    <p>Medimos tu corredor principal durante dos semanas y te entregamos el desglose
       por franja horaria. Sin costo y sin compromiso.</p>
    <a class="btn" href="mailto:CONTACTO@DOMINIO?subject=Medici%C3%B3n%20de%20mi%20corredor">Pedir la medición</a>
  </div>

  <div class="method">
    <h2>Cómo se mide</h2>
    <p>Cada 30 minutos consultamos el tiempo de viaje de cada corredor a TomTom y a Mapbox
       en el mismo instante. El desacuerdo es la diferencia absoluta entre ambos dividida por
       su promedio, y se reporta como mediana de todas las mediciones del corredor. Solo se
       incluyen corredores con al menos 3 comparaciones. No publicamos las respuestas de
       ningún proveedor, solo el agregado estadístico.</p>
    <p>Actualizado el {updated}.</p>
  </div>
</div>
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
