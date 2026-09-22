#!/bin/bash
# Barrido de TomTom y Mapbox cada 30 min. Claves en ~/trafficlens-sweep/.env
cd "$HOME/trafficlens-sweep"
set -a; . ./.env; set +a
exec python3 server-sweep.py --db calib-global.sqlite >> sweep.log 2>&1
