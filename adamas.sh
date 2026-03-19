#!/usr/bin/env bash
# adamas.sh - flatpak sandbox hardening CLI
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${_dir}/lib/common.sh"
source "${_dir}/lib/run.sh"
source "${_dir}/lib/install.sh"
source "${_dir}/lib/harden.sh"
source "${_dir}/lib/verify.sh"

# --- config ---
_defaults() {
  APP_ID=""
  APP_ARGS=()
  HOOK_NAME=""
  ALLOW_DBUS_CALL=()
  ALLOW_SHARE=()
  ALLOW_SOCKET=()
  ALLOW_DEVICE=()
  ALLOW_FEATURE=()
  ALLOW_FILESYSTEM=()
  ALLOW_DBUS_TALK=()
  ALLOW_DBUS_OWN=()
  ALLOW_SYSTEM_DBUS_TALK=()
  ALLOW_SYSTEM_DBUS_OWN=()
  ALLOW_A11Y_OWN=()
  ALLOW_USB=()
  PERSIST=()
  ADD_POLICY=()
  SET_ENV=()
  ALLOW_ENV=()
  DENY_PORTAL=()    # populated by baseline merge, not by config files
  ALLOW_PORTAL=()
}

_load_conf() {
  local app="$1"
  case "$app" in
    ''|*[!a-zA-Z0-9._-]*) die "invalid app name: $app" ;;
  esac
  local conf="${_dir}/apps/${app}.conf"
  [[ -f "$conf" ]] || die "no config: $conf"

  _conf_name="$app"
  _defaults
  _check_conf_safe "$conf"
  source "$conf"

  [[ -n "$APP_ID" ]] || die "APP_ID not set in $conf"

  # merge baseline portal denies (skip entries overridden per-app)
  local baseline=(
    background:background
    devices:camera
    devices:microphone
    devices:speakers
    location:location
    notifications:notification
    screenshot:screenshot
    screencast:screencast
  )
  local entry skip existing
  for entry in "${baseline[@]}"; do
    skip=false
    for existing in ${DENY_PORTAL[@]+"${DENY_PORTAL[@]}"}; do
      [[ "$entry" != "$existing" ]] || { skip=true; break; }
    done
    for existing in ${ALLOW_PORTAL[@]+"${ALLOW_PORTAL[@]}"}; do
      [[ "$entry" != "$existing" ]] || { skip=true; break; }
    done
    $skip || DENY_PORTAL+=("$entry")
  done

  _validate
}

# --- dispatch ---
cmd="${1:-}"

case "$cmd" in
  run)
    [[ -n "${2:-}" ]] || die "usage: adamas run <app> [args...]"
    _load_conf "$2"
    logger -t adamas "run $_conf_name ($APP_ID)" 2>/dev/null || true
    adamas_run "${@:3}"
    ;;
  install)
    [[ -n "${2:-}" ]] || die "usage: adamas install <app>"
    _load_conf "$2"
    logger -t adamas "install $_conf_name ($APP_ID)" 2>/dev/null || true
    adamas_install
    ;;
  harden)
    [[ -n "${2:-}" ]] || die "usage: adamas harden <app>"
    _load_conf "$2"
    logger -t adamas "harden $_conf_name ($APP_ID)" 2>/dev/null || true
    adamas_harden
    ;;
  verify)
    [[ -n "${2:-}" ]] || die "usage: adamas verify <app>"
    _load_conf "$2"
    logger -t adamas "verify $_conf_name ($APP_ID)" 2>/dev/null || true
    adamas_verify
    ;;
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
    log "  run     <app>     launch with stateless sandbox (--sandbox + env -i)"
    log "  install <app>     install from Flathub"
    log "  harden  <app>     patch .desktop to route through adamas run"
    log "  verify  <app>     audit .desktop route integrity"
    log "  list              show available app configs"
    exit 1
    ;;
esac
