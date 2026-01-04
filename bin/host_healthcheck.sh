#!/usr/bin/env bash
set -euo pipefail

# Host health check for GPU/NVMe/system status.
# Logs are written to gpu-telemetry/logs and also printed to stdout.

REPO_DIR="${HOME}/projects/gpu-telemetry"
LOG_DIR="${REPO_DIR}/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/healthcheck-${STAMP}.log"

usage() {
  cat <<'USAGE'
Usage:
  host_healthcheck.sh [--no-sudo] [--log FILE]

Options:
  --no-sudo   Do not attempt sudo commands.
  --log FILE  Write log to FILE (default: ~/projects/gpu-telemetry/logs/healthcheck-<ts>.log)

Examples:
  host_healthcheck.sh
  host_healthcheck.sh --no-sudo
  host_healthcheck.sh --log /tmp/health.log
USAGE
}

NO_SUDO="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-sudo) NO_SUDO="1"; shift;;
    --log) LOG_FILE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERROR] Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

mkdir -p "${LOG_DIR}"

# Tee everything to a log file.
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

run() {
  local title="$1"; shift
  echo
  echo "===== ${title} ====="
  echo "+ $*"
  "$@" || warn "Command failed (ignored): $*"
}

run_sh() {
  local title="$1"; shift
  local cmd="$*"
  echo
  echo "===== ${title} ====="
  echo "+ ${cmd}"
  bash -lc "${cmd}" || warn "Command failed (ignored): ${cmd}"
}

run_sudo() {
  local title="$1"; shift
  if [[ "${NO_SUDO}" == "1" ]]; then
    warn "Skipping sudo command (disabled): $*"
    return 0
  fi

  if sudo -n true >/dev/null 2>&1; then
    echo
    echo "===== ${title} ====="
    echo "+ sudo $*"
    sudo "$@" || warn "sudo command failed (ignored): $*"
  else
    warn "sudo requires a password (non-interactive). Skipping: $*"
  fi
}

log "Log file: ${LOG_FILE}"
run "TIME" date

# ===== 0) OS / Kernel / HW =====
run_sh "OS" 'lsb_release -a 2>/dev/null || cat /etc/os-release'
run "KERNEL" uname -a
run_sh "CPU (summary)" "lscpu | egrep 'Model name|CPU\\(s\\)|Thread|Core|Socket|NUMA' || true"
run "MEMORY" free -h
run_sh "FILESYSTEM" 'df -hT / /var /usr /opt 2>/dev/null || df -hT'

# ===== 1) NVIDIA driver / device nodes / module sanity =====
if have nvidia-smi; then
  run "NVIDIA-SMI (summary)" nvidia-smi
  run "NVIDIA-SMI (list GPUs)" nvidia-smi -L
  run_sh "NVIDIA-SMI (query fields help, first 200 lines)" 'nvidia-smi --help-query-gpu 2>/dev/null | sed -n "1,200p" || true'
  run_sh "NVIDIA-SMI (query: name/uuid/compute_cap/driver)" \
    'nvidia-smi --query-gpu=name,uuid,compute_cap,driver_version --format=csv,noheader 2>/dev/null || true'
  run_sh "GPU live metrics" \
    'nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv 2>/dev/null || true'
  run_sh "NVIDIA topology (optional)" 'nvidia-smi topo -m 2>/dev/null || true'
else
  warn "nvidia-smi not found."
fi

run_sh "Kernel modules (nvidia/nouveau)" "lsmod | egrep '(^nvidia\\b|^nvidia_uvm|nouveau)' || true"
run_sh "/dev/nvidia* nodes" "ls -l /dev/nvidia* /dev/nvidia-caps/* 2>/dev/null || true"
run_sh "NVIDIA module version (modinfo)" "modinfo -F version nvidia 2>/dev/null || true"
run_sh "CUDA libraries (ldconfig)" "ldconfig -p | egrep 'libcuda\\.so|libcudart\\.so|libcublas\\.so' || true"
run_sh "dmesg hints (last 80 lines match)" "dmesg -T | egrep -i 'nvrm|nvidia|nouveau|iommu|pcie' | tail -n 80 || true"
run_sh "Secure Boot state (mokutil)" "command -v mokutil >/dev/null 2>&1 && mokutil --sb-state || true"

# ===== 2) Thermals (CPU/GPU/NVMe) =====
if have sensors; then
  run "sensors" sensors
else
  warn "sensors not found. Install: sudo apt install -y lm-sensors && sudo sensors-detect --auto"
fi

if have nvme; then
  run_sudo "NVMe list (needs sudo)" nvme list
  # Try common device name; if you have multiple NVMe, adjust here.
  run_sudo "NVMe smart-log /dev/nvme0n1 (needs sudo)" nvme smart-log /dev/nvme0n1
  run_sudo "NVMe id-ctrl /dev/nvme0n1 (needs sudo)" nvme id-ctrl /dev/nvme0n1
  run_sudo "NVMe id-ctrl filtered fields" bash -lc "nvme id-ctrl /dev/nvme0n1 | egrep -i 'mn|fr|sn|fguid|subnqn' || true"
else
  warn "nvme not found. Install: sudo apt install -y nvme-cli"
fi

# ===== 3) Storage SMART (generic) =====
if have smartctl; then
  run "smartctl scan" smartctl --scan || true
  # NVMe SMART via smartctl is typically /dev/nvme0 -d nvme (device name differs from nvme-cli)
  run_sudo "smartctl -a /dev/nvme0 -d nvme (needs sudo)" smartctl -a /dev/nvme0 -d nvme
else
  warn "smartctl not found. Install: sudo apt install -y smartmontools"
fi

# ===== 4) Ollama presence / service =====
run_sh "ollama version" 'command -v ollama >/dev/null 2>&1 && ollama -v || echo "ollama: not installed"'
run_sh "systemd service (system)" 'systemctl status ollama --no-pager -l 2>/dev/null || true'
run_sh "systemd service (user)" 'systemctl --user status ollama --no-pager -l 2>/dev/null || true'

# ===== 5) Your gpu-telemetry services (optional) =====
run_sh "gpu-telemetry service (user)" 'systemctl --user status gpu-telemetry.service --no-pager -l 2>/dev/null || true'
run_sh "gpu-telemetry flush timer (user)" 'systemctl --user status gpu-telemetry-flush.timer --no-pager -l 2>/dev/null || true'
run_sh "gpu-telemetry recent logs (user)" 'journalctl --user -u gpu-telemetry.service --no-pager -n 50 2>/dev/null || true'
run_sh "gpu-telemetry flush recent logs (user)" 'journalctl --user -u gpu-telemetry-flush.service --no-pager -n 50 2>/dev/null || true'
run_sh "gpu-telemetry spool dir" 'ls -la "${HOME}/projects/gpu-telemetry/spool" 2>/dev/null | tail -n 50 || true'

log "Done."
