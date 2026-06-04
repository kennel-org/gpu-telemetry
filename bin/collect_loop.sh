#!/usr/bin/env bash
set -euo pipefail

INTERVAL_SEC="${1:-5}"
REPO_DIR="${HOME}/projects/gpu-telemetry"
UV="${REPO_DIR}/bin/uv.sh"

echo "[INFO] Using uv: ${UV}" >&2
"${UV}" run python -c "import dotenv, psycopg; print('[INFO] deps ok')"

# Load .env to pick up REMOTE_HOSTS
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
    set +a
fi

while true; do
    # Local GPU collection
    "${UV}" run "${REPO_DIR}/bin/collect_once.py" || true

    # Remote GPU collection (space-separated SSH targets in REMOTE_HOSTS)
    for rhost in ${REMOTE_HOSTS:-}; do
        "${UV}" run "${REPO_DIR}/bin/collect_once.py" --remote-host "${rhost}" || true
    done

    sleep "${INTERVAL_SEC}"
done
