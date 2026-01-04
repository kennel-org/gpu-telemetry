#!/usr/bin/env python3
import os
import json
from pathlib import Path

import psycopg
from dotenv import load_dotenv

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
    for g in payload.get("gpus", []):
        cur.execute(
            """
            insert into telemetry.gpu_telemetry
              (ts, host, gpu_uuid, pci_bus_id, gpu_name, temp_c, status_tag, status_memo, raw_json)
            values
              (%s::timestamptz, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
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
                json.dumps(payload.get("raw_json", {}), ensure_ascii=False),
            ),
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
