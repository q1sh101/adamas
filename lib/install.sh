#!/usr/bin/env bash
# lib/install.sh - flatpak install from Flathub

# --- install (idempotent) ---
adamas_install() {
  _require_safe_flatpak

  if _is_installed "$APP_ID"; then
    ok "$APP_ID already installed"
    return 0
  fi

  log "installing $APP_ID..."
  flatpak install --user --noninteractive flathub "$APP_ID" \
    || die "install failed: $APP_ID"

  # trust nothing - verify it landed
  _is_installed "$APP_ID" || die "install succeeded but $APP_ID not found"

  ok "$APP_ID installed"
}
