# gpu-telemetry

GPU telemetry collector for Linux hosts with NVIDIA GPUs.
This repo stores telemetry in PostgreSQL and provides helper scripts to run `gpu-burn` with telemetry status tagging.

Primary use case: continuous GPU temperature monitoring on Minisforum X1 AI + DEG1 eGPU + Tesla P40 × 2, especially during stress tests such as `gpu-burn`. Supports multi-GPU configurations — each GPU is collected and stored independently.

## What this repository provides

- Telemetry collection based on `nvidia-smi`
- PostgreSQL schema (`sql/001_init.sql`)
- Spooling to local files when the DB is unavailable (`spool/`)
- Helper wrapper to run `gpu-burn` while tagging telemetry status (`bin/run_gpuburn.sh`)

> Note: This repo does **not** include the `gpu-burn` source code. It expects a built `gpu_burn` binary in `~/projects/gpu-burn`.

## What is stored

One row per GPU per sample, in `telemetry.gpu_telemetry`:

| Column | Description |
|---|---|
| `ts`, `host`, `gpu_uuid` | Primary key |
| `pci_bus_id`, `gpu_name` | GPU identity |
| `temp_c` | Temperature (°C) |
| `gpu_util_pct`, `mem_util_pct` | Utilisation (%) |
| `mem_used_mib`, `mem_total_mib` | VRAM |
| `power_w`, `fan_pct`, `sm_clock_mhz`, `perf_state` | Power / fan / clock / P-state |
| `processes` | jsonb: what is running on the GPU — `[{"pid","type","name","used_mib"}, ...]` (`type` C = compute, G = graphics) |
| `status_tag`, `status_memo` | Operator-set tag from `status.json` |
| `raw_json` | Full `nvidia-smi -q -x` snapshot, kept verbatim |

## Read operations docs

- Operations: `docs/operations.en.md`

## Directory layout (summary)

- `bin/collect_once.py` (collect once and insert into PostgreSQL; spool on failure)
- `bin/collect_loop.sh` (run collector in a loop)
- `bin/flush_spool.py` (flush spooled payloads to PostgreSQL)
- `bin/set_status.sh` (update `status.json`)
- `bin/run_gpuburn.sh` (run `gpu-burn` + status tagging)
- `bin/init_db.sh` (apply schema)
- `bin/host_healthcheck.sh` (host sanity info)
- `sql/001_init.sql`, `sql/002_add_metric_columns.sql` (schema; applied in order by `init_db.sh`)
- `bin/nvsmi_parse.py` (parse `nvidia-smi -q -x` into the metric columns)
- `bin/backfill_metrics.py` (fill metric columns on rows collected before they existed)

## License

MIT. See `LICENSE`.
