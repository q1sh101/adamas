#!/usr/bin/env bash
# lib/trace.sh - observe app needs and generate draft config
# shellcheck disable=SC2154  # _dir provided by adamas.sh

# --- metadata parser ---
# populates _T_* arrays from flatpak manifest metadata
_parse_metadata() {
  local app_id="$1"

  local meta
  meta="$(flatpak info --show-metadata "$app_id" 2>/dev/null)" \
    || die "cannot read metadata for $app_id"

  # reset trace arrays
  _T_SHARE=() _T_SOCKET=() _T_DEVICE=() _T_FEATURE=()
  _T_FILESYSTEM=() _T_PERSIST=()
  _T_DBUS_TALK=() _T_DBUS_OWN=()
  _T_SYSTEM_DBUS_TALK=() _T_SYSTEM_DBUS_OWN=()
  _T_DBUS_CALL=() _T_PORTAL=()
  _T_UNFILTERED=false

  local section="" key val
  while IFS= read -r line; do
    # section header
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # skip empty lines and lines without =
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"

    # --- [Context] ---
    if [[ "$section" == "Context" ]]; then
      local items item
      IFS=';' read -ra items <<< "$val"
      for item in "${items[@]}"; do
        [[ -n "$item" ]] || continue
        case "$key" in
          shared)     _T_SHARE+=("$item") ;;
          sockets)    _T_SOCKET+=("$item") ;;
          devices)    _T_DEVICE+=("$item") ;;
          features)   _T_FEATURE+=("$item") ;;
          filesystems) _T_FILESYSTEM+=("$item") ;;
          persistent) _T_PERSIST+=("$item") ;;
        esac
      done
    fi

    # --- [Session Bus Policy] ---
    if [[ "$section" == "Session Bus Policy" ]]; then
      case "$val" in
        own)  _T_DBUS_OWN+=("$key") ;;
        talk) _T_DBUS_TALK+=("$key") ;;
      esac
    fi

    # --- [System Bus Policy] ---
    if [[ "$section" == "System Bus Policy" ]]; then
      case "$val" in
        own)  _T_SYSTEM_DBUS_OWN+=("$key") ;;
        talk) _T_SYSTEM_DBUS_TALK+=("$key") ;;
      esac
    fi

    # [Environment] intentionally skipped - manifest env is package context, not user intent
  done <<< "$meta"
}

# --- resolve proxy PID to D-Bus unique name ---
_resolve_sender() {
  local proxy_pid="$1"
  local name pid
  while IFS= read -r name; do
    [[ "$name" == :* ]] || continue
    pid="$(gdbus call --session \
      --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.GetConnectionUnixProcessID \
      "$name" 2>/dev/null | tr -dc '0-9')" || continue
    [[ "$pid" == "$proxy_pid" ]] && { printf '%s' "$name"; return 0; }
  done < <(gdbus call --session \
    --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListNames 2>/dev/null \
    | tr ',' '\n' | tr -d "[]' ")
  return 1
}

# --- portal interface to portal permission mapping ---
_portal_to_permission() {
  case "$1" in
    org.freedesktop.portal.ScreenCast)    echo "screencast:screencast" ;;
    org.freedesktop.portal.Camera)        echo "devices:camera" ;;
    org.freedesktop.portal.Location)      echo "location:location" ;;
    org.freedesktop.portal.Notification)  echo "notifications:notification" ;;
    org.freedesktop.portal.Background)    echo "background:background" ;;
    org.freedesktop.portal.Screenshot)    echo "screenshot:screenshot" ;;
    *) return 1 ;;
  esac
}

# --- dbus log parser ---
# reads dbus-monitor log, filters by sender, populates _T_DBUS_CALL and _T_PORTAL
_parse_dbus_log() {
  local log_file="$1" app_sender="$2"

  local seen_iface="" dest iface sender
  while IFS= read -r line; do
    # method call lines: "method call ... sender=:1.XX -> destination=org.freedesktop.portal.Desktop ... interface=org.freedesktop.portal.Settings; member=ReadAll"
    [[ "$line" == *"method call"* ]] || continue

    # extract sender
    sender=""
    [[ "$line" =~ sender=([^ ]+) ]] && sender="${BASH_REMATCH[1]}"

    # filter by app sender (if known)
    if [[ -n "$app_sender" && "$sender" != "$app_sender" ]]; then
      continue
    fi

    # extract destination (dbus-monitor uses "destination=", not "dest=")
    [[ "$line" =~ destination=([^ ]+) ]] || continue
    dest="${BASH_REMATCH[1]}"

    # extract interface and member
    [[ "$line" =~ interface=([^ ;]+) ]] || continue
    iface="${BASH_REMATCH[1]}"
    [[ "$line" =~ member=([^ ;]+) ]] || continue

    # skip D-Bus internal methods
    [[ "$iface" == "org.freedesktop.DBus."* ]] && continue

    # accept if destination OR interface is a portal
    [[ "$dest" == org.freedesktop.portal.* || "$iface" == org.freedesktop.portal.* ]] || continue

    # resolve dest to well-known name when unique name was used
    local call_dest="$dest"
    if [[ "$dest" == :* ]]; then
      # only Documents has a separate bus name; everything else lives on Desktop
      case "$iface" in
        org.freedesktop.portal.Documents*|org.freedesktop.portal.FileTransfer*)
          call_dest="org.freedesktop.portal.Documents" ;;
        *) call_dest="org.freedesktop.portal.Desktop" ;;
      esac
    fi

    # deduplicate by (call_dest, interface)
    local key="${call_dest}=${iface}"
    [[ ";${seen_iface};" == *";${key};"* ]] && continue
    seen_iface="${seen_iface};${key}"

    # add ALLOW_DBUS_CALL entry
    _T_DBUS_CALL+=("${call_dest}=${iface}.*")

    # map to portal permission if applicable
    local perm
    perm="$(_portal_to_permission "$iface")" && _T_PORTAL+=("$perm")
  done < "$log_file"
  return 0
}

# --- conf renderer ---
# output draft .conf to stdout
_render_conf() {
  local app_id="$1"

  # helper: format array as (val1 val2) or ()
  _fmt_arr() {
    local -n _arr="$1"
    if [[ ${#_arr[@]} -eq 0 ]]; then
      printf '()'
    else
      printf '(%s)' "${_arr[*]}"
    fi
  }

  # helper: format array with quoting for multi-word entries
  _fmt_arr_quoted() {
    local -n _arr="$1"
    if [[ ${#_arr[@]} -eq 0 ]]; then
      printf '()'
      return
    fi
    local item
    printf '(\n'
    for item in "${_arr[@]}"; do
      printf '  "%s"\n' "$item"
    done
    printf ')'
  }

  printf '# generated by: adamas trace %s\n' "$app_id"
  printf '# source: flatpak info --show-metadata %s\n' "$app_id"
  printf '#\n'
  printf '# ⚠  this is a DRAFT - review before saving\n'
  printf '# ⚠  remove permissions the app does not need\n'
  if [[ "${_T_UNFILTERED:-false}" == "true" ]]; then
    printf '#\n'
    printf '# ⚠  WARNING: sender could not be resolved - runtime D-Bus calls\n'
    printf '# ⚠  may include activity from OTHER apps. review carefully.\n'
  fi
  printf '\n'
  printf 'APP_ID="%s"\n' "$app_id"

  printf '\n# --- share ---\n'
  printf 'ALLOW_SHARE=%s\n' "$(_fmt_arr _T_SHARE)"

  printf '\n# --- socket ---\n'
  printf 'ALLOW_SOCKET=%s\n' "$(_fmt_arr _T_SOCKET)"

  printf '\n# --- device ---\n'
  printf 'ALLOW_DEVICE=%s\n' "$(_fmt_arr _T_DEVICE)"

  printf '\n# --- feature ---\n'
  printf 'ALLOW_FEATURE=%s\n' "$(_fmt_arr _T_FEATURE)"

  printf '\n# --- filesystem ---\n'
  printf 'ALLOW_FILESYSTEM=%s\n' "$(_fmt_arr _T_FILESYSTEM)"

  printf '\n# --- session D-Bus ---\n'
  printf 'ALLOW_DBUS_TALK=%s\n' "$(_fmt_arr _T_DBUS_TALK)"
  printf 'ALLOW_DBUS_OWN=%s\n' "$(_fmt_arr _T_DBUS_OWN)"

  printf '\n# --- system D-Bus ---\n'
  printf 'ALLOW_SYSTEM_DBUS_TALK=%s\n' "$(_fmt_arr _T_SYSTEM_DBUS_TALK)"
  printf 'ALLOW_SYSTEM_DBUS_OWN=%s\n' "$(_fmt_arr _T_SYSTEM_DBUS_OWN)"

  printf '\n# --- a11y D-Bus ---\n'
  printf 'ALLOW_A11Y_OWN=()\n'

  printf '\n# --- USB ---\n'
  printf 'ALLOW_USB=()\n'

  printf '\n# --- persist ---\n'
  printf '# without this, app data lives in RAM and dies on exit\n'
  printf '# (.) = full disk | e.g. (.mozilla .config/app) = by name to disk\n'
  printf 'PERSIST=%s\n' "$(_fmt_arr _T_PERSIST)"

  printf '\n# --- policy ---\n'
  printf 'ADD_POLICY=()\n'

  printf '\n# --- env ---\n'
  printf '# baseline: HOME PATH XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS\n'
  printf '#   WAYLAND_DISPLAY DISPLAY LANG\n'
  printf 'ALLOW_ENV=()\n'
  printf 'SET_ENV=()\n'

  printf '\n# --- portal ---\n'
  printf '# 8 denied by default: camera | microphone | speakers | location\n'
  printf '#   notifications | screenshot | screencast | background\n'
  printf 'ALLOW_PORTAL=%s\n' "$(_fmt_arr _T_PORTAL)"

  if [[ ${#_T_DBUS_CALL[@]} -gt 0 ]]; then
    printf '\n# --- D-Bus call filtering (runtime observed) ---\n'
    printf 'ALLOW_DBUS_CALL=%s\n' "$(_fmt_arr_quoted _T_DBUS_CALL)"
  fi
}

# --- save or print draft ---
_output_conf() {
  local app_id="$1" save="$2"
  if $save; then
    local name
    name="${app_id##*.}"
    name="${name,,}"
    local conf="${_dir}/apps/${name}.conf"
    if [[ -f "$conf" ]]; then
      name="${app_id//./-}"
      conf="${_dir}/apps/${name}.conf"
    fi
    [[ -f "$conf" ]] && die "config already exists: $conf"
    _render_conf "$app_id" > "$conf"
    ok "draft written: $conf"
  else
    _render_conf "$app_id"
  fi
}

# --- static analysis ---
_trace_static() {
  local app_id="$1" save="$2"
  _parse_metadata "$app_id"
  _output_conf "$app_id" "$save"
}

# --- runtime observation ---
_trace_runtime() {
  local app_id="$1" save="$2"

  # static first - populates _T_* arrays
  _parse_metadata "$app_id"

  # snapshot existing proxy PIDs
  local proxy_pids_before
  proxy_pids_before="$(pgrep xdg-dbus-proxy 2>/dev/null | sort)" || true

  # start dbus-monitor (background)
  local dbus_log
  dbus_log="$(mktemp /tmp/adamas-trace-XXXXXX)"
  dbus-monitor --session \
    "type='method_call',destination='org.freedesktop.portal.Desktop'" \
    "type='method_call',destination='org.freedesktop.portal.Documents'" \
    > "$dbus_log" 2>/dev/null &
  local monitor_pid=$!

  # cleanup on exit: kill monitor, remove tmpfile
  trap 'kill "$monitor_pid" 2>/dev/null; rm -f "$dbus_log"' EXIT

  # launch app (permissive - no --sandbox, uses manifest permissions)
  warn "runtime trace runs without sandbox" >&2
  log "trace active - use the app, then close it or Ctrl+C" >&2
  flatpak run "$app_id" &
  local app_pid=$!

  # wait for proxy to appear (retry up to 5 times)
  local proxy_pids_after app_sender="" new_proxy="" attempt
  for attempt in 1 2 3 4 5; do
    sleep 2
    proxy_pids_after="$(pgrep xdg-dbus-proxy 2>/dev/null | sort)" || true
    new_proxy="$(comm -13 <(echo "$proxy_pids_before") <(echo "$proxy_pids_after") | head -1)" || true
    [[ -n "$new_proxy" ]] && break
  done

  if [[ -n "$new_proxy" ]]; then
    app_sender="$(_resolve_sender "$new_proxy")" || true
    [[ -n "$app_sender" ]] && log "sender resolved: $app_sender (proxy PID $new_proxy)" >&2
  fi

  if [[ -z "$app_sender" ]]; then
    warn "could not resolve app sender - log may include other apps" >&2
    _T_UNFILTERED=true
  else
    _T_UNFILTERED=false
  fi

  # wait for app to exit
  local app_rc=0
  wait "$app_pid" 2>/dev/null || app_rc=$?

  if [[ $app_rc -ne 0 ]]; then
    # cleanup before bail
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    rm -f "$dbus_log"
    trap - EXIT
    die "app exited with code $app_rc - trace aborted"
  fi

  # stop monitor (may already be dead)
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true

  # parse collected log
  _parse_dbus_log "$dbus_log" "$app_sender"
  rm -f "$dbus_log"

  local call_count=${#_T_DBUS_CALL[@]}
  local portal_count=${#_T_PORTAL[@]}
  log "observed: $call_count D-Bus call rules, $portal_count portal permissions" >&2

  # disarm cleanup trap (trace is terminal - no prior trap to restore)
  trap - EXIT

  # render
  _output_conf "$app_id" "$save"
}

# --- trace (observe + generate draft) ---
adamas_trace() {
  local app_id="$1"; shift
  local runtime=false save=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --runtime) runtime=true ;;
      --save)    save=true ;;
      *)         die "unknown flag: $arg" ;;
    esac
  done

  _require_flatpak
  _is_installed "$app_id" || die "$app_id not installed"

  log "tracing ${app_id}..." >&2

  if $runtime; then
    _trace_runtime "$app_id" "$save"
  else
    _trace_static "$app_id" "$save"
  fi
}
