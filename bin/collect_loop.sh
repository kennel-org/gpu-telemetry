#!/usr/bin/env bash
set -euo pipefail

INTERVAL_SEC="${1:-5}"
REPO_DIR="${HOME}/projects/gpu-telemetry"
UV="${REPO_DIR}/bin/uv.sh"

echo "[INFO] Using uv: ${UV}" >&2
"${UV}" run python -c "import dotenv, psycopg; print('[INFO] deps ok')"

while true; do
  "${UV}" run "${REPO_DIR}/bin/collect_once.py" || true
  sleep "${INTERVAL_SEC}"
done
