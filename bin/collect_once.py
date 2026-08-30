#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import socket
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv

from nvsmi_parse import EMPTY_METRICS, METRIC_COLUMNS, metrics_by_uuid

REPO_DIR = Path(__file__).resolve().parent.parent
STATUS_FILE = REPO_DIR / "status.json"
SPOOL_DIR = REPO_DIR / "spool"

# WSL2 hosts keep nvidia-smi under /usr/lib/wsl/lib/ which is often absent from PATH
_NVIDIA_SMI_DETECT = (
    "command -v nvidia-smi 2>/dev/null || echo /usr/lib/wsl/lib/nvidia-smi"
)

# Without these, an unreachable host blocks on the OS TCP timeout (~130 s), which
# stalls the whole sampling loop. Observed on 2026-08-30: the sample interval
# collapsed from 5 s to ~144 s while one remote host was being renamed in Tailscale.
SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
]
# Backstop for a host that accepts the connection but never answers.
REMOTE_TIMEOUT_SEC = 20


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True).strip()


def run_remote(args: list[str], remote_host: str) -> str:
    args_str = " ".join(shlex.quote(a) for a in args)
    # Pass a single shell string so SSH doesn't split it on spaces before sending
    shell_cmd = f'NSMI=$({_NVIDIA_SMI_DETECT}); "$NSMI" {args_str}'
    return subprocess.check_output(
        ["ssh", *SSH_OPTS, remote_host, shell_cmd],
        text=True,
        timeout=REMOTE_TIMEOUT_SEC,
    ).strip()


def load_status() -> tuple[str | None, str | None]:
    try:
        obj = json.loads(STATUS_FILE.read_text(encoding="utf-8"))
        return obj.get("tag"), obj.get("memo")
    except Exception:
        return None, None


def atomic_write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def build_payload(remote_host: str | None = None) -> dict:
    if remote_host:
        nvidia_smi = lambda args: run_remote(args, remote_host)
        host = remote_host
    else:
        nvidia_smi = lambda args: run(["nvidia-smi"] + args)
        host = socket.gethostname()

    ts = datetime.now(timezone.utc)
    status_tag, status_memo = load_status()

    # Lightweight fields (fast)
    q = "uuid,pci.bus_id,name,temperature.gpu"
    out = nvidia_smi([f"--query-gpu={q}", "--format=csv,noheader,nounits"])

    gpus = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != 4:
            continue
        gpu_uuid, pci_bus_id, gpu_name, temp_s = parts
        try:
            temp_c = int(temp_s)
        except ValueError:
            temp_c = None
        gpus.append(
            {
                "gpu_uuid": gpu_uuid,
                "pci_bus_id": pci_bus_id,
                "gpu_name": gpu_name,
                "temp_c": temp_c,
            }
        )

    # Heavy raw snapshot (kept as XML string inside JSON)
    raw_xml = nvidia_smi(["-q", "-x"])
    raw_obj = {"nvidia_smi_q_x": raw_xml}

    # Promote the queryable metrics out of the XML so Grafana can read columns
    # instead of parsing a 30 KB string per row.
    by_uuid = metrics_by_uuid(raw_xml)
    for gpu in gpus:
        gpu.update(by_uuid.get(gpu["gpu_uuid"], EMPTY_METRICS))

    return {
        "ts": ts.isoformat(),
        "host": host,
        "status_tag": status_tag,
        "status_memo": status_memo,
        "gpus": gpus,
        "raw_json": raw_obj,
    }


def metric_values(gpu: dict) -> tuple:
    """Metric column values for one GPU, in METRIC_COLUMNS order."""
    return tuple(
        json.dumps(gpu[col], ensure_ascii=False) if col == "processes" and gpu.get(col) is not None
        else gpu.get(col)
        for col in METRIC_COLUMNS
    )


def insert_payload(payload: dict) -> None:
    dsn = (
        f"host={os.environ['PGHOST']} "
        f"port={os.environ['PGPORT']} "
        f"dbname={os.environ['PGDATABASE']} "
        f"user={os.environ['PGUSER']} "
        f"password={os.environ['PGPASSWORD']} "
        f"sslmode={os.environ.get('PGSSLMODE', 'prefer')}"
    )

    ts = datetime.fromisoformat(payload["ts"].replace("Z", "+00:00"))

    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            for g in payload["gpus"]:
                cur.execute(
                    """
                    insert into telemetry.gpu_telemetry
                      (ts, host, gpu_uuid, pci_bus_id, gpu_name, temp_c, status_tag, status_memo, raw_json,
                       gpu_util_pct, mem_util_pct, mem_used_mib, mem_total_mib, power_w,
                       fan_pct, sm_clock_mhz, perf_state, processes)
                    values
                      (%s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb,
                       %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
                    on conflict (ts, host, gpu_uuid) do nothing
                    """,
                    (
                        ts,
                        payload["host"],
                        g["gpu_uuid"],
                        g["pci_bus_id"],
                        g["gpu_name"],
                        g["temp_c"],
                        payload["status_tag"],
                        payload["status_memo"],
                        json.dumps(payload["raw_json"], ensure_ascii=False),
                    )
                    + metric_values(g),
                )
        conn.commit()


def spool_payload(payload: dict, reason: str) -> Path:
    ts_safe = payload["ts"].replace(":", "").replace("-", "")
    name = f"{ts_safe}_{payload['host']}_{uuid.uuid4().hex}.json"
    path = SPOOL_DIR / name
    payload2 = dict(payload)
    payload2["_spool_reason"] = reason
    atomic_write_json(path, payload2)
    return path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Collect GPU telemetry and insert into DB")
    p.add_argument(
        "--remote-host",
        metavar="HOST",
        default=None,
        help="SSH target to collect from (omit for local collection)",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    load_dotenv(REPO_DIR / ".env")

    try:
        payload = build_payload(remote_host=args.remote_host)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        target = args.remote_host or socket.gethostname()
        print(f"[WARN] nvidia-smi collection failed for host={target}: {e}")
        raise SystemExit(1)

    try:
        insert_payload(payload)
        summary = " ".join(
            f"[{g['pci_bus_id']} {g['temp_c']}C util={g.get('gpu_util_pct')}% "
            f"mem={g.get('mem_used_mib')}MiB procs={len(g.get('processes') or [])}]"
            for g in payload["gpus"]
        )
        print(f"[INFO] {payload['ts']} host={payload['host']} status={payload['status_tag']} {summary}")
    except Exception as e:
        p = spool_payload(payload, reason=str(e))
        temp0 = payload["gpus"][0]["temp_c"] if payload["gpus"] else "NA"
        print(
            f"[WARN] DB insert failed; spooled to {p}. "
            f"ts={payload['ts']} host={payload['host']} temp={temp0}C status={payload['status_tag']} error={e}"
        )


if __name__ == "__main__":
    main()
