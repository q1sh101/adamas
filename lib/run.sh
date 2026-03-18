#!/usr/bin/env bash
# lib/run.sh - stateless sandbox launcher

# --- portal cleanup (only if last instance for this APP_ID) ---
_portal_cleanup() {
  local _pf="${XDG_RUNTIME_DIR:-/tmp}/adamas-${APP_ID}.pids"
  local _alive="" _p
  while IFS= read -r _p; do
    [[ -n "$_p" && "$_p" != "$$" ]] || continue
    kill -0 "$_p" 2>/dev/null && _alive="${_alive}${_p}
"
  done < "$_pf" 2>/dev/null
  if [[ -n "$_alive" ]]; then
    printf '%s' "$_alive" > "$_pf"
    return 0  # siblings alive, don't reset
  fi
  rm -f "$_pf"
  flatpak permission-reset "$APP_ID" 2>/dev/null || true
}

# --- run (stateless sandbox) ---
adamas_run() {
  _require_safe_flatpak
  _is_installed "$APP_ID" || die "$APP_ID not installed"

  # --- portal reset (skip if sibling for same APP_ID) ---
  local _pf="${XDG_RUNTIME_DIR:-/tmp}/adamas-${APP_ID}.pids"
  echo "$$" >> "$_pf"
  local _sibling=false _p
  while IFS= read -r _p; do
    [[ -n "$_p" && "$_p" != "$$" ]] || continue
    kill -0 "$_p" 2>/dev/null && { _sibling=true; break; }
  done < "$_pf"

  if $_sibling; then
    warn "concurrent $APP_ID instance - skipping portal reset"
  else
    flatpak permission-reset "$APP_ID" 2>/dev/null \
      || warn "permission-reset failed (may retain stale grants)"
    local pe tbl id
    for pe in ${DENY_PORTAL[@]+"${DENY_PORTAL[@]}"}; do
      tbl="${pe%%:*}"; id="${pe#*:}"
      flatpak permission-set "$tbl" "$id" "$APP_ID" no \
        || die "permission-set (deny) failed: $tbl:$id"
    done
    for pe in ${ALLOW_PORTAL[@]+"${ALLOW_PORTAL[@]}"}; do
      tbl="${pe%%:*}"; id="${pe#*:}"
      flatpak permission-set "$tbl" "$id" "$APP_ID" yes \
        || die "permission-set (allow) failed: $tbl:$id"
    done
  fi

  # --- compile allow flags ---
  local flags=(--sandbox --file-forwarding)
  local item
  for item in ${ALLOW_SHARE[@]+"${ALLOW_SHARE[@]}"}; do
    flags+=("--share=${item}")
  done
  for item in ${ALLOW_SOCKET[@]+"${ALLOW_SOCKET[@]}"}; do
    flags+=("--socket=${item}")
  done
  for item in ${ALLOW_DEVICE[@]+"${ALLOW_DEVICE[@]}"}; do
    flags+=("--device=${item}")
  done
  for item in ${ALLOW_FEATURE[@]+"${ALLOW_FEATURE[@]}"}; do
    flags+=("--allow=${item}")
  done
  for item in ${ALLOW_FILESYSTEM[@]+"${ALLOW_FILESYSTEM[@]}"}; do
    flags+=("--filesystem=${item}")
  done
  for item in ${ALLOW_DBUS_TALK[@]+"${ALLOW_DBUS_TALK[@]}"}; do
    flags+=("--talk-name=${item}")
  done
  for item in ${ALLOW_DBUS_OWN[@]+"${ALLOW_DBUS_OWN[@]}"}; do
    flags+=("--own-name=${item}")
  done
  for item in ${ALLOW_SYSTEM_DBUS_TALK[@]+"${ALLOW_SYSTEM_DBUS_TALK[@]}"}; do
    flags+=("--system-talk-name=${item}")
  done
  for item in ${ALLOW_SYSTEM_DBUS_OWN[@]+"${ALLOW_SYSTEM_DBUS_OWN[@]}"}; do
    flags+=("--system-own-name=${item}")
  done
  for item in ${ALLOW_A11Y_OWN[@]+"${ALLOW_A11Y_OWN[@]}"}; do
    flags+=("--a11y-own-name=${item}")
  done
  for item in ${ALLOW_USB[@]+"${ALLOW_USB[@]}"}; do
    flags+=("--usb=${item}")
  done
  for item in ${PERSIST[@]+"${PERSIST[@]}"}; do
    flags+=("--persist=${item}")
  done
  for item in ${SET_ENV[@]+"${SET_ENV[@]}"}; do
    flags+=("--env=${item}")
  done
  for item in ${ADD_POLICY[@]+"${ADD_POLICY[@]}"}; do
    flags+=("--add-policy=${item}")
  done
  for item in ${ALLOW_DBUS_CALL[@]+"${ALLOW_DBUS_CALL[@]}"}; do
    flags+=("--dbus-call=${item}")
  done
  if [[ ${#ALLOW_DBUS_CALL[@]} -gt 0 ]]; then
    flags+=(--session-bus)
  fi

  # --- sanitized env ---
  local env=()
  local seen=""
  local v
  for v in HOME PATH XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS \
            WAYLAND_DISPLAY DISPLAY LANG \
            ${ALLOW_ENV[@]+"${ALLOW_ENV[@]}"}; do
    [[ ";${seen};" == *";${v};"* ]] && continue
    seen="${seen};${v}"
    [[ -n "${!v:-}" ]] && env+=("${v}=${!v}")
  done
  ulimit -c 0  # no core dumps to disk

  trap '_portal_cleanup' EXIT
  local rc=0
  env -i "${env[@]}" flatpak run "${flags[@]}" "$APP_ID" ${APP_ARGS[@]+"${APP_ARGS[@]}"} "$@" || rc=$?
  exit "$rc"
}
