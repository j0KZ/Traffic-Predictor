#!/usr/bin/env python3
"""Agente de correo: lee, clasifica, archiva y deja borradores. Nunca envía.

Corre en el servidor por IMAP, sin depender de Gmail ni de ningún conector.
Clasifica con Ollama si está disponible; si no, con reglas. El borrador
queda en Borradores con la marca \\Draft: se revisa desde cualquier cliente
de correo y se envía a mano.

Configuración, en el .env del servidor:
    MAIL_HOST=imap.zoho.com
    MAIL_USER=contacto@dominio.cl
    MAIL_PASS=...            # contraseña de aplicación, no la principal
    OLLAMA_URL=http://127.0.0.1:11434   # opcional
    OLLAMA_MODEL=hermes3                # opcional

Uso: mail-agent.py [--dry-run] [--limit 20]
"""
import argparse
import email
import email.utils
import imaplib
import json
import os
import re
import sys
import urllib.request
from email.message import EmailMessage

CARPETAS = ["Leads/Nuevo", "Leads/Midiendo", "Leads/Informe", "Leads/Cerrado"]

# Señales de que alguien quiere la medición. El modelo decide mejor, pero
# esto tiene que funcionar igual si Ollama está caído.
PALABRAS_LEAD = [
    "medici", "corredor", "ruta", "eta", "entrega", "flota", "reparto",
    "tiempo de viaje", "auditor", "cotiza", "informaci", "interesa",
]

PROMPT = """Clasifica este correo en UNA categoría:

lead: alguien interesado en medir sus rutas o en el servicio de precisión de ETA
datos: un interesado que ENVÍA los datos de su corredor o sus viajes reales
otro: cualquier otra cosa (spam, facturas, boletines, personal)

Responde SOLO con un JSON: {{"categoria": "...", "empresa": "...", "resumen": "..."}}
empresa es el nombre de la empresa si aparece, o "" si no.
resumen es una línea de qué pide.

Asunto: {asunto}
De: {remitente}

{cuerpo}
"""

RESPUESTA_LEAD = """Hola:

Gracias por escribir.

Para partir con la medición necesito tres cosas:

1. Origen y destino del corredor (dirección o coordenadas).
2. El horario en que operan esa ruta.
3. Cuántos viajes hacen por día en ella.

Con eso lo doy de alta hoy y en dos semanas les mando el informe, sin costo.

Si además me pueden compartir los tiempos reales de algunos viajes ya hechos
—hora de salida y duración, un CSV basta—, el informe pasa de describir el
corredor a medir el error exacto de su proveedor actual. Es la diferencia
entre una foto y una auditoría.

Saludos,
"""

RESPUESTA_DATOS = """Hola:

Recibido, gracias.

Doy de alta el corredor hoy y empieza a medirse cada 30 minutos. En dos
semanas les llega el informe con el desglose por franja horaria.

Si en el intertanto aparecen más viajes reales para comparar, mándenlos y
los incorporo.

Saludos,
"""


def ollama(texto):
    url = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    model = os.environ.get("OLLAMA_MODEL", "hermes3")
    req = urllib.request.Request(
        f"{url}/api/generate",
        data=json.dumps({"model": model, "prompt": texto, "stream": False,
                         "format": "json", "options": {"temperature": 0}}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(json.loads(r.read())["response"])


def cuerpo_de(msg, limite=2000):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                return part.get_payload(decode=True).decode(errors="replace")[:limite]
        return ""
    payload = msg.get_payload(decode=True)
    return payload.decode(errors="replace")[:limite] if payload else ""


def clasificar(asunto, remitente, cuerpo):
    try:
        r = ollama(PROMPT.format(asunto=asunto, remitente=remitente, cuerpo=cuerpo))
        if r.get("categoria") in ("lead", "datos", "otro"):
            return r["categoria"], r.get("empresa", ""), r.get("resumen", "")
    except Exception as e:
        print(f"  (ollama no disponible: {e.__class__.__name__}; uso reglas)", file=sys.stderr)
    texto = f"{asunto} {cuerpo}".lower()
    if re.search(r"\b-?\d{1,2}\.\d{3,},\s*-?\d{1,3}\.\d{3,}", texto) or ".csv" in texto:
        return "datos", "", "trae coordenadas o un archivo de viajes"
    if any(p in texto for p in PALABRAS_LEAD):
        return "lead", "", "consulta por el servicio"
    return "otro", "", ""


def borrador(original, texto):
    m = EmailMessage()
    m["To"] = original.get("Reply-To") or original.get("From")
    m["From"] = os.environ["MAIL_USER"]
    asunto = original.get("Subject", "")
    m["Subject"] = asunto if asunto.lower().startswith("re:") else f"Re: {asunto}"
    if original.get("Message-ID"):
        m["In-Reply-To"] = original["Message-ID"]
        m["References"] = original["Message-ID"]
    m.set_content(texto)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=20)
    a = ap.parse_args()

    for v in ("MAIL_HOST", "MAIL_USER", "MAIL_PASS"):
        if not os.environ.get(v):
            sys.exit(f"falta {v} en el entorno")

    M = imaplib.IMAP4_SSL(os.environ["MAIL_HOST"])
    M.login(os.environ["MAIL_USER"], os.environ["MAIL_PASS"])
    for c in CARPETAS:
        M.create(c)   # si ya existe, IMAP responde NO y seguimos

    M.select("INBOX")
    _, data = M.search(None, "UNSEEN")
    ids = data[0].split()[: a.limit]
    print(f"{len(ids)} correo(s) sin leer")

    for num in ids:
        _, d = M.fetch(num, "(RFC822)")
        msg = email.message_from_bytes(d[0][1])
        asunto = str(email.header.make_header(email.header.decode_header(msg.get("Subject", ""))))
        remitente = msg.get("From", "")
        cat, empresa, resumen = clasificar(asunto, remitente, cuerpo_de(msg))
        etiqueta = f"[{cat}]" + (f" {empresa}" if empresa else "")
        print(f"  {etiqueta:22} {remitente[:38]:38} {asunto[:40]}")
        if resumen:
            print(f"    → {resumen}")

        if cat == "otro" or a.dry_run:
            continue

        texto = RESPUESTA_LEAD if cat == "lead" else RESPUESTA_DATOS
        M.append("Drafts", "\\Draft", None, borrador(msg, texto).as_bytes())
        destino = "Leads/Nuevo" if cat == "lead" else "Leads/Midiendo"
        M.copy(num, destino)
        M.store(num, "+FLAGS", "\\Seen")

    M.logout()
    if a.dry_run:
        print("\n(dry-run: no se escribió ningún borrador)")


if __name__ == "__main__":
    main()
