#!/usr/bin/env python3
"""Receptor local de la extensión TrafficLens Waze Reader.

GET  /routes   rutas (routes/*.json + route.json) con coordenadas para Waze
POST /sweep    barre TomTom/Mapbox justo antes de leer Waze (pares < 5 min)
POST /reading  {"name","at","seconds","km"} -> trafficlens-cli reference

Uso: set -a && source .env && set +a && python3 tools/waze-receiver.py [--db calib-global.sqlite]
"""
import argparse, glob, json, os, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, ".build", "debug", "trafficlens-cli")

def route_files():
    files = {os.path.splitext(os.path.basename(f))[0]: f for f in sorted(glob.glob(os.path.join(ROOT, "routes", "*.json")))}
    files["chile"] = os.path.join(ROOT, "route.json")
    return files

def coords(p):
    return f"{p['lat']}%2C{p['lon']}"

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/routes":
            return self._send(404, {"error": "not found"})
        out = []
        for name, f in route_files().items():
            r = json.load(open(f))
            out.append({"name": name, "from": coords(r["origin"]), "to": coords(r["destination"])})
        self._send(200, out)

    def do_POST(self):
        if self.path == "/sweep":
            files = list(route_files().values())
            res = subprocess.run([CLI, "sweep", "--db", DB, "--routes", *files], capture_output=True, text=True, cwd=ROOT)
            print(res.stdout[-2000:], flush=True)
            return self._send(200 if res.returncode == 0 else 500, {"ok": res.returncode == 0})
        if self.path == "/reading":
            d = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            f = route_files().get(d["name"])
            if not f:
                return self._send(400, {"error": "ruta desconocida"})
            cmd = [CLI, "reference", "--route", f, "--db", DB, "--source", "waze",
                   "--eta", str(int(d["seconds"])), "--at", d["at"]]
            if d.get("km"):
                cmd += ["--km", str(d["km"])]
            res = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
            print(d["name"], (res.stdout or res.stderr).strip().splitlines()[-1:], flush=True)
            return self._send(200 if res.returncode == 0 else 500, {"ok": res.returncode == 0})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="calib-global.sqlite")
    ap.add_argument("--port", type=int, default=8791)
    a = ap.parse_args()
    DB = os.path.join(ROOT, a.db)
    subprocess.run(["swift", "build", "--product", "trafficlens-cli"], cwd=ROOT, check=True)
    print(f"Receptor en 127.0.0.1:{a.port}, base {DB}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
