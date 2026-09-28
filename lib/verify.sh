#!/usr/bin/env bash
# lib/verify.sh - desktop route integrity check
# shellcheck disable=SC2154  # _dir, _conf_name provided by adamas.sh

# --- verify (desktop route or launcher hook integrity) ---
adamas_verify() {
  _require_safe_flatpak
  _is_installed "${APP_ID}" || die "${APP_ID} not installed"

  log "verifying ${_conf_name}..."

  local fails=0

  if [[ "${AUTO_SKIP}" == "true" ]]; then
    ok "${_conf_name}: route not managed by adamas (AUTO_SKIP=true)"
    return 0
  fi

  if [[ -n "${HOOK_NAME:-}" ]]; then
    # webapp: check launcher hook
    local hook
    hook="${HOOK_DIR}/${HOOK_NAME}"
    local hook_escaped_dir
    hook_escaped_dir="$(_bre_escape "${_dir}")"
    if [[ ! -x "${hook}" ]]; then
      warn "DRIFT: launcher hook missing or not executable: ${hook}"
      ((fails++)) || true
    elif ! grep -q "\"${hook_escaped_dir}/adamas\\.sh\" run \"${_conf_name}\"" "${hook}" 2>/dev/null; then
      warn "DRIFT: hook does not route to adamas run ${_conf_name}"
      ((fails++)) || true
    fi
  else
    # flatpak app: check .desktop route
    local ddir
    ddir="$(_desktop_dir)"
    local desktop="${ddir}/${APP_ID}.desktop"
    if [[ -f "${desktop}" ]]; then
      local reason
      while IFS= read -r reason; do
        [[ -n "${reason}" ]] || continue
        warn "DRIFT: ${APP_ID}.desktop ${reason}"
        ((fails++)) || true
      done <<< "$(_desktop_drift "${desktop}" "${_conf_name}")"
    else
      warn "DRIFT: ${APP_ID}.desktop not found in ${ddir}"
      ((fails++)) || true
    fi
  fi

  (( fails == 0 )) || die "${fails} drift(s) detected - run adamas harden ${_conf_name}"
  ok "${_conf_name} clean"
}
