#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
REPO_DIR="${HOME}/projects/gpu-telemetry"
GPUBURN_DIR="${HOME}/projects/gpu-burn"
LOG_DIR="${REPO_DIR}/logs"
STATUS_CMD="${REPO_DIR}/bin/set_status.sh"

DURATION_SEC="900"
PRE_TAG="bench"
POST_TAG="idle"
PRE_MEMO="gpu-burn (max workload)"
POST_MEMO="post gpu-burn idle"
PRE_IDLE_SEC="0"
PRE_IDLE_MEMO="pre gpu-burn idle (baseline)"
COOLDOWN_SEC="0"
COOLDOWN_MEMO="cooldown idle (post gpu-burn)"
FINAL_TAG="prod"
FINAL_MEMO="prod (normal usage)"
TMUX_SESSION="gpubench"
USE_TMUX="0"
FORCE_ENGLISH="1"
RUN_DIAG="1"   # 1=collect sensors/smart before&after, 0=skip

usage() {
  cat <<'USAGE'
Usage:
  run_gpuburn.sh [--sec 900] [--pre-tag bench] [--pre-memo "memo"]
                 [--post-tag idle] [--post-memo "memo"]
                 [--pre-idle-sec 0] [--pre-idle-memo "memo"]
                 [--cooldown-sec 0] [--cooldown-memo "memo"]
                 [--final-tag prod] [--final-memo "memo"]
                 [--tmux-session gpubench] [--tmux|--no-tmux]
                 [--english|--no-english]
                 [--diag|--no-diag]

Examples:
  run_gpuburn.sh --sec 900 --pre-tag bench --pre-memo "gpu-burn 900s fan=MAX" --tmux
  run_gpuburn.sh --sec 60 --no-tmux --no-diag
USAGE
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }

# Avoid killing parent shell if this script is sourced or a snippet is copy/pasted.
script_exit() {
  local rc="${1:-0}"
  # If sourced: BASH_SOURCE[0] != $0, so "return" won't terminate the parent shell.
  if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return "${rc}"
  fi
  exit "${rc}"
}

# --- Args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sec) DURATION_SEC="${2:-}"; shift 2;;
    --pre-tag) PRE_TAG="${2:-}"; shift 2;;
    --pre-memo) PRE_MEMO="${2:-}"; shift 2;;
    --post-tag) POST_TAG="${2:-}"; shift 2;;
    --post-memo) POST_MEMO="${2:-}"; shift 2;;
    --pre-idle-sec) PRE_IDLE_SEC="${2:-}"; shift 2;;
    --pre-idle-memo) PRE_IDLE_MEMO="${2:-}"; shift 2;;
    --cooldown-sec) COOLDOWN_SEC="${2:-}"; shift 2;;
    --cooldown-memo) COOLDOWN_MEMO="${2:-}"; shift 2;;
    --final-tag) FINAL_TAG="${2:-}"; shift 2;;
    --final-memo) FINAL_MEMO="${2:-}"; shift 2;;
    --tmux-session) TMUX_SESSION="${2:-}"; shift 2;;
    --tmux) USE_TMUX="1"; shift;;
    --no-tmux) USE_TMUX="0"; shift;;
    --english) FORCE_ENGLISH="1"; shift;;
    --no-english) FORCE_ENGLISH="0"; shift;;
    --diag) RUN_DIAG="1"; shift;;
    --no-diag) RUN_DIAG="0"; shift;;
    -h|--help) usage; script_exit 0;;
    *) err "Unknown arg: $1"; usage; script_exit 2;;
  esac
done

# --- Validation ---
[[ -x "${STATUS_CMD}" ]] || { err "Missing status script: ${STATUS_CMD}"; script_exit 2; }
[[ -d "${GPUBURN_DIR}" ]] || { err "Missing gpu-burn dir: ${GPUBURN_DIR}"; script_exit 2; }
[[ -x "${GPUBURN_DIR}/gpu_burn" ]] || { err "Missing gpu_burn binary: ${GPUBURN_DIR}/gpu_burn"; script_exit 2; }
[[ "${DURATION_SEC}" =~ ^[0-9]+$ ]] || { err "--sec must be integer"; script_exit 2; }
[[ "${PRE_IDLE_SEC}" =~ ^[0-9]+$ ]] || { err "--pre-idle-sec must be integer"; script_exit 2; }
[[ "${COOLDOWN_SEC}" =~ ^[0-9]+$ ]] || { err "--cooldown-sec must be integer"; script_exit 2; }

mkdir -p "${LOG_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gpu-burn-${STAMP}-${PRE_TAG}.log"

# --- Optional: run detached in tmux ---
if [[ "${USE_TMUX}" == "1" ]]; then
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
      err "tmux session already exists: ${TMUX_SESSION} (attach: tmux a -t ${TMUX_SESSION})"
      script_exit 2
    fi
    log "Starting in tmux session: ${TMUX_SESSION}"
    tmux new-session -d -s "${TMUX_SESSION}" \
      "bash -lc '${0} --sec ${DURATION_SEC} --pre-tag \"${PRE_TAG}\" --pre-memo \"${PRE_MEMO}\" --post-tag \"${POST_TAG}\" --post-memo \"${POST_MEMO}\" --pre-idle-sec ${PRE_IDLE_SEC} --pre-idle-memo \"${PRE_IDLE_MEMO}\" --cooldown-sec ${COOLDOWN_SEC} --cooldown-memo \"${COOLDOWN_MEMO}\" --final-tag \"${FINAL_TAG}\" --final-memo \"${FINAL_MEMO}\" --no-tmux $( [[ ${FORCE_ENGLISH} == 1 ]] && echo --english || echo --no-english ) $( [[ ${RUN_DIAG} == 1 ]] && echo --diag || echo --no-diag )'"
    log "Log file: ${LOG_FILE}"
    log "Attach: tmux a -t ${TMUX_SESSION}"
    script_exit 0
  else
    err "tmux not installed. Install it or run with --no-tmux."
    script_exit 2
  fi
fi

# --- Diagnostics helper ---
diag_cmd() {
  local title="$1"
  shift
  {
    echo ""
    echo "===== ${title} ====="
    echo "[INFO] time=$(date -Is) host=$(hostname) user=$(id -un)"
    echo "[INFO] cmd=$*"
    "$@"
  } >> "${LOG_FILE}" 2>&1 || {
    echo "[WARN] diag command failed: ${title}" >> "${LOG_FILE}"
    return 0
  }
}

collect_diagnostics() {
  [[ "${RUN_DIAG}" == "1" ]] || return 0

  diag_cmd "uname" uname -a
  if command -v nvidia-smi >/dev/null 2>&1; then
    diag_cmd "nvidia-smi" nvidia-smi
    diag_cmd "nvidia-smi -q (TEMP/POWER/PERF)" nvidia-smi -q -d TEMPERATURE,PERFORMANCE,POWER
  fi

  if command -v sensors >/dev/null 2>&1; then
    diag_cmd "sensors" sensors
  fi

  # NVMe SMART (usually needs root)
  if command -v nvme >/dev/null 2>&1; then
    # If you have multiple NVMe, this will attempt the common namespace paths.
    for dev in /dev/nvme0 /dev/nvme0n1 /dev/nvme1 /dev/nvme1n1; do
      if [[ -e "${dev}" ]]; then
        if sudo -n true >/dev/null 2>&1; then
          diag_cmd "nvme smart-log ${dev}" sudo -n nvme smart-log "${dev}"
        else
          echo "" >> "${LOG_FILE}"
          echo "===== nvme smart-log ${dev} =====" >> "${LOG_FILE}"
          echo "[WARN] sudo password required; skipping nvme smart-log (use: sudo nvme smart-log ${dev})" >> "${LOG_FILE}"
        fi
      fi
    done
  fi

  # SATA/SAS SMART (usually needs root)
  if command -v smartctl >/dev/null 2>&1; then
    # Try to list devices (may require root)
    if sudo -n true >/dev/null 2>&1; then
      diag_cmd "smartctl --scan" sudo -n smartctl --scan
    else
      echo "" >> "${LOG_FILE}"
      echo "===== smartctl --scan =====" >> "${LOG_FILE}"
      echo "[WARN] sudo password required; skipping smartctl scans (use: sudo smartctl --scan)" >> "${LOG_FILE}"
    fi
  fi
}

# --- Ensure post status even on Ctrl+C ---
PHASE="init"
RC=0
cleanup() {
  set +e
  local final_memo
  final_memo="${FINAL_MEMO} (phase=${PHASE} rc=${RC})"
  "${STATUS_CMD}" "${FINAL_TAG}" "${final_memo}" >/dev/null 2>&1 || true
  log "Status set to ${FINAL_TAG}"
}
trap cleanup EXIT INT TERM

# --- Pre idle (optional) ---
if [[ "${PRE_IDLE_SEC}" != "0" ]]; then
  PHASE="pre-idle"
  "${STATUS_CMD}" "idle" "${PRE_IDLE_MEMO}"
  log "Status set to idle (memo='${PRE_IDLE_MEMO}')"
  log "Pre-idle sleep: ${PRE_IDLE_SEC}s"
  sleep "${PRE_IDLE_SEC}"
fi

# --- Pre status (bench) ---
PHASE="bench"
"${STATUS_CMD}" "${PRE_TAG}" "${PRE_MEMO}"
log "Status set to ${PRE_TAG} (memo='${PRE_MEMO}')"
log "Log file: ${LOG_FILE}"

# --- Pre diagnostics ---
collect_diagnostics

# --- Run gpu-burn ---
cd "${GPUBURN_DIR}"
log "Running gpu-burn for ${DURATION_SEC}s"

RC=0
if [[ "${FORCE_ENGLISH}" == "1" ]]; then
  # Force English output formatting while keeping JST timestamps.
  LC_ALL=C LANG=C TZ=Asia/Tokyo ./gpu_burn "${DURATION_SEC}" 2>&1 | tee -a "${LOG_FILE}" || RC=$?
else
  ./gpu_burn "${DURATION_SEC}" 2>&1 | tee -a "${LOG_FILE}" || RC=$?
fi

log "gpu-burn exit code: ${RC}"

PHASE="post-idle"
"${STATUS_CMD}" "${POST_TAG}" "${POST_MEMO}"
log "Status set to ${POST_TAG} (memo='${POST_MEMO}')"

if [[ "${COOLDOWN_SEC}" != "0" ]]; then
  "${STATUS_CMD}" "idle" "${COOLDOWN_MEMO}"
  log "Status set to idle (memo='${COOLDOWN_MEMO}')"
  log "Cooldown sleep: ${COOLDOWN_SEC}s"
  sleep "${COOLDOWN_SEC}"
fi

PHASE="final"
"${STATUS_CMD}" "${FINAL_TAG}" "${FINAL_MEMO}"
log "Status set to ${FINAL_TAG} (memo='${FINAL_MEMO}')"

# --- Post diagnostics ---
collect_diagnostics

script_exit "${RC}"
