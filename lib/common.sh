#!/usr/bin/env bash
# lib/common.sh - shared primitives

# --- colors ---
if [[ -t 1 ]] || [[ -n "${JOURNAL_STREAM:-}" ]]; then
  _r='\033[0m'
  _blue='\033[1;34m'
  _green='\033[1;32m'
  _yellow='\033[1;33m'
  _red='\033[1;31m'
else
  _r='' _blue='' _green='' _yellow='' _red=''
fi

# --- logging ---
log()  { echo -e "  ${_blue}[adamas]${_r} $*"; }
ok()   { echo -e "  ${_green}[  ok ]${_r} $*"; }
warn() { echo -e "  ${_yellow}[ warn]${_r} $*" >&2; }
die()  { echo -e "  ${_red}[error]${_r} $*" >&2; exit 1; }

# --- flatpak ---
_require_flatpak() {
  command -v flatpak &>/dev/null || die "flatpak not found"
}

# require flatpak versions with upstream sandbox escape fixes
_require_safe_flatpak() {
  _require_flatpak
  local ver major minor patch
  ver="$(flatpak --version | awk '{print $2}')"
  IFS='.' read -r major minor patch <<< "$ver"
  major="${major%%[!0-9]*}"
  minor="${minor%%[!0-9]*}"
  minor="${minor:-0}"
  patch="${patch%%[!0-9]*}"
  patch="${patch:-0}"

  local safe=false
  if   (( major > 1 ));                                 then safe=true
  elif (( major == 1 && minor >= 16 ));                 then safe=true
  elif (( major == 1 && minor == 15 && patch >= 10 ));  then safe=true
  elif (( major == 1 && minor == 14 && patch >= 10 ));  then safe=true
  fi

  if ! $safe; then
    local min="1.14.10"
    (( major == 1 && minor == 15 )) && min="1.15.10"
    die "flatpak $ver is below required safe baseline - upgrade to >= $min"
  fi
}

_is_installed() { flatpak info "$1" &>/dev/null; }

# --- paths ---
_desktop_dir() {
  echo "${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
}

_unit_dir() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"; }

_hook_dir() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}/hifox/hooks/webapp"; }

# all flatpak .desktop export dirs (user + system + custom installations)
_list_export_dirs() {
  echo "${XDG_DATA_HOME:-${HOME}/.local/share}/flatpak/exports/share/applications"
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    echo "${dir}/exports/share/applications"
  done < <(flatpak --installations 2>/dev/null)
}

# --- regex ---
_bre_escape() {
  local s="${1//\\/\\\\}"
  s="${s//./\\.}"; s="${s//\[/\\[}"; s="${s//\]/\\]}"
  s="${s//\*/\\*}"; s="${s//\^/\\^}"; s="${s//\$/\\$}"
  printf '%s' "$s"
}

# escape string for sed replacement (delimiter |)
_sed_repl_escape() {
  local s="${1//\\/\\\\}"
  s="${s//&/\\&}"; s="${s//|/\\|}"
  printf '%s' "$s"
}

# --- validation ---
_validate_enum() {
  local name="$1" valid="$2"
  local -n _arr="$name"
  local item
  for item in ${_arr[@]+"${_arr[@]}"}; do
    [[ ";${valid};" == *";${item};"* ]] \
      || die "invalid $name: $item (valid: $valid)"
  done
}

_validate_fmt() {
  local name="$1" pattern="$2" hint="$3"
  local -n _arr="$name"
  local item
  for item in ${_arr[@]+"${_arr[@]}"}; do
    [[ "$item" =~ $pattern ]] \
      || die "invalid $name format: $item (expected: $hint)"
  done
}

# --- config safety (defense-in-depth before source) ---
_check_conf_safe() {
  local conf="$1"
  [[ ! -L "$conf" ]]            || die "config is a symlink: $conf"
  local owner; owner="$(stat -c '%u' "$conf")" || die "cannot stat $conf"
  [[ "$owner" == "$(id -u)" ]]  || die "config not owned by current user: $conf"
  local perms; perms="$(stat -c '%a' "$conf")" || die "cannot stat $conf"
  [[ ! "${perms: -2:1}" =~ [2367] && ! "${perms: -1}" =~ [2367] ]] \
    || die "config is group/world-writable ($perms): $conf"
}

_check_conflict() {
  local a_name="$1" b_name="$2"
  local -n _a="$a_name" _b="$b_name"
  local x y
  for x in ${_a[@]+"${_a[@]}"}; do
    for y in ${_b[@]+"${_b[@]}"}; do
      [[ "$x" != "$y" ]] \
        || die "conflict: $x in both $a_name and $b_name"
    done
  done
}

_validate() {
  _validate_fmt APP_ID '^[a-zA-Z][a-zA-Z0-9_-]*(\.[a-zA-Z0-9_-]+)+$' \
    "reverse-DNS (org.example.App)"

  _validate_enum ALLOW_SHARE   "network;ipc"
  _validate_enum ALLOW_SOCKET  "x11;wayland;fallback-x11;pulseaudio;session-bus;system-bus;ssh-auth;pcsc;cups;gpg-agent;inherit-wayland-socket"
  _validate_enum ALLOW_DEVICE  "dri;input;usb;kvm;shm;all"
  _validate_enum ALLOW_FEATURE "devel;multiarch;bluetooth;canbus;per-app-dev-shm"

  local dbus='^[a-zA-Z_][a-zA-Z0-9_.-]*(\.\*)?$'
  _validate_fmt ALLOW_DBUS_TALK        "$dbus" "D-Bus name (org.example.Name)"
  _validate_fmt ALLOW_DBUS_OWN         "$dbus" "D-Bus name (org.example.Name)"
  _validate_fmt ALLOW_SYSTEM_DBUS_TALK "$dbus" "D-Bus name (org.example.Name)"
  _validate_fmt ALLOW_SYSTEM_DBUS_OWN  "$dbus" "D-Bus name (org.example.Name)"
  _validate_fmt ALLOW_A11Y_OWN         "$dbus" "D-Bus name (org.example.Name)"
  _validate_fmt ALLOW_FILESYSTEM '^[a-zA-Z~/][a-zA-Z0-9_./-]*(:(ro|rw|create))?$' \
    "path or xdg-name[:ro|rw|create]"
  # block overly broad filesystem access
  local _fs
  for _fs in ${ALLOW_FILESYSTEM[@]+"${ALLOW_FILESYSTEM[@]}"}; do
    local _fp="${_fs%%:*}"
    [[ "$_fp" != "/" && "$_fp" != "~" && "$_fp" != "home" && "$_fp" != "host" ]] \
      || die "ALLOW_FILESYSTEM: '$_fp' is too broad"
    [[ "$_fp" != *".."* ]] || die "ALLOW_FILESYSTEM: path traversal in '$_fs'"
  done

  # allow single dot for full-home persist
  _validate_fmt PERSIST      '^(\.|\.?[a-zA-Z0-9][a-zA-Z0-9._/-]*)$'  "relative path (.app-data)"
  _validate_fmt ALLOW_ENV    '^[A-Za-z_][A-Za-z_0-9]*$'           "ENV_VAR_NAME"
  _validate_fmt SET_ENV      '^[A-Za-z_][A-Za-z_0-9]*=.+$'       "VAR=VALUE"

  # block security-sensitive env vars
  local _env_blocked="LD_PRELOAD;LD_LIBRARY_PATH;LD_AUDIT;LD_DEBUG;LD_PROFILE"
  _env_blocked+=";FLATPAK_ID;FLATPAK_ARCH;FLATPAK_DEST;FLATPAK_BUILDER_BUILDDIR"
  _env_blocked+=";BASH_ENV;ENV;CDPATH;GLOBIGNORE"
  local _ev
  for _ev in ${ALLOW_ENV[@]+"${ALLOW_ENV[@]}"}; do
    [[ ";${_env_blocked};" != *";${_ev};"* ]] \
      || die "ALLOW_ENV: '$_ev' is blocked (security-sensitive)"
  done
  for _ev in ${SET_ENV[@]+"${SET_ENV[@]}"}; do
    local _sv="${_ev%%=*}"
    [[ ";${_env_blocked};" != *";${_sv};"* ]] \
      || die "SET_ENV: '$_sv' is blocked (security-sensitive)"
  done
  _validate_fmt ALLOW_USB    '^(all|(vnd|dev|cls):[0-9a-fA-F*]+(:[0-9a-fA-F*]+)?(\+(vnd|dev|cls):[0-9a-fA-F*]+(:[0-9a-fA-F*]+)?)*)$' "all or query (vnd:XXXX+dev:YYYY, cls:XX:XX)"
  # flatpak: dev: requires vnd: in same query
  local u
  for u in ${ALLOW_USB[@]+"${ALLOW_USB[@]}"}; do
    [[ "$u" != *dev:* || "$u" == *vnd:* ]] \
      || die "invalid USB query: $u - dev: requires vnd:"
  done
  _validate_fmt DENY_PORTAL  '^[a-z][a-z0-9-]*:.+$'   "table:id"
  _validate_fmt ALLOW_PORTAL '^[a-z][a-z0-9-]*:.+$'    "table:id"
  _validate_fmt ALLOW_DBUS_CALL '^[a-zA-Z_][a-zA-Z0-9_.*-]*=[a-zA-Z_][a-zA-Z0-9_.@/*-]*$' \
    "BUSNAME=INTERFACE.METHOD (org.example.Bus=org.example.Iface.*)"
  _validate_fmt ADD_POLICY   '^[^.=]+\.[^=]+=.+$'      "subsystem.key=value"

  _check_conflict DENY_PORTAL ALLOW_PORTAL

  # hook name: alphanumeric only (no path traversal)
  [[ -z "${HOOK_NAME:-}" ]] || [[ "$HOOK_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] \
    || die "invalid HOOK_NAME: $HOOK_NAME"
}
