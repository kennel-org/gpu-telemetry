#!/usr/bin/env bash
set -euo pipefail

INTERVAL_SEC="${1:-5}"
REPO_DIR="${HOME}/projects/gpu-telemetry"
UV="${REPO_DIR}/bin/uv.sh"

# Backstop above collect_once.py's own SSH timeouts, in case uv or the DB hangs.
COLLECT_TIMEOUT_SEC="${COLLECT_TIMEOUT_SEC:-45}"

echo "[INFO] Using uv: ${UV}" >&2
"${UV}" run python -c "import dotenv, psycopg; print('[INFO] deps ok')"

# Load .env to pick up REMOTE_HOSTS
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
    set +a
fi

collect() {
    timeout "${COLLECT_TIMEOUT_SEC}" "${UV}" run "${REPO_DIR}/bin/collect_once.py" "$@" || true
}

while true; do
    start=${SECONDS}

    # Collect every host concurrently. Sequentially, one slow or unreachable host
    # delayed every other host's sample by its full timeout.
    collect &
    for rhost in ${REMOTE_HOSTS:-}; do
        collect --remote-host "${rhost}" &
    done
    wait || true

    # Sleep the remainder so the sample period is INTERVAL_SEC, not
    # INTERVAL_SEC + however long collection took.
    elapsed=$(( SECONDS - start ))
    remaining=$(( INTERVAL_SEC - elapsed ))
    if (( remaining > 0 )); then
        sleep "${remaining}"
    fi
done
