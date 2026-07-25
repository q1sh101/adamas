#!/usr/bin/env bash
# lib/auto.sh - auto-harden all flatpak apps
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- read minimal config fields after safety checks ---
_conf_var() {
  local conf="$1" name="$2"
  (
    _check_conf_safe "$conf"
    set +eu
    # shellcheck disable=SC2034  # values are read indirectly after sourcing
    APP_ID='' HOOK_NAME=''
    # shellcheck disable=SC1090
    source "$conf" 2>/dev/null
    printf '%s' "${!name:-}"
  )
}

# --- check if app is already hardened (desktop patch or hook) ---
_is_hardened() {
  local conf_name="$1" app_id="$2" escaped_dir="$3"
  local conf
  _conf_path "$conf_name" || return 1
  conf="$_CONF_PATH"

  # check launcher hook (webapp path)
  local hook_name
  hook_name="$(_conf_var "$conf" HOOK_NAME)"
  if [[ -n "$hook_name" ]]; then
    local hook
    hook="$(_conf_var "$conf" HOOK_DIR)/${hook_name}"
    [[ -x "$hook" ]] \
      && grep -q "\"${escaped_dir}/adamas\\.sh\" run \"${conf_name}\"" "$hook" 2>/dev/null \
      && return 0
    return 1
  fi

  # check .desktop patch (regular app path)
  local desktop
  desktop="$(_desktop_dir)/${app_id}.desktop"
  [[ -f "$desktop" ]] && grep -q "^Exec=\"\\?${escaped_dir}/adamas\\.sh\"\\? run ${conf_name}\( \|$\)" "$desktop" 2>/dev/null
}

# --- does this APP_ID export a .desktop anywhere? ---
_has_desktop() {
  local app_id="$1" d
  while IFS= read -r d; do
    [[ -f "${d}/${app_id}.desktop" ]] && return 0
  done < <(_list_export_dirs)
  return 1
}

# --- auto (scan + harden all) ---
adamas_auto() {
  _require_safe_flatpak
  # deterministic config order regardless of the caller's locale (systemd runs under C)
  local LC_ALL=C

  # prevent concurrent execution
  local _lock_fd
  exec {_lock_fd}>"${XDG_RUNTIME_DIR:-/tmp}/adamas-auto.lock"
  flock -n "$_lock_fd" || { log "another adamas auto is running - skipping"; return 0; }

  local app_id app_name conf target check_id
  local generated=0 hardened=0 skipped=0 failed=0
  local escaped_dir
  escaped_dir="$(_bre_escape "$_dir")"

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue

    # every config for this APP_ID - several webapps can share one app
    local -a matches=()
    while IFS= read -r conf; do
      [[ "$(basename "$conf")" == "example.conf" ]] && continue
      check_id="$(_conf_var "$conf" APP_ID)"
      [[ "$check_id" == "$app_id" ]] && matches+=("$(basename "${conf%.conf}")")
    done < <(_list_confs)

    # generate minimal config if missing
    if (( ${#matches[@]} == 0 )); then
      app_name="${app_id##*.}"
      app_name="${app_name,,}"
      target="${_dir}/apps/${app_name}.conf"
      if _conf_path "$app_name"; then
        app_name="${app_id//./-}"
        target="${_dir}/apps/${app_name}.conf"
      fi
      if _conf_path "$app_name"; then
        warn "config collision: $target exists, skipping $app_id"
        ((skipped++)) || true
        continue
      fi
      # a zero-permission config breaks the app - review it before routing launches
      printf 'APP_ID="%s"\nAUTO_SKIP=true   # review permissions, then set false\n' \
        "$app_id" > "$target"
      log "generated $app_name.conf (review it, then set AUTO_SKIP=false)"
      ((generated++)) || true
      ((skipped++)) || true
      continue
    fi

    for app_name in "${matches[@]}"; do
      _conf_path "$app_name" || continue
      conf="$_CONF_PATH"

      if [[ "$(_conf_var "$conf" AUTO_SKIP)" == "true" ]]; then
        ((skipped++)) || true
        continue
      fi

      # CLI-only apps have no .desktop to patch - nothing to do, not a failure
      if [[ -z "$(_conf_var "$conf" HOOK_NAME)" ]] && ! _has_desktop "$app_id"; then
        log "$app_name: no .desktop exported - nothing to route"
        ((skipped++)) || true
        continue
      fi

      if _is_hardened "$app_name" "$app_id" "$escaped_dir"; then
        ((skipped++)) || true
        continue
      fi

      # harden in subshell (die won't kill parent)
      if ( _load_conf "$app_name" && adamas_harden ); then
        ((hardened++)) || true
      else
        warn "failed to harden $app_name"
        ((failed++)) || true
      fi
    done
  done < <(flatpak list --app --columns=application 2>/dev/null | sort -u)

  if (( failed > 0 )); then
    die "auto: $generated generated, $hardened hardened, $skipped ok, $failed FAILED"
  fi
  ok "auto: $generated generated, $hardened hardened, $skipped already ok"
}
