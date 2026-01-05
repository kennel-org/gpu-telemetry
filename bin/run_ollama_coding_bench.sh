#!/usr/bin/env bash
set -euo pipefail

# Run Ollama coding-model benchmarks with gpu-telemetry status tagging and cooldowns.
# - Uses ./bin/set_status.sh <tag> "<memo>"
# - Selects models from Ollama /api/tags: coding-regex + baselines
# - Sorts selected models by .size (ascending) and runs small -> large
# - De-duplicates models by .digest WITHOUT breaking the size order (reduce-based)
# - Ensures final status is restored even on Ctrl+C (trap)
# - Writes per-model CSV files under ./bench_results

API_BASE_DEFAULT="http://127.0.0.1:11434"
API_TAGS_PATH_DEFAULT="/api/tags"
API_GEN_PATH_DEFAULT="/api/generate"

FINAL_TAG_DEFAULT="prod"
FINAL_MEMO_DEFAULT='prod/prod (normal usage) fan=25% (phase=final rc=0)'

PRE_IDLE_SEC_DEFAULT=180
PRE_IDLE_MEMO_DEFAULT="pre ollama bench idle (baseline)"
POST_IDLE_SEC_DEFAULT=60
POST_IDLE_MEMO_DEFAULT="post ollama bench idle"
COOLDOWN_SEC_DEFAULT=600
COOLDOWN_MEMO_DEFAULT="cooldown idle (post model)"

NUM_PREDICT_DEFAULT=512
TEMPERATURE_DEFAULT=0
REPEAT_DEFAULT=3
KEEP_ALIVE_DEFAULT="10m"

CODING_REGEX_DEFAULT='(coder|starcoder|code)'
BASELINE_MODELS_DEFAULT=("llama3.1:8b" "gpt-oss:20b")

OUT_DIR_DEFAULT="./bench_results"
WRITE_CSV_DEFAULT=1

PROMPTS_DEFAULT=(
  "Write a Python function that parses a syslog line into a dict with type hints. Also write 3 unit tests using pytest."
  "Refactor this code for readability and performance without changing behavior. Explain changes briefly:\n\nfor i in range(len(a)):\n  if a[i] != None:\n    b.append(a[i])\n"
  "Given this error, propose the most likely root cause and the smallest fix:\n\nTypeError: expected str, got NoneType"
)

log() { echo "INFO: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
need_file() { [[ -f "$1" ]] || die "Missing file: $1"; }

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [options]

Options:
  --api-base <url>              (default: ${API_BASE_DEFAULT})
  --num-predict <n>             (default: ${NUM_PREDICT_DEFAULT})
  --temperature <n>             (default: ${TEMPERATURE_DEFAULT})
  --repeat <n>                  (default: ${REPEAT_DEFAULT})
  --keep-alive <dur>            (default: ${KEEP_ALIVE_DEFAULT})

  --pre-idle-sec <sec>          (default: ${PRE_IDLE_SEC_DEFAULT})
  --pre-idle-memo <memo>        (default: "${PRE_IDLE_MEMO_DEFAULT}")
  --post-idle-sec <sec>         (default: ${POST_IDLE_SEC_DEFAULT})
  --post-idle-memo <memo>       (default: "${POST_IDLE_MEMO_DEFAULT}")
  --cooldown-sec <sec>          (default: ${COOLDOWN_SEC_DEFAULT})
  --cooldown-memo <memo>        (default: "${COOLDOWN_MEMO_DEFAULT}")

  --final-tag <tag>             (default: ${FINAL_TAG_DEFAULT})
  --final-memo <memo>           (default: "${FINAL_MEMO_DEFAULT}")

  --coding-regex <regex>        (default: ${CODING_REGEX_DEFAULT})
  --baseline <model>            Add baseline model (can repeat). Default: llama3.1:8b, gpt-oss:20b
  --out-dir <dir>               (default: ${OUT_DIR_DEFAULT})
  --no-csv                      Disable CSV output (telemetry tagging only)
  --dry-run                     Print selected/sorted model list and exit

Examples:
  $(basename "$0")
  $(basename "$0") --repeat 5 --num-predict 768 --cooldown-sec 900
  $(basename "$0") --baseline mistral:7b
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SET_STATUS="${REPO_DIR}/bin/set_status.sh"
STATUS_JSON="${REPO_DIR}/status.json"

need_file "$SET_STATUS"
need_cmd curl
need_cmd jq
need_cmd awk
need_cmd sed

if [[ ! -f "$STATUS_JSON" ]]; then
  if [[ -f "${REPO_DIR}/status.json.example" ]]; then
    cp "${REPO_DIR}/status.json.example" "$STATUS_JSON"
    log "Created status.json from status.json.example"
  else
    die "status.json is missing and status.json.example not found."
  fi
fi

set_status() {
  local tag="$1"
  local memo="$2"
  "$SET_STATUS" "$tag" "$memo"
}

API_BASE="$API_BASE_DEFAULT"
API_TAGS_PATH="$API_TAGS_PATH_DEFAULT"
API_GEN_PATH="$API_GEN_PATH_DEFAULT"

PRE_IDLE_SEC="$PRE_IDLE_SEC_DEFAULT"
PRE_IDLE_MEMO="$PRE_IDLE_MEMO_DEFAULT"
POST_IDLE_SEC="$POST_IDLE_SEC_DEFAULT"
POST_IDLE_MEMO="$POST_IDLE_MEMO_DEFAULT"
COOLDOWN_SEC="$COOLDOWN_SEC_DEFAULT"
COOLDOWN_MEMO="$COOLDOWN_MEMO_DEFAULT"

FINAL_TAG="$FINAL_TAG_DEFAULT"
FINAL_MEMO="$FINAL_MEMO_DEFAULT"

NUM_PREDICT="$NUM_PREDICT_DEFAULT"
TEMPERATURE="$TEMPERATURE_DEFAULT"
REPEAT="$REPEAT_DEFAULT"
KEEP_ALIVE="$KEEP_ALIVE_DEFAULT"

CODING_REGEX="$CODING_REGEX_DEFAULT"
BASELINE_MODELS=("${BASELINE_MODELS_DEFAULT[@]}")

OUT_DIR="$OUT_DIR_DEFAULT"
DRY_RUN=0
WRITE_CSV="$WRITE_CSV_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-base) API_BASE="${2:-}"; shift 2 ;;
    --num-predict) NUM_PREDICT="${2:-}"; shift 2 ;;
    --temperature) TEMPERATURE="${2:-}"; shift 2 ;;
    --repeat) REPEAT="${2:-}"; shift 2 ;;
    --keep-alive) KEEP_ALIVE="${2:-}"; shift 2 ;;

    --pre-idle-sec) PRE_IDLE_SEC="${2:-}"; shift 2 ;;
    --pre-idle-memo) PRE_IDLE_MEMO="${2:-}"; shift 2 ;;
    --post-idle-sec) POST_IDLE_SEC="${2:-}"; shift 2 ;;
    --post-idle-memo) POST_IDLE_MEMO="${2:-}"; shift 2 ;;
    --cooldown-sec) COOLDOWN_SEC="${2:-}"; shift 2 ;;
    --cooldown-memo) COOLDOWN_MEMO="${2:-}"; shift 2 ;;

    --final-tag) FINAL_TAG="${2:-}"; shift 2 ;;
    --final-memo) FINAL_MEMO="${2:-}"; shift 2 ;;

    --coding-regex) CODING_REGEX="${2:-}"; shift 2 ;;
    --baseline) BASELINE_MODELS+=("${2:-}"); shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --no-csv) WRITE_CSV=0; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

TAGS_URL="${API_BASE}${API_TAGS_PATH}"
GEN_URL="${API_BASE}${API_GEN_PATH}"

cleanup() {
  set_status "$FINAL_TAG" "$FINAL_MEMO" || true
  log "Restored status: ${FINAL_TAG} / ${FINAL_MEMO}"
}
trap cleanup EXIT INT TERM

log "Fetching model list from: ${TAGS_URL}"
tags_json="$(curl -sS "$TAGS_URL")"

# Keep size order while de-duplicating by digest.
models_sorted="$(
  jq -r --arg re "$CODING_REGEX" --argjson baselines "$(printf '%s\n' "${BASELINE_MODELS[@]}" | jq -R . | jq -s .)" '
    .models
    | map(select((.name | test($re; "i")) or (.name as $n | any($baselines[]; . == $n))))
    | sort_by(.size)
    | reduce .[] as $m ({seen:{}, out:[]};
        if .seen[$m.digest] then
          .
        else
          .seen[$m.digest] = true | .out += [$m]
        end
      )
    | .out
    | .[].name
  ' <<<"$tags_json"
)"

if [[ -z "$models_sorted" ]]; then
  die "No models matched. Check --coding-regex or baseline list."
fi

log "Selected models (small -> large):"
echo "$models_sorted" | sed 's/^/  - /' >&2

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry-run requested. Exiting without running benchmarks."
  exit 0
fi

if [[ "$WRITE_CSV" -eq 1 ]]; then
  mkdir -p "$OUT_DIR"
fi

run_generate() {
  local model="$1"
  local prompt="$2"
  curl -sS "$GEN_URL" -H 'Content-Type: application/json' -d "$(
    jq -n \
      --arg model "$model" \
      --arg prompt "$prompt" \
      --arg keep "$KEEP_ALIVE" \
      --argjson num_predict "$NUM_PREDICT" \
      --argjson temperature "$TEMPERATURE" \
      '{
        model:$model,
        prompt:$prompt,
        stream:false,
        keep_alive:$keep,
        options:{num_predict:$num_predict, temperature:$temperature}
      }'
  )"
}

ns_to_s() { awk "BEGIN{printf \"%.3f\", $1/1000000000}"; }

calc_tps() {
  local count="$1"
  local dur_ns="$2"
  if [[ "$dur_ns" -gt 0 && "$count" -gt 0 ]]; then
    awk "BEGIN{printf \"%.3f\", $count/($dur_ns/1000000000)}"
  else
    echo "0.000"
  fi
}

bench_one_model() {
  local model="$1"
  local model_safe="${model//[:\/]/_}"
  local out_csv="${OUT_DIR}/bench_${model_safe}.csv"

  log "Pre-idle: ${PRE_IDLE_SEC}s (${PRE_IDLE_MEMO})"
  set_status "idle" "$PRE_IDLE_MEMO"
  sleep "$PRE_IDLE_SEC"

  log "Bench start: model=${model}"
  set_status "bench" "ollama_${model}"

  if [[ "$WRITE_CSV" -eq 1 ]]; then
    if [[ ! -f "$out_csv" ]]; then
      echo "model,run,prompt_id,load_s,prompt_tps,gen_tps,total_s,prompt_tokens,gen_tokens" > "$out_csv"
    fi
  fi

  local run_id=0
  for r in $(seq 1 "$REPEAT"); do
    run_id=$((run_id+1))

    local pid=0
    for prompt in "${PROMPTS_DEFAULT[@]}"; do
      pid=$((pid+1))

      run_generate "$model" "Warm up. Reply with OK." >/dev/null || true
      resp="$(run_generate "$model" "$prompt")"

      load_ns="$(jq -r '.load_duration // 0' <<<"$resp")"
      total_ns="$(jq -r '.total_duration // 0' <<<"$resp")"
      p_cnt="$(jq -r '.prompt_eval_count // 0' <<<"$resp")"
      p_ns="$(jq -r '.prompt_eval_duration // 0' <<<"$resp")"
      e_cnt="$(jq -r '.eval_count // 0' <<<"$resp")"
      e_ns="$(jq -r '.eval_duration // 0' <<<"$resp")"

      load_s="$(ns_to_s "$load_ns")"
      total_s="$(ns_to_s "$total_ns")"
      p_tps="$(calc_tps "$p_cnt" "$p_ns")"
      e_tps="$(calc_tps "$e_cnt" "$e_ns")"

      if [[ "$WRITE_CSV" -eq 1 ]]; then
        echo "${model},${run_id},${pid},${load_s},${p_tps},${e_tps},${total_s},${p_cnt},${e_cnt}" >> "$out_csv"
      fi
      log "Done: model=${model} run=${run_id}/${REPEAT} prompt=${pid}/${#PROMPTS_DEFAULT[@]} gen_tps=${e_tps}"
    done
  done

  log "Post-idle: ${POST_IDLE_SEC}s (${POST_IDLE_MEMO})"
  set_status "idle" "$POST_IDLE_MEMO"
  sleep "$POST_IDLE_SEC"

  log "Cooldown: ${COOLDOWN_SEC}s (${COOLDOWN_MEMO})"
  set_status "idle" "$COOLDOWN_MEMO"
  sleep "$COOLDOWN_SEC"

  if [[ "$WRITE_CSV" -eq 1 ]]; then
    log "Bench complete: model=${model} -> ${out_csv}"
  else
    log "Bench complete: model=${model}"
  fi
}

if [[ "$WRITE_CSV" -eq 1 ]]; then
  log "Starting benchmarks. Output dir: ${OUT_DIR}"
else
  log "Starting benchmarks. CSV output disabled."
fi
while IFS= read -r model; do
  [[ -n "$model" ]] || continue
  bench_one_model "$model"
done <<<"$models_sorted"

log "All benchmarks completed."
