#!/usr/bin/env python3
"""Fill the metric columns for rows collected before they existed.

The archive is ~40 GB of nvidia-smi XML, so the extraction runs server-side with
xpath/XMLTABLE rather than streaming every snapshot to this process. Work is
split into time windows, is restricted to rows whose metrics are still NULL, and
records a checkpoint after each window, so an interrupted run resumes in place.
"""
import argparse
import json
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv

REPO_DIR = Path(__file__).resolve().parent.parent
CHECKPOINT = REPO_DIR / "logs" / "backfill_metrics_checkpoint.json"

# One <gpu> subtree per row, selected by the row's own PCI bus id: raw_json holds
# the whole multi-GPU snapshot, identical on every row of the sample.
# When a GPU falls off the bus, nvidia-smi prefixes the document with a plain-text
# error line, which makes xmlparse fail for the whole window. The XML after the
# declaration is well formed, so cut back to it. Mirrors strip_prolog_noise() in
# bin/nvsmi_parse.py.
XML_TEXT = """
    CASE WHEN position('<?xml' in raw_json->>'nvidia_smi_q_x') > 1
         THEN substr(raw_json->>'nvidia_smi_q_x',
                     position('<?xml' in raw_json->>'nvidia_smi_q_x'))
         ELSE raw_json->>'nvidia_smi_q_x'
    END"""

GPU_SUBTREE = f"""(xpath('/nvidia_smi_log/gpu[@id="' || pci_bus_id || '"]',
                        xmlparse(document {XML_TEXT})))[1]"""

# nvidia-smi renders absent readings as "N/A"; drivers before ~570 named the
# power field <power_draw> instead of <instant_power_draw>.
UPDATE_SQL = f"""
-- MATERIALIZED matters: inlined, the CTE re-runs xmlparse once per xpath call,
-- which measured ~3x slower on real rows.
WITH src AS MATERIALIZED (
    SELECT ts, host, gpu_uuid, {GPU_SUBTREE} AS gx
    FROM telemetry.gpu_telemetry
    WHERE ts >= %(lo)s AND ts < %(hi)s
      AND gpu_util_pct IS NULL
      AND raw_json ? 'nvidia_smi_q_x'
), m AS MATERIALIZED (
    SELECT ts, host, gpu_uuid,
      nullif(split_part((xpath('/gpu/utilization/gpu_util/text()', gx))[1]::text, ' ', 1), 'N/A')::int      AS gpu_util_pct,
      nullif(split_part((xpath('/gpu/utilization/memory_util/text()', gx))[1]::text, ' ', 1), 'N/A')::int   AS mem_util_pct,
      nullif(split_part((xpath('/gpu/fb_memory_usage/used/text()', gx))[1]::text, ' ', 1), 'N/A')::int      AS mem_used_mib,
      nullif(split_part((xpath('/gpu/fb_memory_usage/total/text()', gx))[1]::text, ' ', 1), 'N/A')::int     AS mem_total_mib,
      nullif(split_part(coalesce(
          (xpath('/gpu/gpu_power_readings/instant_power_draw/text()', gx))[1]::text,
          (xpath('/gpu/gpu_power_readings/power_draw/text()', gx))[1]::text,
          (xpath('/gpu/power_readings/power_draw/text()', gx))[1]::text), ' ', 1), 'N/A')::numeric          AS power_w,
      nullif(split_part((xpath('/gpu/fan_speed/text()', gx))[1]::text, ' ', 1), 'N/A')::int                 AS fan_pct,
      nullif(split_part((xpath('/gpu/clocks/sm_clock/text()', gx))[1]::text, ' ', 1), 'N/A')::int           AS sm_clock_mhz,
      nullif((xpath('/gpu/performance_state/text()', gx))[1]::text, 'N/A')                                  AS perf_state,
      (SELECT jsonb_agg(jsonb_build_object(
                  'pid', pid, 'type', ptype, 'name', pname,
                  'used_mib', nullif(split_part(used, ' ', 1), 'N/A')::int) ORDER BY pid)
         FROM XMLTABLE('/gpu/processes/process_info' PASSING BY VALUE gx
                       COLUMNS pid int PATH 'pid', ptype text PATH 'type',
                               pname text PATH 'process_name', used text PATH 'used_memory'))
                                                                                                            AS processes
    FROM src
    WHERE gx IS NOT NULL
)
UPDATE telemetry.gpu_telemetry t
SET gpu_util_pct  = m.gpu_util_pct,
    mem_util_pct  = m.mem_util_pct,
    mem_used_mib  = m.mem_used_mib,
    mem_total_mib = m.mem_total_mib,
    power_w       = m.power_w,
    fan_pct       = m.fan_pct,
    sm_clock_mhz  = m.sm_clock_mhz,
    perf_state    = m.perf_state,
    processes     = coalesce(m.processes, '[]'::jsonb)
FROM m
WHERE t.ts = m.ts AND t.host = m.host AND t.gpu_uuid = m.gpu_uuid
"""


def retry_per_row(conn, lo, hi) -> tuple[int, int]:
    """Re-run one window a row at a time. Returns (rows updated, rows that failed)."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT ts, host, gpu_uuid FROM telemetry.gpu_telemetry"
            " WHERE ts >= %s AND ts < %s AND gpu_util_pct IS NULL"
            "   AND raw_json ? 'nvidia_smi_q_x'",
            (lo, hi),
        )
        keys = cur.fetchall()

    recovered = bad = 0
    for ts, host, gpu_uuid in keys:
        try:
            with conn.cursor() as cur:
                cur.execute(
                    UPDATE_SQL + " AND t.ts = %(ts)s AND t.host = %(host)s"
                                 " AND t.gpu_uuid = %(gpu_uuid)s",
                    {"lo": ts, "hi": ts + timedelta(microseconds=1),
                     "ts": ts, "host": host, "gpu_uuid": gpu_uuid},
                )
                recovered += cur.rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            bad += 1
    return recovered, bad


def dsn_from_env() -> str:
    return (
        f"host={os.environ['PGHOST']} "
        f"port={os.environ['PGPORT']} "
        f"dbname={os.environ['PGDATABASE']} "
        f"user={os.environ['PGUSER']} "
        f"password={os.environ['PGPASSWORD']} "
        f"sslmode={os.environ.get('PGSSLMODE', 'prefer')}"
    )


def parse_ts(value: str) -> datetime:
    ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def pending_range(conn) -> tuple[datetime | None, datetime | None, int]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT min(ts), max(ts), count(*) FROM telemetry.gpu_telemetry"
            " WHERE gpu_util_pct IS NULL"
        )
        return cur.fetchone()


def load_checkpoint() -> datetime | None:
    try:
        return parse_ts(json.loads(CHECKPOINT.read_text())["next_ts"])
    except Exception:
        return None


def save_checkpoint(next_ts: datetime, updated: int) -> None:
    CHECKPOINT.parent.mkdir(parents=True, exist_ok=True)
    tmp = CHECKPOINT.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(
            {
                "next_ts": next_ts.isoformat(),
                "updated_rows": updated,
                "written_at": datetime.now(timezone.utc).isoformat(),
            }
        )
    )
    tmp.replace(CHECKPOINT)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--since", type=parse_ts, help="start of range (default: oldest unfilled row)")
    p.add_argument("--until", type=parse_ts, help="end of range, exclusive (default: now)")
    p.add_argument("--batch-minutes", type=int, default=60, help="window size per UPDATE")
    p.add_argument("--resume", action="store_true", help="continue from the checkpoint file")
    p.add_argument("--dry-run", action="store_true", help="report what is pending, change nothing")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    load_dotenv(REPO_DIR / ".env")

    with psycopg.connect(dsn_from_env()) as conn:
        oldest, newest, pending = pending_range(conn)
        if not pending:
            print("[INFO] Nothing to backfill.")
            return
        print(f"[INFO] Rows with NULL metrics: {pending} over {oldest} .. {newest}")

        lo = args.since or (load_checkpoint() if args.resume else None) or oldest
        hi = args.until or (newest + timedelta(seconds=1))
        if args.dry_run:
            print(f"[INFO] Dry run: would process {lo} .. {hi}")
            return

        step = timedelta(minutes=args.batch_minutes)
        total = max(1, int((hi - lo) / step) + 1)
        start = time.perf_counter()
        updated = failed = 0

        cursor_ts, i = lo, 0
        while cursor_ts < hi:
            window_hi = min(cursor_ts + step, hi)
            i += 1
            try:
                with conn.cursor() as cur:
                    cur.execute(UPDATE_SQL, {"lo": cursor_ts, "hi": window_hi})
                    updated += cur.rowcount
                conn.commit()
            except Exception as e:
                # One unparseable snapshot aborts its whole window. Retry the window
                # row by row so only the genuinely bad samples are left behind.
                conn.rollback()
                print(f"[WARN] window {cursor_ts} .. {window_hi} failed: {e}; retrying per row")
                recovered, bad = retry_per_row(conn, cursor_ts, window_hi)
                updated += recovered
                failed += bad
                print(f"[WARN] window {cursor_ts}: recovered={recovered} unparseable={bad}")

            save_checkpoint(window_hi, updated)
            elapsed = time.perf_counter() - start
            eta = elapsed / i * (total - i)
            print(
                f"[{i}/{total}] {cursor_ts:%Y-%m-%d %H:%M} updated={updated} "
                f"elapsed={elapsed:.0f}s eta={eta:.0f}s",
                flush=True,
            )
            cursor_ts = window_hi

        print(f"[INFO] Done. updated={updated} unparseable_rows={failed} elapsed={time.perf_counter() - start:.0f}s")


if __name__ == "__main__":
    main()
