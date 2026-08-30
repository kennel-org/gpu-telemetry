#!/usr/bin/env python3
import os
import json
from pathlib import Path

import psycopg
from dotenv import load_dotenv

from nvsmi_parse import EMPTY_METRICS, METRIC_COLUMNS, metrics_by_uuid

REPO_DIR = Path(__file__).resolve().parent.parent
SPOOL_DIR = REPO_DIR / "spool"


def dsn_from_env() -> str:
    return (
        f"host={os.environ['PGHOST']} "
        f"port={os.environ['PGPORT']} "
        f"dbname={os.environ['PGDATABASE']} "
        f"user={os.environ['PGUSER']} "
        f"password={os.environ['PGPASSWORD']} "
        f"sslmode={os.environ.get('PGSSLMODE', 'prefer')}"
    )


def insert_payload(cur, payload: dict) -> None:
    ts = payload["ts"].replace("Z", "+00:00")
    raw_json = payload.get("raw_json", {})
    # Re-derive metrics from the snapshot rather than trusting the spool file:
    # files written before the metric columns existed carry only raw_json.
    by_uuid = metrics_by_uuid(raw_json.get("nvidia_smi_q_x", ""))

    for g in payload.get("gpus", []):
        m = by_uuid.get(g["gpu_uuid"], EMPTY_METRICS)
        metrics = tuple(
            json.dumps(m[col], ensure_ascii=False) if col == "processes" and m.get(col) is not None
            else m.get(col)
            for col in METRIC_COLUMNS
        )
        cur.execute(
            """
            insert into telemetry.gpu_telemetry
              (ts, host, gpu_uuid, pci_bus_id, gpu_name, temp_c, status_tag, status_memo, raw_json,
               gpu_util_pct, mem_util_pct, mem_used_mib, mem_total_mib, power_w,
               fan_pct, sm_clock_mhz, perf_state, processes)
            values
              (%s::timestamptz, %s, %s, %s, %s, %s, %s, %s, %s::jsonb,
               %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
            on conflict (ts, host, gpu_uuid) do nothing
            """,
            (
                ts,
                payload["host"],
                g["gpu_uuid"],
                g["pci_bus_id"],
                g.get("gpu_name"),
                g.get("temp_c"),
                payload.get("status_tag"),
                payload.get("status_memo"),
                json.dumps(raw_json, ensure_ascii=False),
            )
            + metrics,
        )


def main() -> None:
    load_dotenv(REPO_DIR / ".env")
    SPOOL_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(SPOOL_DIR.glob("*.json"))

    if not files:
        print("[INFO] No spooled files.")
        return

    dsn = dsn_from_env()

    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            sent = 0
            for f in files:
                payload = json.loads(f.read_text(encoding="utf-8"))
                try:
                    insert_payload(cur, payload)
                    conn.commit()
                    f.unlink()
                    sent += 1
                except Exception as e:
                    conn.rollback()
                    print(f"[WARN] Flush stopped at {f.name}: {e}")
                    break

    print(f"[INFO] Flushed files: {sent}")


if __name__ == "__main__":
    main()
