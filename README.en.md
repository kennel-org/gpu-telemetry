# gpu-telemetry

GPU telemetry collector for Linux hosts with NVIDIA GPUs.
This repo stores telemetry in PostgreSQL and provides helper scripts to run `gpu-burn` with telemetry status tagging.

Primary use case: continuous GPU temperature monitoring on Minisforum X1 AI + DEG1 eGPU + Tesla P40, especially during stress tests such as `gpu-burn`.

## What this repository provides

- Telemetry collection based on `nvidia-smi`
- PostgreSQL schema (`sql/001_init.sql`)
- Spooling to local files when the DB is unavailable (`spool/`)
- Helper wrapper to run `gpu-burn` while tagging telemetry status (`bin/run_gpuburn.sh`)

> Note: This repo does **not** include the `gpu-burn` source code. It expects a built `gpu_burn` binary in `~/projects/gpu-burn`.

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
- `sql/001_init.sql` (schema)

## License

MIT. See `LICENSE`.
