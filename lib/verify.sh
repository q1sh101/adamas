#!/usr/bin/env bash
# lib/verify.sh - desktop route integrity check
# shellcheck disable=SC2154  # _dir, _conf_name provided by adamas.sh

# --- verify (desktop route or launcher hook integrity) ---
adamas_verify() {
  _require_safe_flatpak
  _is_installed "$APP_ID" || die "$APP_ID not installed"

  log "verifying ${_conf_name}..."

  local fails=0

  if [[ -n "${HOOK_NAME:-}" ]]; then
    # webapp: check launcher hook
    local hook
    hook="$(_hook_dir)/${HOOK_NAME}"
    if [[ ! -x "$hook" ]]; then
      warn "DRIFT: launcher hook missing or not executable: $hook"
      ((fails++)) || true
    elif ! grep -q "adamas\\.sh.*run.*${_conf_name}" "$hook" 2>/dev/null; then
      warn "DRIFT: hook does not route to adamas run ${_conf_name}"
      ((fails++)) || true
    fi
  else
    # flatpak app: check .desktop route
    local ddir
    ddir="$(_desktop_dir)"
    local desktop="${ddir}/${APP_ID}.desktop"
    local escaped_dir
    escaped_dir="$(_bre_escape "$_dir")"
    if [[ -f "$desktop" ]]; then
      if ! grep -q "^Exec=\"\\?${escaped_dir}/adamas\\.sh\"\\? run ${_conf_name}\( \|$\)" "$desktop" 2>/dev/null; then
        warn "DRIFT: ${APP_ID}.desktop not routed through adamas run"
        ((fails++)) || true
      fi
      # check all Exec= lines for bare flatpak (Desktop Actions too)
      local bare_count=0
      bare_count=$(grep -c "^Exec=.*flatpak " "$desktop" 2>/dev/null) || true
      if (( bare_count > 0 )); then
        warn "DRIFT: ${APP_ID}.desktop has $bare_count unpatched Exec= line(s) with bare flatpak run"
        ((fails += bare_count)) || true
      fi
    else
      warn "DRIFT: ${APP_ID}.desktop not found in $ddir"
      ((fails++)) || true
    fi
  fi

  (( fails == 0 )) || die "$fails drift(s) detected - run adamas harden $_conf_name"
  ok "${_conf_name} clean"
}
