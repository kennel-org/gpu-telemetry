# Operations (Runbook for X1 AI + DEG1 eGPU + Tesla P40 Temperature Monitoring)

This document is a zero-based runbook for collecting GPU telemetry (focused on temperature) on a Minisforum X1 AI with a Tesla P40 connected via a DEG1 eGPU dock.

## Goal

- `nvidia-smi` can see the GPU
- Telemetry is continuously inserted into PostgreSQL (spool to `spool/` when DB is down; flush after recovery)
- Run `gpu-burn` and confirm temperature increase is recorded in DB

## Hardware (BOM)

- **Host**: Minisforum X1 AI
- **eGPU dock**: DEG1 eGPU
- **GPU**: NVIDIA Tesla P40
- **PSU**: Kuroutoshikou 600W ATX PSU ¥4598-
  - Price as of Dec 2025

## Prerequisites

- NVIDIA driver installed and `nvidia-smi` works
- PostgreSQL reachable from this host
- `psql` installed (used by `bin/init_db.sh`)
- Python 3
- `uv` (Python environment/dependency manager)

Optional tools:

- `tmux` (recommended)
- `lm-sensors`, `nvme-cli`, `smartmontools` (used by diagnostics)

## 0. Pre-check (GPU enumeration)

If you cannot make the P40 visible to `nvidia-smi` yet, see:

- `docs/p40-nvidia-smi.ubuntu22.en.md`

```bash
nvidia-smi
nvidia-smi -L
nvidia-smi --query-gpu=name,uuid,pci.bus_id,temperature.gpu,power.draw --format=csv
```

If P40 does not show up, run `bin/host_healthcheck.sh` first and troubleshoot based on logs.

## 1. Setup (repo)

### 1.1 Create `.env`

Copy `.env.example` to `.env` and edit the PostgreSQL connection (do not commit `.env`).

```bash
cp .env.example .env
```

Required keys:

- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`

Optional:

- `PGSSLMODE` (default: `prefer`)
- `SAMPLE_INTERVAL_SEC` (sampling interval seconds)

### 1.2 Install dependencies with uv

```bash
uv sync
```

### 1.3 Initialize DB schema

```bash
./bin/init_db.sh
```

## 2. Connectivity test (one-shot)

```bash
uv run ./bin/collect_once.py
```

- On success: inserts into PostgreSQL
- On failure: spools payload to `./spool/` (with `_spool_reason`)

## 3. Continuous collection (systemd user service)

Recommended: run as systemd user units.

### 3.1 Install

```bash
mkdir -p ~/.config/systemd/user
cp ./systemd/gpu-telemetry.service ~/.config/systemd/user/
cp ./systemd/gpu-telemetry-flush.service ~/.config/systemd/user/
cp ./systemd/gpu-telemetry-flush.timer ~/.config/systemd/user/
systemctl --user daemon-reload
```

Note: under systemd, `uv` may not be available in PATH. This repo uses `bin/uv.sh` to resolve the `uv` binary reliably.

### 3.2 Enable and start

```bash
systemctl --user enable --now gpu-telemetry.service
systemctl --user enable --now gpu-telemetry-flush.timer
```

### 3.3 Check status/logs

```bash
systemctl --user status gpu-telemetry.service --no-pager -l
journalctl --user -u gpu-telemetry.service --no-pager -n 100

systemctl --user status gpu-telemetry-flush.timer --no-pager -l
journalctl --user -u gpu-telemetry-flush.service --no-pager -n 100
```

## Status tags (recommended: idle / prod / bench)

The collector reads `status.json` and stores `status_tag` / `status_memo` into DB.

Recommended taxonomy:

- `idle`
  - Normal baseline operation. Even if Open-WebUI/ollama is running, the system is considered "light load".
  - Goal: establish baseline temperature / power / fan behavior.
- `prod`
  - Real-world usage. You are actively using inference (API/WEBUI).
  - Goal: record temperature / power / throttling / VRAM behavior in real usage.
- `bench`
  - Benchmark / stress (gpu-burn / long-running inference / stress).
  - Goal: capture limit behavior (thermal saturation, power limit, clock drop, early warning signals).

Examples:

```bash
cp ./status.json.example ./status.json

./bin/set_status.sh idle "baseline"
./bin/set_status.sh prod "inference (Open-WebUI/ollama)"
./bin/set_status.sh bench "gpu-burn"
```

`status.json` is runtime state and should not be committed to a public repository.

## 4. Stress test (gpu-burn)

### 4.1 Prereq

This repo does not include `gpu-burn` source code. It expects:

- `~/projects/gpu-burn/gpu_burn` (built)

### 4.2 Run (tmux recommended)

```bash
./bin/run_gpuburn.sh \
  --pre-idle-sec 180 --pre-idle-memo "pre gpu-burn idle (baseline)" \
  --sec 900 --pre-tag bench --pre-memo "gpu-burn (max workload)" \
  --post-tag idle --post-memo "post gpu-burn idle" \
  --cooldown-sec 600 --cooldown-memo "cooldown idle (post gpu-burn)" \
  --final-tag prod --final-memo "prod (normal usage)" \
  --tmux
```

- `run_gpuburn.sh` updates `status.json` automatically and can include pre-idle baseline and post-burn cooldown
- It can also set a final `prod` status for normal usage
- Logs are written under `./logs/`

## 5. Verify results

### 5.1 Quick check via `nvidia-smi`

```bash
nvidia-smi --query-gpu=timestamp,name,pci.bus_id,temperature.gpu,power.draw,utilization.gpu --format=csv
```

Continuous monitoring during `gpu-burn` (1s interval):

```bash
nvidia-smi --query-gpu=timestamp,temperature.gpu,power.draw,power.limit,clocks.gr,pstate,utilization.gpu,fan.speed \
  --format=csv -l 1
```

### 5.2 Check in DB (examples)

```bash
psql "host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} sslmode=${PGSSLMODE:-prefer}"
```

```sql
select
  ts,
  host,
  gpu_name,
  pci_bus_id,
  temp_c,
  status_tag,
  status_memo
from telemetry.gpu_telemetry
order by ts desc
limit 50;
```

Only `bench` rows:

```sql
select
  ts,
  host,
  gpu_name,
  pci_bus_id,
  temp_c,
  status_tag,
  status_memo
from telemetry.gpu_telemetry
where status_tag = 'bench'
order by ts desc
limit 200;
```

### 5.3 Temperature plot (save PNG)

This script queries the DB for a selected time range and saves a PNG plot.

Example (last 6 hours; saves to `docs/images/gpu-temp.png`):

```bash
uv run ./bin/plot_temp.py --hours 6
```

Example (explicit range; ISO8601):

```bash
uv run ./bin/plot_temp.py \
  --start 2026-01-04T00:00:00+09:00 \
  --end   2026-01-04T06:00:00+09:00
```

Example (only `prod` rows):

```bash
uv run ./bin/plot_temp.py --hours 24 --status-tag prod
```

Example (exclude `prod` to focus on benchmark/non-prod ranges):

```bash
uv run ./bin/plot_temp.py --hours 24 --exclude-prod
```

Example (split benchmark runs by `status_memo`; repeatable):

```bash
# fan 100% (baseline)
uv run ./bin/plot_temp.py --hours 24 --exclude-prod --include-memo "fan=100%" --out docs/images/gpu-temp-fan100.png

# fan 25%
uv run ./bin/plot_temp.py --hours 24 --exclude-prod --include-memo "fan=25%" --out docs/images/gpu-temp-fan25.png
```

## 6. Spool and flush

- `bin/collect_once.py` spools to `spool/` when DB insert fails
- You can flush manually:

```bash
uv run ./bin/flush_spool.py
```

## 7. Recovery (after updating unit files)

After editing/replacing unit files:

```bash
systemctl --user daemon-reload
systemctl --user restart gpu-telemetry.service
systemctl --user restart gpu-telemetry-flush.timer
```

## 8. Troubleshooting

### 8.1 GPU not detected / `nvidia-smi` fails

- Run `bin/host_healthcheck.sh` and check `dmesg`, `lsmod`, `/dev/nvidia*`
- Check eGPU power sequence/cables/PCIe logs

```bash
./bin/host_healthcheck.sh
```

### 8.2 Telemetry not inserted

- Check `systemctl --user status gpu-telemetry.service` and `journalctl`
- Check if `spool/` is growing
- Verify `.env` DB settings

### 8.3 DB size grows too fast

- `bin/collect_once.py` stores `nvidia-smi -q -x` XML as a string inside `raw_json` (jsonb) (heavy)
- For temperature-only monitoring, consider retention/partitioning on DB side

### 8.4 Reset DB (truncate all telemetry)

Stop systemd units first to avoid re-inserts during reset:

```bash
systemctl --user stop gpu-telemetry.service
systemctl --user stop gpu-telemetry-flush.timer

set -a
source ${HOME}/projects/gpu-telemetry/.env
set +a

psql "host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER sslmode=${PGSSLMODE:-prefer}" \
  -v ON_ERROR_STOP=1 \
  -c "TRUNCATE telemetry.gpu_telemetry;"
```
