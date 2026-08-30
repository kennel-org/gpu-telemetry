#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${HOME}/projects/gpu-telemetry/.env"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${PGHOST:?}" "${PGPORT:?}" "${PGDATABASE:?}" "${PGUSER:?}" "${PGPASSWORD:?}"
PGSSLMODE="${PGSSLMODE:-prefer}"

CONNINFO="host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} sslmode=${PGSSLMODE}"

# Every file in sql/ is idempotent (IF NOT EXISTS), so applying them all in
# order both initialises a fresh DB and migrates an existing one.
for f in "${HOME}"/projects/gpu-telemetry/sql/*.sql; do
    echo "[INFO] Applying $(basename "${f}") to db=${PGDATABASE} ..."
    psql "${CONNINFO}" -v ON_ERROR_STOP=1 -f "${f}"
done
echo "[INFO] Done."
