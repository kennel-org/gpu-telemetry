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

echo "[INFO] Applying initial schema to db=${PGDATABASE} ..."
psql "${CONNINFO}" -v ON_ERROR_STOP=1 -f "${HOME}/projects/gpu-telemetry/sql/001_init.sql"
echo "[INFO] Done."
