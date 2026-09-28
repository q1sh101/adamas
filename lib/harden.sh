#!/usr/bin/env bash
# lib/harden.sh - harden app launches via .desktop patch or launcher hook
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- install launcher hook (for webapps routed through an external launcher) ---
_install_hook() {
  local hook_name="$1"
  local hook="${HOOK_DIR}/${hook_name}"

  mkdir -p "${HOOK_DIR}" || die "cannot create ${HOOK_DIR}"

  # temp + rename (never writes through a symlinked hook)
  local tmp
  tmp="$(mktemp "${HOOK_DIR}/.${hook_name}.XXXXXX")" || die "cannot write in ${HOOK_DIR}"
  # shellcheck disable=SC2016  # $@ expands in the hook
  printf '#!/bin/sh\nexec "%s/adamas.sh" run "%s" "$@"\n' "${_dir}" "${_conf_name}" > "${tmp}" \
    && chmod 755 "${tmp}" && mv -fT "${tmp}" "${hook}" \
    || { rm -f "${tmp}"; die "cannot install ${hook}"; }
  ok "hook installed: ${hook}"
}

# --- harden (.desktop patch or launcher hook) ---
adamas_harden() {
  _require_safe_flatpak
  _is_installed "${APP_ID}" || die "${APP_ID} not installed"

  log "hardening ${_conf_name}..."

  if [[ -n "${HOOK_NAME:-}" ]]; then
    # webapp: install launcher hook (survives .desktop overwrites)
    _install_hook "${HOOK_NAME}"
  else
    # flatpak app: patch .desktop directly
    local dest_dir dest=""
    dest_dir="$(_desktop_dir)"
    mkdir -p "${dest_dir}" || die "cannot create ${dest_dir}"

    local src_desktop="" d
    _export_dirs
    for d in "${_EXPORT_DIRS[@]}"; do
      [[ -f "${d}/${APP_ID}.desktop" ]] && { src_desktop="${d}/${APP_ID}.desktop"; break; }
    done
    [[ -n "${src_desktop}" ]] || die "no .desktop found for ${APP_ID}"
    dest="${dest_dir}/${APP_ID}.desktop"

    local sed_dir bre_app_id tmp drift
    sed_dir="$(_sed_repl_escape "${_dir}")"
    bre_app_id="$(_bre_escape "${APP_ID}")"

    tmp="$(mktemp "${dest_dir}/.${APP_ID}.XXXXXX")" || die "cannot write in ${dest_dir}"
    # patch a temp copy: "flatpak run [--opts] <app id>" in every Exec= line (main +
    # Desktop Actions, keeps trailing args), drop DBusActivatable, then check the route
    sed -e "s|^Exec=[^ ]*flatpak run\( --[^ ]*\)* ${bre_app_id}\( .*\)\?$|Exec=\"${sed_dir}/adamas.sh\" run ${_conf_name}\2|" \
      -e '/^[[:space:]]*DBusActivatable[[:space:]]*=/d' \
      "${src_desktop}" > "${tmp}" || { rm -f "${tmp}"; die "cannot patch .desktop for ${APP_ID}"; }
    drift="$(_desktop_drift "${tmp}" "${_conf_name}")"
    if [[ -n "${drift}" ]]; then
      rm -f "${tmp}"
      die "${APP_ID}.desktop ${drift//$'\n'/, }"
    fi
    { chmod 644 "${tmp}" && mv -fT "${tmp}" "${dest}"; } \
      || { rm -f "${tmp}"; die "cannot install ${APP_ID}.desktop"; }
    ok "${_conf_name} hardened (all Exec= lines patched)"
  fi
}
