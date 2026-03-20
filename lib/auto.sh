#!/usr/bin/env bash
# lib/auto.sh - auto-harden all flatpak apps
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- check if app is already hardened (desktop patch or hook) ---
_is_hardened() {
  local conf_name="$1" app_id="$2" escaped_dir="$3"

  # check launcher hook (webapp path)
  local hook_name
  hook_name="$(set +eu; HOOK_NAME=''; source "${_dir}/apps/${conf_name}.conf" 2>/dev/null; printf '%s' "$HOOK_NAME")"
  if [[ -n "$hook_name" ]]; then
    local hook
    hook="$(_hook_dir)/${hook_name}"
    [[ -x "$hook" ]] && grep -q "adamas\\.sh.*run.*${conf_name}" "$hook" 2>/dev/null && return 0
    return 1
  fi

  # check .desktop patch (regular app path)
  local desktop
  desktop="$(_desktop_dir)/${app_id}.desktop"
  [[ -f "$desktop" ]] && grep -q "^Exec=\"\\?${escaped_dir}/adamas\\.sh\"\\? run ${conf_name}\( \|$\)" "$desktop" 2>/dev/null
}

# --- auto (scan + harden all) ---
adamas_auto() {
  _require_safe_flatpak

  # prevent concurrent execution
  local _lock_fd
  exec {_lock_fd}>"${XDG_RUNTIME_DIR:-/tmp}/adamas-auto.lock"
  flock -n "$_lock_fd" || { log "another adamas auto is running - skipping"; return 0; }

  local app_id app_name conf found target check_id
  local generated=0 hardened=0 skipped=0 failed=0
  local escaped_dir
  escaped_dir="$(_bre_escape "$_dir")"

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue

    # find existing config for this APP_ID
    found=false
    app_name=""
    for conf in "${_dir}/apps"/*.conf; do
      [[ -f "$conf" ]] || continue
      [[ "$(basename "$conf")" == "example.conf" ]] && continue
      check_id="$(set +eu; APP_ID=''; source "$conf" 2>/dev/null; printf '%s' "$APP_ID")"
      if [[ "$check_id" == "$app_id" ]]; then
        found=true
        app_name="$(basename "${conf%.conf}")"
        break
      fi
    done

    # generate minimal config if missing
    if ! $found; then
      app_name="${app_id##*.}"
      app_name="${app_name,,}"
      target="${_dir}/apps/${app_name}.conf"
      if [[ -f "$target" ]]; then
        app_name="${app_id//./-}"
        target="${_dir}/apps/${app_name}.conf"
      fi
      if [[ -f "$target" ]]; then
        warn "config collision: $target exists, skipping $app_id"
        ((skipped++)) || true
        continue
      fi
      printf 'APP_ID="%s"\n' "$app_id" > "$target"
      log "generated $app_name.conf"
      ((generated++)) || true
    fi

    # already hardened?
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
  done < <(flatpak list --app --columns=application 2>/dev/null | sort -u)

  if (( failed > 0 )); then
    die "auto: $generated generated, $hardened hardened, $skipped ok, $failed FAILED"
  fi
  ok "auto: $generated generated, $hardened hardened, $skipped already ok"
}
