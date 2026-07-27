#!/usr/bin/env bash
# lib/run.sh - stateless sandbox launcher
# shellcheck disable=SC2154  # _conf_name provided by adamas.sh

# --- shared portal state for one APP_ID ---
# the permission store is keyed by APP_ID, so instances of the same app cannot
# hold different portal policies at the same time.
# state lines: "<pid><TAB><config><TAB><shared><TAB><portal grants>"
_portal_state() { echo "${XDG_RUNTIME_DIR:-/tmp}/adamas-${APP_ID}.pids"; }

_portal_sig() {
  local -a entries=() sorted=()
  entries=(
    ${ALLOW_PORTAL[@]+"${ALLOW_PORTAL[@]/#/yes:}"}
    ${DENY_PORTAL[@]+"${DENY_PORTAL[@]/#/no:}"}
  )
  [[ ${#entries[@]} -eq 0 ]] \
    || mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)
  printf '%s' "${sorted[*]-}"
}

# readable form of a signature - the denies are mostly the baseline, so name
# only what the config opened
_portal_grants() {
  local -a granted=()
  local token
  for token in $1; do
    [[ "$token" == yes:* ]] && granted+=("${token#yes:}")
  done
  printf '%s' "${granted[*]-}"
}

# drop dead pids, print the surviving lines
_portal_prune() {
  local pf pid conf share sig live=""
  pf="$(_portal_state)"
  while IFS=$'\t' read -r pid conf share sig; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    live+="${pid}"$'\t'"${conf}"$'\t'"${share}"$'\t'"${sig}"$'\n'
    # redirections apply left to right - stderr must be silenced before the
    # input redirect, or the first run reports the missing state file
  done 2>/dev/null < "$pf"
  printf '%s' "$live" > "$pf"
  printf '%s' "$live"
}

# store policy for one app id: the union of every live instance's ALLOW_PORTAL,
# everything else denied. with one instance that is its own policy.
_portal_apply() {
  local pf pid conf share sig token key seen="" yes=""
  local -a tokens=() allow=() deny=()
  pf="$(_portal_state)"
  while IFS=$'\t' read -r pid conf share sig; do
    [[ -n "$pid" ]] || continue
    for token in $sig; do tokens+=("$token"); done
  done 2>/dev/null < "$pf"

  for token in ${tokens[@]+"${tokens[@]}"}; do
    [[ "$token" == yes:* ]] && yes+=" ${token#yes:}"
  done
  for token in ${tokens[@]+"${tokens[@]}"}; do
    key="${token#*:}"
    [[ " $seen " == *" $key "* ]] && continue
    seen+=" $key"
    if [[ " $yes " == *" $key "* ]]; then allow+=("$key"); else deny+=("$key"); fi
  done

  flatpak permission-reset "$APP_ID" 2>/dev/null || return 1
  local pe tbl id
  for pe in ${deny[@]+"${deny[@]}"}; do
    tbl="${pe%%:*}"; id="${pe#*:}"
    flatpak permission-set "$tbl" "$id" "$APP_ID" no || return 1
  done
  for pe in ${allow[@]+"${allow[@]}"}; do
    tbl="${pe%%:*}"; id="${pe#*:}"
    flatpak permission-set "$tbl" "$id" "$APP_ID" yes || return 1
  done
}

# _PORTAL_LOCK_FD is set while adamas_run holds the lock - re-locking the same
# file from the same process would deadlock, so reuse the fd it already owns
_portal_cleanup() {
  local pf fd live held=true
  pf="$(_portal_state)"
  if [[ -n "${_PORTAL_LOCK_FD:-}" ]]; then
    fd="$_PORTAL_LOCK_FD"
  else
    held=false
    exec {fd}>"${pf}.lock"
    flock "$fd"
  fi
  # grep exits 1 when the last line is dropped - that is the normal last-instance
  # case, not a failure, so the rewrite must not depend on its status
  { grep -v "^$$"$'\t' "$pf" 2>/dev/null || true; } > "${pf}.tmp"
  mv -f "${pf}.tmp" "$pf"
  live="$(_portal_prune)"
  if [[ -z "$live" ]]; then
    rm -f "$pf"
    flatpak permission-reset "$APP_ID" 2>/dev/null \
      || warn "permission-reset failed on exit - portal grants may be stale"
  else
    _portal_apply || warn "portal policy downgrade failed - grants may be stale"
  fi
  $held || flock -u "$fd"
}

# --- run (stateless sandbox) ---
adamas_run() {
  _require_safe_flatpak
  _is_installed "$APP_ID" || die "$APP_ID not installed"

  if [[ ${#ALLOW_DBUS_CALL[@]} -gt 0 ]] && ! _has_dbus_call; then
    die "ALLOW_DBUS_CALL needs a flatpak with --dbus-call (fork: q1sh101/flatpak, branch add-dbus-call-option) - drop it or use NEED_PORTAL=true"
  fi

  # --- portal policy (one policy per APP_ID, fail closed on conflict) ---
  local _pf _lock_fd _sig _live _pid _conf _pshare _psig _running _wanted
  _pf="$(_portal_state)"
  _sig="$(_portal_sig)"
  # hold the lock until the policy is in place - a sibling must not start earlier
  exec {_lock_fd}>"${_pf}.lock"
  flock "$_lock_fd"
  _live="$(_portal_prune)"

  # a shared ceiling needs both sides to have asked for it
  while IFS=$'\t' read -r _pid _conf _pshare _psig; do
    [[ -n "$_pid" ]] || continue
    [[ "$_psig" == "$_sig" ]] && continue
    [[ "$_pshare" == "true" && "$SHARE_PORTAL" == "true" ]] && continue
    _running="$(_portal_grants "$_psig")"
    _wanted="$(_portal_grants "$_sig")"
    die "$APP_ID is running as '$_conf' with portal grants [${_running:-none}]; '$_conf_name' needs [${_wanted:-none}] - the permission store is shared per app id, so close it first, give this config its own APP_ID, or set SHARE_PORTAL=true on both"
  done <<< "$_live"

  printf '%s\t%s\t%s\t%s\n' "$$" "$_conf_name" "$SHARE_PORTAL" "$_sig" >> "$_pf"
  _PORTAL_LOCK_FD="$_lock_fd"
  trap '_portal_cleanup' EXIT

  _portal_apply \
    || die "portal policy write failed - refusing to launch with unknown portal grants"
  flock -u "$_lock_fd"
  exec {_lock_fd}>&-
  unset _PORTAL_LOCK_FD

  # --- compile allow flags ---
  local flags=(--sandbox)
  local item
  # --file-forwarding only matters for @@-style args (patched .desktop entries)
  for item in ${APP_ARGS[@]+"${APP_ARGS[@]}"} "$@"; do
    [[ "$item" == *@@* ]] && { flags+=(--file-forwarding); break; }
  done
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
  # --sandbox turns the session bus proxy off; portals are unreachable without it
  if [[ "${NEED_PORTAL}" == "true" ]] || [[ ${#ALLOW_DBUS_CALL[@]} -gt 0 ]]; then
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

  local rc=0
  env -i "${env[@]}" flatpak run "${flags[@]}" "$APP_ID" ${APP_ARGS[@]+"${APP_ARGS[@]}"} "$@" || rc=$?
  exit "$rc"
}
