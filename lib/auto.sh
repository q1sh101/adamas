#!/usr/bin/env bash
# lib/auto.sh - auto-harden all flatpak apps
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- read minimal config fields after safety checks ---
_conf_var() {
  local conf="$1" name="$2"
  (
    _check_conf_safe "${conf}"
    set +eu
    # shellcheck disable=SC2034  # values are read indirectly after sourcing
    APP_ID='' HOOK_NAME=''
    # shellcheck disable=SC1090
    source "${conf}" 2>/dev/null
    printf '%s' "${!name:-}"
  )
}

# --- does this APP_ID export a .desktop anywhere? ---
_has_desktop() {
  local app_id="$1" d
  _export_dirs
  for d in "${_EXPORT_DIRS[@]}"; do
    [[ -f "${d}/${app_id}.desktop" ]] && return 0
  done
  return 1
}

# --- auto (scan + harden all) ---
adamas_auto() {
  _require_safe_flatpak
  # deterministic config order regardless of the caller's locale (systemd runs under C)
  local LC_ALL=C

  # prevent concurrent execution
  local _lock_fd
  _require_runtime_dir
  exec {_lock_fd}>"${XDG_RUNTIME_DIR}/adamas-auto.lock"
  flock -n "${_lock_fd}" || { log "another adamas auto is running - skipping"; return 0; }

  local app_id app_name conf target check_id apps
  local generated=0 hardened=0 skipped=0 failed=0

  # an unreadable app list is a failure, not an empty system
  apps="$(flatpak list --app --columns=application)" || die "cannot list installed apps"

  while IFS= read -r app_id; do
    [[ -n "${app_id}" ]] || continue

    # every config for this APP_ID - several webapps can share one app
    local -a matches=()
    while IFS= read -r conf; do
      [[ "$(basename "${conf}")" == "example.conf" ]] && continue
      check_id="$(_conf_var "${conf}" APP_ID)"
      [[ "${check_id}" == "${app_id}" ]] && matches+=("$(basename "${conf%.conf}")")
    done < <(_list_confs)

    # generate minimal config if missing
    if (( ${#matches[@]} == 0 )); then
      _draft_name "${app_id}"
      app_name="${_DRAFT_NAME}"
      target="${_dir}/apps/${app_name}.conf"
      if _conf_path "${app_name}" || [[ -e "${target}" || -L "${target}" ]]; then
        warn "config collision: ${target} exists, skipping ${app_id}"
        ((failed++)) || true
        continue
      fi
      # a zero-permission config breaks the app - review it before routing launches
      { printf 'APP_ID="%s"\nAUTO_SKIP=true   # review permissions, then set false\n' \
          "${app_id}" > "${target}" && chmod go-w "${target}"; } || die "cannot write ${target}"
      log "generated ${app_name}.conf (review it, then set AUTO_SKIP=false)"
      ((generated++)) || true
      ((skipped++)) || true
      continue
    fi

    for app_name in "${matches[@]}"; do
      _conf_path "${app_name}" || continue
      conf="${_CONF_PATH}"

      if [[ "$(_conf_var "${conf}" AUTO_SKIP)" == "true" ]]; then
        ((skipped++)) || true
        continue
      fi

      # CLI-only apps have no .desktop to patch - nothing to do, not a failure
      if [[ -z "$(_conf_var "${conf}" HOOK_NAME)" ]] && ! _has_desktop "${app_id}"; then
        log "${app_name}: no .desktop exported - nothing to route"
        ((skipped++)) || true
        continue
      fi

      # route intact - nothing to do
      if ( _load_conf "${app_name}" && adamas_verify ) >/dev/null 2>&1; then
        ((skipped++)) || true
        continue
      fi

      # harden in subshell (die won't kill parent)
      if ( _load_conf "${app_name}" && adamas_harden ); then
        ((hardened++)) || true
      else
        warn "failed to harden ${app_name}"
        ((failed++)) || true
      fi
    done
  done < <(printf '%s\n' "${apps}" | sort -u)

  if (( failed > 0 )); then
    die "auto: ${generated} generated, ${hardened} hardened, ${skipped} ok, ${failed} FAILED"
  fi
  ok "auto: ${generated} generated, ${hardened} hardened, ${skipped} already ok"
}
