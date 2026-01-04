#!/usr/bin/env bash
set -euo pipefail

# Resolve uv path for systemd (PATH may be minimal).
# Preference:
# 1) UV_BIN env var
# 2) ~/.local/bin/uv
# 3) /usr/local/bin/uv
# 4) /usr/bin/uv
# 5) PATH lookup

UV_BIN_CANDIDATES=()

if [[ -n "${UV_BIN:-}" ]]; then
  UV_BIN_CANDIDATES+=("${UV_BIN}")
fi

UV_BIN_CANDIDATES+=("${HOME}/.local/bin/uv")
UV_BIN_CANDIDATES+=("/usr/local/bin/uv")
UV_BIN_CANDIDATES+=("/usr/bin/uv")

for c in "${UV_BIN_CANDIDATES[@]}"; do
  if [[ -x "${c}" ]]; then
    exec "${c}" "$@"
  fi
done

if command -v uv >/dev/null 2>&1; then
  exec uv "$@"
fi

echo "[ERROR] uv not found. Install uv and/or set UV_BIN or ensure uv is in PATH." >&2
exit 127
