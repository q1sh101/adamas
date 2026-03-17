#!/usr/bin/env bash
# adamas.sh - flatpak sandbox hardening CLI
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/common.sh"

# --- dispatch ---
cmd="${1:-}"

case "$cmd" in
  list)
    found=0
    for f in "${_dir}/apps"/*.conf; do
      [[ -f "$f" ]] || continue
      [[ "$(basename "$f")" == "example.conf" ]] && continue
      log "  $(basename "${f%.conf}")"
      ((found++)) || true
    done
    (( found > 0 )) || warn "no app configs in $_dir/apps"
    ;;
  *)
    log "usage: adamas <command> <app>"
    log "  list              show available app configs"
    exit 1
    ;;
esac
