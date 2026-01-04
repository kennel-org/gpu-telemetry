#!/usr/bin/env bash
set -euo pipefail

STATUS_FILE="${HOME}/projects/gpu-telemetry/status.json"

tag="${1:-idle}"
memo="${2:-$tag}"

STATUS_TAG="$tag" STATUS_MEMO="$memo" STATUS_FILE="$STATUS_FILE" python3 - <<'PY'
import json
import os

tag = os.environ.get("STATUS_TAG", "idle")
memo = os.environ.get("STATUS_MEMO", tag)
path = os.environ["STATUS_FILE"]

obj = {"tag": tag, "memo": memo}
with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False)

print("[INFO] status updated:", obj)
PY
