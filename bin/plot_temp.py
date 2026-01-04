#!/usr/bin/env python3
import argparse
import os
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv


REPO_DIR = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Row:
    ts: datetime
    host: str
    gpu_uuid: str
    pci_bus_id: str
    gpu_name: str | None
    temp_c: int
    status_tag: str | None
    status_memo: str | None


JST = timezone(timedelta(hours=9))


def _to_tz(dt: datetime, tz_name: str) -> datetime:
    if tz_name.lower() == "utc":
        return dt.astimezone(timezone.utc)
    if tz_name.lower() == "jst":
        return dt.astimezone(JST)
    raise ValueError("--tz must be 'utc' or 'jst'")


def _parse_iso8601(s: str) -> datetime:
    s2 = s.strip()
    if s2.endswith("Z"):
        s2 = s2[:-1] + "+00:00"
    dt = datetime.fromisoformat(s2)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _build_dsn() -> str:
    return (
        f"host={os.environ['PGHOST']} "
        f"port={os.environ['PGPORT']} "
        f"dbname={os.environ['PGDATABASE']} "
        f"user={os.environ['PGUSER']} "
        f"password={os.environ['PGPASSWORD']} "
        f"sslmode={os.environ.get('PGSSLMODE', 'prefer')}"
    )


def fetch_rows(
    *,
    start: datetime,
    end: datetime,
    host: str | None,
    status_tag: str | None,
    exclude_status_tags: list[str] | None,
    include_memos: list[str] | None,
    exclude_memos: list[str] | None,
) -> list[Row]:
    dsn = _build_dsn()

    where = ["ts >= %(start)s", "ts <= %(end)s", "temp_c is not null"]
    params: dict[str, object] = {"start": start, "end": end}

    if host:
        where.append("host = %(host)s")
        params["host"] = host

    if status_tag:
        where.append("status_tag = %(status_tag)s")
        params["status_tag"] = status_tag

    if exclude_status_tags:
        placeholders: list[str] = []
        for i, t in enumerate(exclude_status_tags):
            k = f"ex{i}"
            placeholders.append(f"%({k})s")
            params[k] = t
        # Keep NULLs, exclude only matching tags
        where.append(f"(status_tag is null or status_tag not in ({', '.join(placeholders)}))")

    if include_memos:
        memo_clauses: list[str] = []
        for i, s in enumerate(include_memos):
            k = f"im{i}"
            memo_clauses.append(f"status_memo ilike %({k})s")
            params[k] = f"%{s}%"
        where.append(f"({' or '.join(memo_clauses)})")

    if exclude_memos:
        memo_clauses = []
        for i, s in enumerate(exclude_memos):
            k = f"em{i}"
            memo_clauses.append(f"status_memo not ilike %({k})s")
            params[k] = f"%{s}%"
        # Keep NULLs, exclude only matching memos
        where.append(f"(status_memo is null or ({' and '.join(memo_clauses)}))")

    sql = (
        "select ts, host, gpu_uuid, pci_bus_id, gpu_name, temp_c, status_tag, status_memo "
        "from telemetry.gpu_telemetry "
        f"where {' and '.join(where)} "
        "order by ts asc"
    )

    out: list[Row] = []
    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            for ts, host2, gpu_uuid, pci_bus_id, gpu_name, temp_c, status_tag2, status_memo2 in cur.fetchall():
                out.append(
                    Row(
                        ts=ts,
                        host=host2,
                        gpu_uuid=gpu_uuid,
                        pci_bus_id=pci_bus_id,
                        gpu_name=gpu_name,
                        temp_c=int(temp_c),
                        status_tag=status_tag2,
                        status_memo=status_memo2,
                    )
                )
    return out


def plot(rows: list[Row], out_path: Path, title: str | None) -> None:
    import matplotlib

    matplotlib.use("Agg")

    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    out_path.parent.mkdir(parents=True, exist_ok=True)

    by_gpu: dict[str, list[Row]] = defaultdict(list)
    for r in rows:
        by_gpu[r.gpu_uuid].append(r)

    fig, ax = plt.subplots(figsize=(12, 5))

    status_colors: dict[str, str] = {
        "idle": "#4C78A8",
        "prod": "#F58518",
        "bench": "#E45756",
        "unknown": "#8E8E8E",
    }

    # Background bands for status transitions (across all rows)
    if rows:
        rows_sorted = sorted(rows, key=lambda r: r.ts)
        cur_status = rows_sorted[0].status_tag or "unknown"
        seg_start = rows_sorted[0].ts
        segments: list[tuple[datetime, datetime, str]] = []
        for r in rows_sorted[1:]:
            st = r.status_tag or "unknown"
            if st != cur_status:
                segments.append((seg_start, r.ts, cur_status))
                seg_start = r.ts
                cur_status = st
        segments.append((seg_start, rows_sorted[-1].ts, cur_status))

        for a, b, st in segments:
            c = status_colors.get(st, status_colors["unknown"])
            ax.axvspan(a, b, color=c, alpha=0.08, linewidth=0)

    if not rows:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", transform=ax.transAxes)
    else:
        # Use distinct line colors per GPU, but keep status in the background.
        color_cycle = list(plt.get_cmap("tab10").colors)
        for gpu_uuid, rs in sorted(by_gpu.items(), key=lambda kv: kv[0]):
            xs = [r.ts for r in rs]
            ys = [r.temp_c for r in rs]
            label_name = rs[0].gpu_name or "GPU"
            label = f"{label_name} ({rs[0].pci_bus_id})"

            c = color_cycle[hash(gpu_uuid) % len(color_cycle)]
            ax.plot(xs, ys, linewidth=1.8, color=c, alpha=0.95, label=label)

    ax.set_ylabel("Temperature (°C)")
    ax.set_ylim(10, 100)
    ax.grid(True, alpha=0.3)

    ax.xaxis.set_major_locator(mdates.AutoDateLocator(minticks=3, maxticks=10))
    ax.xaxis.set_major_formatter(mdates.ConciseDateFormatter(ax.xaxis.get_major_locator()))

    if title:
        ax.set_title(title)

    if rows:
        gpu_handles, gpu_labels = ax.get_legend_handles_labels()
        status_handles = [
            Patch(facecolor=status_colors["idle"], alpha=0.18, label="idle"),
            Patch(facecolor=status_colors["prod"], alpha=0.18, label="prod"),
            Patch(facecolor=status_colors["bench"], alpha=0.18, label="bench"),
        ]
        ax.legend(
            gpu_handles + status_handles,
            gpu_labels + ["idle", "prod", "bench"],
            loc="upper left",
            fontsize="small",
            framealpha=0.9,
        )

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)


def main() -> None:
    ap = argparse.ArgumentParser(description="Plot GPU temperature from telemetry.gpu_telemetry")
    ap.add_argument("--env", default=str(REPO_DIR / ".env"), help="Path to .env (default: repo/.env)")
    ap.add_argument("--out", default=str(REPO_DIR / "docs/images/gpu-temp.png"), help="Output PNG path")

    t = ap.add_mutually_exclusive_group(required=False)
    t.add_argument("--hours", type=float, help="Plot last N hours (UTC)")
    t.add_argument("--start", help="Start time (ISO8601; e.g. 2026-01-04T00:00:00+09:00)")

    ap.add_argument("--end", help="End time (ISO8601). Used with --start. Default: now (UTC)")
    ap.add_argument("--host", help="Filter by host")
    ap.add_argument("--status-tag", help="Filter by status_tag (idle/prod/bench)")
    ap.add_argument(
        "--exclude-status-tag",
        action="append",
        default=[],
        help="Exclude rows with this status_tag (repeatable). NULL status_tag rows are kept.",
    )
    ap.add_argument(
        "--exclude-prod",
        action="store_true",
        help="Exclude status_tag=prod (useful to focus on benchmark/non-prod ranges)",
    )
    ap.add_argument(
        "--include-memo",
        action="append",
        default=[],
        help="Include only rows whose status_memo contains this substring (case-insensitive; repeatable)",
    )
    ap.add_argument(
        "--exclude-memo",
        action="append",
        default=[],
        help="Exclude rows whose status_memo contains this substring (case-insensitive; repeatable). NULL status_memo rows are kept.",
    )
    ap.add_argument("--tz", default="jst", help="Timezone for x-axis and title (jst|utc). Default: jst")
    ap.add_argument("--title", help="Plot title")

    args = ap.parse_args()

    env_path = Path(args.env)
    load_dotenv(env_path)

    if args.hours is not None:
        end = datetime.now(timezone.utc)
        start = end - timedelta(hours=float(args.hours))
    elif args.start is not None:
        start = _parse_iso8601(args.start)
        if args.end:
            end = _parse_iso8601(args.end)
        else:
            end = datetime.now(timezone.utc)
    else:
        end = datetime.now(timezone.utc)
        start = end - timedelta(hours=6)

    exclude_tags = list(args.exclude_status_tag or [])
    if args.exclude_prod and "prod" not in exclude_tags:
        exclude_tags.append("prod")

    rows = fetch_rows(
        start=start,
        end=end,
        host=args.host,
        status_tag=args.status_tag,
        exclude_status_tags=exclude_tags,
        include_memos=list(args.include_memo or []),
        exclude_memos=list(args.exclude_memo or []),
    )

    start_local = _to_tz(start, args.tz)
    end_local = _to_tz(end, args.tz)

    # Convert timestamps for plotting
    rows_local = [
        Row(
            ts=_to_tz(r.ts, args.tz),
            host=r.host,
            gpu_uuid=r.gpu_uuid,
            pci_bus_id=r.pci_bus_id,
            gpu_name=r.gpu_name,
            temp_c=r.temp_c,
            status_tag=r.status_tag,
            status_memo=r.status_memo,
        )
        for r in rows
    ]

    title = args.title
    if not title:
        base = "GPU temperature"
        if args.status_tag:
            base = f"{base} ({args.status_tag})"
        if exclude_tags:
            base = f"{base} (exclude: {','.join(exclude_tags)})"
        if args.include_memo:
            base = f"{base} (memo: {','.join(args.include_memo)})"
        if args.exclude_memo:
            base = f"{base} (memo-exclude: {','.join(args.exclude_memo)})"
        title = (
            f"{base}\n"
            f"{args.tz.upper()}: {start_local.isoformat(timespec='seconds')} - {end_local.isoformat(timespec='seconds')}"
        )

    plot(rows_local, Path(args.out), title)

    print(
        f"[INFO] wrote: {args.out} rows={len(rows)} "
        f"utc={start.isoformat(timespec='seconds')}..{end.isoformat(timespec='seconds')} "
        f"{args.tz.lower()}={start_local.isoformat(timespec='seconds')}..{end_local.isoformat(timespec='seconds')}"
    )


if __name__ == "__main__":
    main()
