#!/usr/bin/env bash
# lib/harden.sh - harden app launches via .desktop patch or launcher hook
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- install launcher hook (for webapps routed through an external launcher) ---
_install_hook() {
  local hook_name="$1"
  local hook_dir
  hook_dir="$(_hook_dir)"
  local hook="${hook_dir}/${hook_name}"

  mkdir -p "$hook_dir" || die "cannot create $hook_dir"

  cat > "$hook" <<HOOK
#!/bin/sh
exec "${_dir}/adamas.sh" run "${_conf_name}" "\$@"
HOOK
  chmod +x "$hook" || die "cannot chmod $hook"
  ok "hook installed: $hook"
}

# --- harden (.desktop patch or launcher hook) ---
adamas_harden() {
  _require_safe_flatpak
  _is_installed "$APP_ID" || die "$APP_ID not installed"

  log "hardening ${_conf_name}..."

  if [[ -n "${HOOK_NAME:-}" ]]; then
    # webapp: install launcher hook (survives .desktop overwrites)
    _install_hook "$HOOK_NAME"
  else
    # flatpak app: patch .desktop directly
    local dest_dir dest=""
    dest_dir="$(_desktop_dir)"
    mkdir -p "$dest_dir" || die "cannot create $dest_dir"

    local src_desktop="" d
    while IFS= read -r d; do
      [[ -f "${d}/${APP_ID}.desktop" ]] && { src_desktop="${d}/${APP_ID}.desktop"; break; }
    done < <(_list_export_dirs)
    [[ -n "$src_desktop" ]] || die "no .desktop found for $APP_ID"
    dest="${dest_dir}/${APP_ID}.desktop"
    cp "$src_desktop" "$dest" || die "cannot copy .desktop for $APP_ID"

    local escaped_dir sed_dir bre_app_id
    escaped_dir="$(_bre_escape "$_dir")"
    sed_dir="$(_sed_repl_escape "$_dir")"
    bre_app_id="$(_bre_escape "$APP_ID")"

    # patch all Exec= lines (main + Desktop Actions, preserves trailing args)
    sed -i "s|^Exec=.*${bre_app_id}\(.*\)|Exec=\"${sed_dir}/adamas.sh\" run ${_conf_name}\1|" "$dest"

    if ! grep -q "^Exec=\"${escaped_dir}/adamas\\.sh\" run ${_conf_name}" "$dest" 2>/dev/null; then
      die "${APP_ID}.desktop: no Exec lines matched"
    fi
    if grep -q "^Exec=.*flatpak " "$dest" 2>/dev/null; then
      die "${APP_ID}.desktop: unpatched Exec= lines with bare flatpak run remain"
    fi
    ok "${_conf_name} hardened (all Exec= lines patched)"
  fi
}
