#!/usr/bin/env python3
"""Publica el estudio contra viajes reales: site/estudio.html.

Sale de truth-chicago-largos.sqlite, que junta viajes de taxi publicados por
Chicago con la predicción que cada proveedor daba para ese mismo instante.
No nombra a los proveedores, igual que el resto del sitio.

La cifra que manda no es el error medio, es cuántos viajes tardaron más que
lo prometido y cuánto margen hace falta para cumplirle al 90%. El error medio
aparece igual, porque esconderlo sería lo mismo que maquillarlo.

Uso: tools/build-estudio.py [--db truth-chicago-largos.sqlite] [--out site]
"""
import argparse
import math
import re
import sqlite3
import statistics
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Chicago")
MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
FRANJAS = [("Madrugada", "00–06", range(0, 6)), ("Punta mañana", "06–10", range(6, 10)),
           ("Mediodía", "10–16", range(10, 16)), ("Punta tarde", "16–20", range(16, 20)),
           ("Noche", "20–24", range(20, 24))]
# Los proveedores no se nombran: se publica un agregado propio, no sus datos.
ALIAS = {"mapbox-tipico": "Fuente A", "tomtom-tipico": "Fuente B"}


def coma(x, dec=1):
    return f"{x:.{dec}f}".replace(".", ",")


def cargar(db_path, desfase):
    db = sqlite3.connect(db_path)
    filas = db.execute("""
        SELECT s.provider, r.captured_at, r.duration_s, s.duration_s,
               r.distance_m, s.distance_m
        FROM reference r JOIN sample s
          ON s.route_id = r.route_id AND s.captured_at = r.captured_at
        WHERE r.source = 'real'
    """).fetchall()
    obs = {}
    for prov, at, real, pred, dr, ds in filas:
        if not dr or not ds or abs(ds - dr) / dr > desfase:
            continue
        hora = datetime.fromtimestamp(at, TZ).hour
        obs.setdefault(ALIAS.get(prov, prov), []).append((hora, real, pred))
    return obs


def cargar_por_corredor(db_path, desfase, proveedor):
    """Márgenes de cada corredor para una sola fuente: mezclarlas los confunde."""
    db = sqlite3.connect(db_path)
    filas = db.execute("""
        SELECT r.route_id, r.duration_s, s.duration_s, r.distance_m, s.distance_m
        FROM reference r JOIN sample s
          ON s.route_id = r.route_id AND s.captured_at = r.captured_at
        WHERE r.source = 'real' AND s.provider = ?
    """, (proveedor,)).fetchall()
    por = {}
    for rid, real, pred, dr, ds in filas:
        if not dr or not ds or abs(ds - dr) / dr > desfase:
            continue
        por.setdefault(rid, []).append(real / pred)
    return {k: sorted(v) for k, v in por.items() if len(v) >= 5}


def resumen(v):
    razones = sorted(r / p for _, r, p in v)
    n = len(razones)
    return {
        "n": n,
        "error": sum(abs(p - r) / r for _, r, p in v) / n,
        "sesgo": math.exp(statistics.mean(math.log(x) for x in razones)) - 1,
        "tarde": sum(1 for x in razones if x > 1) / n,
        "m90": razones[max(0, int(n * 0.9) - 1)],
        "m95": razones[max(0, int(n * 0.95) - 1)],
    }


def build(db_path, out_dir, desfase):
    obs = cargar(db_path, desfase)
    if not obs:
        raise SystemExit("sin observaciones utilizables")
    fuentes = sorted(obs)
    res = {f: resumen(obs[f]) for f in fuentes}
    total = sum(r["n"] for r in res.values())
    peor = max(fuentes, key=lambda f: res[f]["tarde"])

    # El hallazgo que manda: el margen necesario no es un número, es un rango.
    por_corr = cargar_por_corredor(db_path, desfase, "mapbox-tipico")
    margenes = {rid: v[max(0, int(len(v) * 0.9) - 1)] for rid, v in por_corr.items()}
    m_min = min(margenes.values())
    m_max = max(margenes.values())
    filas_corr = "\n".join(
        f'        <tr><td>Corredor {i}</td>'
        f'<td class="num muted">{len(por_corr[rid])}</td>'
        f'<td class="num">{sum(1 for x in por_corr[rid] if x > 1) / len(por_corr[rid]) * 100:.0f}%</td>'
        f'<td class="num {"alto" if m >= 1.3 else "medio" if m >= 1.15 else "bajo"}">'
        f'×{coma(m, 2)}</td></tr>'
        for i, (rid, m) in enumerate(sorted(margenes.items(), key=lambda kv: -kv[1]), 1))

    cab_f = "".join(f'<th class="num">{f}</th>' for f in fuentes)
    cuerpo = ""
    for nombre, horas_txt, horas in FRANJAS:
        celdas = ""
        hay = False
        for f in fuentes:
            v = [o for o in obs[f] if o[0] in horas]
            if len(v) < 12:        # menos que esto es ruido, no una franja
                celdas += '<td class="num nulo">—</td><td class="num nulo">—</td>'
                continue
            hay = True
            r = resumen(v)
            tono = "alto" if r["tarde"] >= 0.65 else "medio" if r["tarde"] >= 0.5 else "bajo"
            celdas += (f'<td class="num {tono}">{r["tarde"] * 100:.0f}%</td>'
                       f'<td class="num">×{coma(r["m90"], 2)}</td>')
        if hay:
            cuerpo += (f'      <tr><td><strong>{nombre}</strong>'
                       f'<span class="horas">{horas_txt}</span></td>{celdas}</tr>\n')

    ahora = datetime.now()
    html = PAGE.format(
        periodo=f"{MESES[ahora.month - 1]} {ahora.year}",
        viajes=f"{total:,}".replace(",", "."),
        corredores=len(margenes),
        m_min=coma(m_min, 2),
        m_max=coma(m_max, 2),
        filas_corredor=filas_corr,
        tarde=f"{res[peor]['tarde'] * 100:.0f}%",
        error_min=coma(min(r["error"] for r in res.values()) * 100),
        error_max=coma(max(r["error"] for r in res.values()) * 100),
        filas_fuente="\n".join(
            f'        <tr><td><strong>{f}</strong></td>'
            f'<td class="num muted">{res[f]["n"]}</td>'
            f'<td class="num">{coma(res[f]["error"] * 100)}%</td>'
            f'<td class="num">{coma(res[f]["sesgo"] * 100)}%</td>'
            f'<td class="num alto">{res[f]["tarde"] * 100:.0f}%</td>'
            f'<td class="num bajo">×{coma(res[f]["m90"], 2)}</td>'
            f'<td class="num">×{coma(res[f]["m95"], 2)}</td></tr>' for f in fuentes),
        cab_franjas="".join(f'<th class="num" colspan="2">{f}</th>' for f in fuentes),
        sub_franjas="".join('<th class="num sub">tarde</th><th class="num sub">margen 90%</th>'
                            for _ in fuentes),
        cuerpo_franjas=cuerpo.rstrip(),
        actualizado=ahora.strftime("%d-%m-%Y"),
    )
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "estudio.html").write_text(html)
    print(f"{out}/estudio.html — {total} observaciones, "
          f"márgenes por corredor de ×{m_min:.2f} a ×{m_max:.2f}, "
          + ", ".join(f"{f}: tarde {res[f]['tarde']*100:.0f}%, error "
                      f"{res[f]['error']*100:.1f}%" for f in fuentes))


PAGE = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>El margen que tu ETA necesita — ETA Check</title>
<meta name="description" content="{viajes} viajes reales contra la predicción del mismo instante: el margen necesario va de ×{m_min} a ×{m_max} en la misma ciudad. Por eso un margen plano no sirve.">
<link rel="canonical" href="https://etacheck.cl/estudio">
<meta property="og:title" content="El margen que tu ETA necesita va de ×{m_min} a ×{m_max}">
<meta property="og:description" content="{viajes} comparaciones contra viajes que de verdad ocurrieron. En la misma ciudad, cada corredor pide un margen distinto.">
<meta property="og:url" content="https://etacheck.cl/estudio">
<style>
  :root {{
    --bg:#fbfaf8; --surface:#fff; --text:#17171a; --muted:#67665f; --line:#e7e3db;
    --accent:#b4491f; --accent-soft:#f5e7e0; --alto:#b5352a; --medio:#b07d1a;
    --bajo:#3f6f52; --radius:14px;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg:#141416; --surface:#1d1d20; --text:#ededea; --muted:#9c9a94; --line:#313137;
      --accent:#e08b62; --accent-soft:#2a211d; --alto:#e8776b; --medio:#d4a955; --bajo:#82b394;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg:#141416; --surface:#1d1d20; --text:#ededea; --muted:#9c9a94; --line:#313137;
    --accent:#e08b62; --accent-soft:#2a211d; --alto:#e8776b; --medio:#d4a955; --bajo:#82b394;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text);
    font:17px/1.65 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing:antialiased; }}
  .wrap {{ max-width:820px; margin:0 auto; padding:0 16px; }}
  header {{ padding:28px 0; border-bottom:1px solid var(--line); display:flex;
    justify-content:space-between; align-items:center; gap:16px; }}
  .brand {{ font-weight:650; font-size:17px; text-decoration:none; color:var(--text); }}
  .brand span {{ color:var(--accent); }}
  header a.volver {{ color:var(--muted); text-decoration:none; font-size:15px; }}
  .eyebrow {{ color:var(--accent); font-size:13px; letter-spacing:.08em; text-transform:uppercase;
    font-weight:600; margin:40px 0 8px; }}
  h1 {{ font-size:clamp(29px,5.6vw,44px); line-height:1.1; letter-spacing:-.03em;
    margin:0 0 16px; font-weight:640; }}
  .lead {{ font-size:19px; color:var(--muted); margin:0 0 32px; max-width:62ch; }}
  .hero {{ background:var(--surface); border:1px solid var(--line); border-radius:var(--radius);
    padding:26px; margin-bottom:14px; }}
  .hero .big {{ font-size:clamp(40px,8.5vw,60px); font-weight:650; letter-spacing:-.03em;
    line-height:1; color:var(--alto); }}
  .hero p {{ margin:12px 0 0; color:var(--muted); }}
  section {{ padding:42px 0; border-top:1px solid var(--line); }}
  h2 {{ font-size:clamp(20px,3vw,26px); letter-spacing:-.02em; margin:0 0 16px; font-weight:640; }}
  p {{ margin:0 0 16px; }} p:last-child {{ margin-bottom:0; }}
  ul {{ margin:0 0 16px; padding-left:22px; }} li {{ margin-bottom:8px; }}
  .scroll {{ overflow-x:auto; }}
  table {{ width:100%; border-collapse:collapse; font-size:15px; min-width:560px; }}
  th {{ text-align:left; font-size:12px; text-transform:uppercase; letter-spacing:.05em;
    color:var(--muted); font-weight:600; padding:0 8px 10px; border-bottom:1px solid var(--line);
    vertical-align:bottom; }}
  th.sub {{ text-transform:none; letter-spacing:0; font-size:11px; padding-top:4px; }}
  td {{ padding:13px 8px; border-bottom:1px solid var(--line); }}
  td.num {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:650; }}
  td.muted {{ color:var(--muted); font-weight:400; }}
  .horas {{ display:block; font-size:12px; color:var(--muted); font-weight:400; }}
  .alto {{ color:var(--alto); }} .medio {{ color:var(--medio); }} .bajo {{ color:var(--bajo); }}
  .nulo {{ color:var(--muted); font-weight:400; }}
  .nota {{ background:var(--surface); border:1px solid var(--line); border-left:3px solid var(--accent);
    border-radius:0 var(--radius) var(--radius) 0; padding:18px 20px; margin:0 0 18px; }}
  .nota strong {{ color:var(--accent); }}
  .cierre {{ background:var(--surface); border:1px solid var(--line); border-radius:var(--radius);
    padding:32px 28px; text-align:center; }}
  .btn {{ display:inline-block; background:var(--accent); color:#fff; text-decoration:none;
    padding:13px 24px; border-radius:9px; font-weight:600; }}
  footer {{ padding:34px 0 60px; color:var(--muted); font-size:14px; border-top:1px solid var(--line); }}
  footer a {{ color:var(--muted); }}
</style>
</head>
<body>

<header class="wrap">
  <a class="brand" href="/">ETA<span>Check</span></a>
  <a class="volver" href="/">← Volver</a>
</header>

<div class="wrap">

  <p class="eyebrow">Estudio abierto · {periodo}</p>
  <h1>El margen que tu ETA necesita no es un número</h1>
  <p class="lead">Tomamos {viajes} comparaciones sobre viajes que de verdad ocurrieron —hora de
     salida y duración exacta, publicados como datos abiertos— y le preguntamos a dos de las
     fuentes de ruteo más usadas del mercado qué habrían predicho para ese mismo instante.
     Esto es lo que salió.</p>

  <div class="hero">
    <div class="big">×{m_min} a ×{m_max}</div>
    <p>es el margen que cada corredor necesita para cumplirle al 90%, medido en
       {corredores} corredores de <strong>una misma ciudad</strong>. Un margen plano queda corto
       en un extremo y regala capacidad en el otro.</p>
  </div>

  <section>
    <h2>Las cifras</h2>
    <div class="scroll">
      <table>
        <thead><tr><th>Fuente</th><th class="num">Viajes</th><th class="num">Error medio</th>
          <th class="num">Sesgo</th><th class="num">Llegan tarde</th>
          <th class="num">Margen 90%</th><th class="num">Margen 95%</th></tr></thead>
        <tbody>
{filas_fuente}
        </tbody>
      </table>
    </div>
    <p><strong>Cómo se lee.</strong> El sesgo <em>positivo</em> significa que el viaje tomó más
       tiempo del prometido: la fuente es optimista. El margen es por cuánto hay que multiplicar el
       ETA para que solo uno de cada diez viajes se salga de la ventana; ×1,30 quiere decir que
       donde el proveedor promete 30 minutos, la promesa segura son 39.</p>
    <p>El error medio contra el reloj queda entre {error_min}% y {error_max}%. Ese es el piso real
       en un viaje urbano de más de media hora, y conviene saberlo antes de comprometer una ventana
       de quince minutos.</p>
  </section>

  <section>
    <h2>Corredor por corredor, en la misma ciudad</h2>
    <p>Acá está el hallazgo que decide todo lo demás. Los {corredores} corredores salen del
       <strong>mismo punto</strong> —el aeropuerto— hacia distintos destinos de la ciudad, medidos
       con la misma fuente y en el mismo período. Los viajes largos de los datos abiertos son
       justamente de esa familia, y eso conviene para comparar: cambia el destino y nada más.</p>
    <div class="scroll">
      <table>
        <thead><tr><th>Corredor</th><th class="num">Viajes</th>
          <th class="num">Exceden el ETA</th><th class="num">Margen para 90%</th></tr></thead>
        <tbody>
{filas_corredor}
        </tbody>
      </table>
    </div>
    <p>Del ×{m_min} al ×{m_max}. Mismo origen, misma ciudad, mismo mes, misma fuente de ruteo:
       lo único que cambia es a dónde va el viaje. Y no hay forma de saber qué corredor pide
       ×{m_max} y cuál ×{m_min} sin medirlos. <strong>Un margen promedio es la peor decisión
       posible: falla donde importa y sobra donde no.</strong></p>
  </section>

  <section>
    <h2>Y cambia con la hora</h2>
    <div class="scroll">
      <table>
        <thead>
          <tr><th rowspan="2">Franja</th>{cab_franjas}</tr>
          <tr>{sub_franjas}</tr>
        </thead>
        <tbody>
{cuerpo_franjas}
        </tbody>
      </table>
    </div>
    <p>Solo se muestran las franjas con doce comparaciones o más; las demás quedan en blanco porque
       con menos datos la cifra es ruido. Un margen plano se pierde de los dos lados: queda corto en
       la franja mala e infla la promesa en la buena.</p>
  </section>

  <section>
    <h2>Lo que probamos y no funcionó</h2>
    <div class="nota">
      <p><strong>Corregir el ETA no baja el error.</strong> Calculamos el factor de corrección de
         cada corredor con su historia y lo aplicamos a la predicción siguiente: el error medio no
         mejoró. La razón es que la dispersión dentro de un mismo corredor es mayor que el sesgo,
         y un factor corrige sesgo, no varianza. Recentra la predicción —los viajes que exceden el
         ETA se acercan a la mitad, que es lo que debería ser una estimación honesta— pero no
         aprieta la distribución.</p>
    </div>
    <p>De ahí la conclusión que nos obliga a vender otra cosa: <strong>no se puede prometer una
       ventana más apretada; se puede saber cuál es la ventana correcta.</strong> Multiplicar un
       ETA por un número no cambia su percentil 90, así que quien te ofrezca bajar el error a la
       mitad con un factor no lo ha medido contra viajes reales.</p>
    <p>Los viajes cortos, además, no sirven como verdad: bajo 25 minutos el ruido de la medición
       —el redondeo de la hora, la maniobra de subida y bajada— se come la señal. Todo lo de arriba
       está calculado sobre viajes de más de 25 minutos y más de 8 millas.</p>
  </section>

  <section>
    <h2>Los límites de este estudio</h2>
    <ul>
      <li><strong>Es Chicago, no tu ciudad.</strong> Los viajes públicos con hora y duración exacta
          existen ahí. Y el propio estudio muestra que el margen cambia de corredor a corredor, así
          que estos números no son tus números por construcción: son la prueba de que el problema
          existe, de que se puede medir, y de que copiar el margen de otro es una apuesta.</li>
      <li><strong>Son corredores entre el aeropuerto y la ciudad</strong>, de más de 25 minutos.
          Es la familia de viajes largos que los datos abiertos permiten aislar con hora y duración
          exactas. En reparto urbano los trayectos son más cortos y más revueltos, así que ahí la
          dispersión es mayor, no menor.</li>
      <li><strong>Son viajes de taxi</strong>, que incluyen la maniobra de recogida y bajada. Eso
          suma algunos minutos que ningún ruteo puede predecir, así que el error medio de acá es un
          techo: con tus propios registros de flota sale más limpio.</li>
      <li><strong>La hora de salida viene redondeada</strong> al cuarto de hora por privacidad, así
          que la predicción se pide con hasta siete minutos de desfase.</li>
      <li><strong>El origen y el destino son centroides</strong> de sector censal, no direcciones.
          Descartamos toda observación donde la distancia predicha se aparta más de 12% de la
          recorrida, porque ahí no es el mismo viaje.</li>
      <li><strong>No nombramos a las dos fuentes</strong> ni publicamos ninguna respuesta suya.
          Lo que está acá es un agregado calculado por nosotros.</li>
    </ul>
  </section>

  <section>
    <div class="cierre">
      <h2>¿Y cuál es el margen en tus rutas?</h2>
      <p>Mido tu corredor dos semanas sin costo y te entrego esta misma tabla con tus rutas y tus
         franjas. Si tienes los tiempos reales de algunos viajes, el informe pasa de describir el
         corredor a medir a tu proveedor.</p>
      <a class="btn" href="mailto:contacto@etacheck.cl?subject=Quiero%20el%20margen%20de%20mis%20rutas">Escribir a contacto@etacheck.cl</a>
    </div>
  </section>

</div>

<footer class="wrap">
  Actualizado el {actualizado} · <a href="/metodo">El método</a> ·
  <a href="/santiago">Santiago medido</a> · <a href="/ejemplo">Informe de ejemplo</a> ·
  <a href="mailto:contacto@etacheck.cl">contacto@etacheck.cl</a>
</footer>

</body>
</html>
"""


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="truth-chicago-largos.sqlite")
    ap.add_argument("--out", default="site")
    ap.add_argument("--desfase", type=float, default=0.12)
    a = ap.parse_args()
    build(a.db, a.out, a.desfase)
