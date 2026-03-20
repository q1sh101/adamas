#!/usr/bin/env bash
# lib/watch.sh - systemd automation for auto-hardening
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- watch install ---
adamas_watch_install() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  systemctl --user status >/dev/null 2>&1 || die "systemd --user not running"

  local udir
  udir="$(_unit_dir)"
  local exe="${_dir}/adamas.sh"
  mkdir -p "$udir" || die "cannot create $udir"

  # service: runs adamas auto
  cat > "${udir}/adamas-auto.service" <<EOF
[Unit]
Description=Adamas auto-harden Flatpak apps

[Service]
Type=oneshot
ExecStart="${exe}" auto
EOF

  # path: instant reaction to new installs (all flatpak installations)
  local path_unit="${udir}/adamas-watch.path"
  {
    echo "[Unit]"
    echo "Description=Watch for new Flatpak app installs"
    echo ""
    echo "[Path]"
    local edir
    while IFS= read -r edir; do
      echo "PathChanged=${edir}"
    done < <(_list_export_dirs)
    echo "Unit=adamas-auto.service"
  } > "$path_unit"
  cat >> "$path_unit" <<EOF

[Install]
WantedBy=default.target
EOF

  # timer: periodic reconcile (catches system installs, updates, edge cases)
  cat > "${udir}/adamas-reconcile.timer" <<EOF
[Unit]
Description=Periodic Adamas reconciliation

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

  # reconcile service (same action as auto)
  cat > "${udir}/adamas-reconcile.service" <<EOF
[Unit]
Description=Adamas periodic reconciliation

[Service]
Type=oneshot
ExecStart="${exe}" auto
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now adamas-watch.path \
    || die "failed to enable adamas-watch.path"
  systemctl --user enable --now adamas-reconcile.timer \
    || die "failed to enable adamas-reconcile.timer"

  ok "watch installed (path + 30min timer)"
}

# --- watch remove ---
adamas_watch_remove() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  local udir
  udir="$(_unit_dir)"

  systemctl --user disable --now adamas-watch.path 2>/dev/null || true
  systemctl --user disable --now adamas-reconcile.timer 2>/dev/null || true

  rm -f "${udir}/adamas-auto.service"
  rm -f "${udir}/adamas-watch.path"
  rm -f "${udir}/adamas-reconcile.timer"
  rm -f "${udir}/adamas-reconcile.service"

  systemctl --user daemon-reload
  ok "watch removed"
}

# --- watch status ---
adamas_watch_status() {
  command -v systemctl &>/dev/null || die "systemctl not found"
  systemctl --user status adamas-watch.path 2>&1 || true
  echo ""
  systemctl --user status adamas-reconcile.timer 2>&1 || true
}
