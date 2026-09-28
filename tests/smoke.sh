#!/usr/bin/env bash
set -euo pipefail

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
_pass=0
_fail=0

_test() {
  local name="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if (( rc == 0 )); then
    echo "  PASS  ${name}"
    ((_pass++)) || true
  else
    echo "  FAIL  ${name}"
    [[ -n "${out}" ]] && printf '%s\n' "${out}" | sed 's/^/        /'
    ((_fail++)) || true
  fi
}

_section() { printf '\n=== %s ===\n' "$1"; }

# throwaway repo with stub flatpak, systemctl and logger on PATH
_make_repo() {
  local root="$1"
  mkdir -p "${root}/repo/apps" "${root}/bin" "${root}/home" "${root}/run"
  chmod 700 "${root}/run"
  cp -a "${_dir}/adamas.sh" "${_dir}/lib" "${root}/repo/"
  : > "${root}/installed"
  cat > "${root}/bin/flatpak" <<'EOF'
#!/usr/bin/env bash
STUB_DIR="__ROOT__"
log="${STUB_DIR}/flatpak.log"
case "${1:-}" in
  --version) echo "Flatpak 1.16.6" ;;
  --installations) [[ ! -e "${STUB_DIR}/no-installations" ]] ;;
  info)
    if [[ "$2" == --show-metadata ]]; then
      printf '[Application]\nname=%s\n\n[Context]\nshared=network;\nsockets=wayland;\n' "$3"
    else
      grep -qx -- "$2" "${STUB_DIR}/installed"
    fi
    ;;
  list) cat "${STUB_DIR}/installed" ;;
  permission-reset) echo "reset $2" >> "${log}" ;;
  permission-set) echo "set $2 $3 $4 $5" >> "${log}" ;;
  run)
    [[ "${2:-}" != --help ]] || exit 0
    shift; echo "run $*" >> "${log}"; env > "${STUB_DIR}/run.env"
    # the first held run stays alive until released
    if mv "${STUB_DIR}/hold" "${STUB_DIR}/holding" 2>/dev/null; then
      for _ in $(seq 200); do [[ -e "${STUB_DIR}/release" ]] && break; sleep 0.05; done
    fi
    ;;
  *) exit 1 ;;
esac
EOF
  sed -i "s|__ROOT__|${root}|" "${root}/bin/flatpak"
  printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "${root}" > "${root}/bin/systemctl"
  printf '#!/bin/sh\n' > "${root}/bin/logger"
  chmod +x "${root}/bin/flatpak" "${root}/bin/systemctl" "${root}/bin/logger"
}

_conf() {
  local root="$1" name="$2"; shift 2
  printf '%s\n' "$@" > "${root}/repo/apps/${name}.conf"
  chmod 644 "${root}/repo/apps/${name}.conf"
}

_adamas() {
  local root="$1"; shift
  env -u FLATPAK_USER_DIR HOME="${root}/home" XDG_RUNTIME_DIR="${root}/run" XDG_DATA_HOME="${root}/home/.local/share" \
    XDG_CONFIG_HOME="${root}/home/.config" PATH="${root}/bin:${PATH}" \
    bash "${root}/repo/adamas.sh" "$@"
}

_wait_until() {
  local attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    "$@" && return 0
    sleep 0.05
  done
  "$@"
}

_cli_contract() {
  local root="$1" cmd out
  local -a argv=()
  _make_repo "${root}"; echo org.example.App > "${root}/installed"; _conf "${root}" app 'APP_ID="org.example.App"'
  for cmd in "" badcmd run verify "verify app extra" "harden app extra" "install app extra" \
    "auto extra" "list extra" watch "watch evil" "watch install extra" trace; do
    argv=(); read -r -a argv <<< "${cmd}" || true
    out=$(_adamas "${root}" ${argv[@]+"${argv[@]}"} 2>&1) && { echo "accepted: ${cmd}"; return 1; }
    grep -qE 'usage|takes no arguments' <<< "${out}" || { echo "not a grammar error: ${cmd}"; return 1; }
  done
  grep -q ' app$' <<< "$(_adamas "${root}" list)"
}

_config_contract() {
  local root="$1" line out
  _make_repo "${root}"; echo org.example.App > "${root}/installed"
  # verify logs "verifying" only after validation passed
  while IFS= read -r line; do
    _conf "${root}" app 'APP_ID="org.example.App"' "${line}"
    out=$(_adamas "${root}" verify app 2>&1) || true
    ! grep -q 'verifying app' <<< "${out}" || { echo "accepted: ${line}"; return 1; }
  done <<EOF
ALLOW_SOCKET=(session-bus)
ALLOW_FILESYSTEM=(/)
ALLOW_FILESYSTEM=(home)
ALLOW_FILESYSTEM=(host)
ALLOW_FILESYSTEM=("~")
ALLOW_FILESYSTEM=("~/")
ALLOW_FILESYSTEM=(~/)
ALLOW_FILESYSTEM=(/home/)
ALLOW_FILESYSTEM=("${root}/home:ro")
ALLOW_FILESYSTEM=(host/.)
ALLOW_FILESYSTEM=(home/./)
ALLOW_FILESYSTEM=("~/.")
ALLOW_FILESYSTEM=(//home)
ALLOW_FILESYSTEM=(/./home)
ALLOW_FILESYSTEM=("${root}/home/.")
ALLOW_FILESYSTEM=(xdg-download/../..)
ALLOW_ENV=(LD_PRELOAD)
NEED_PORTAL=yes
EOF
  _conf "${root}" app 'APP_ID="org.example.App"' 'ALLOW_FILESYSTEM=(xdg-download "~/Documents:ro")'
  grep -q 'verifying app' <<< "$(_adamas "${root}" verify app 2>&1)" || return 1

  # sourced as shell code: symlinked, group-writable or duplicate configs never load
  chmod 664 "${root}/repo/apps/app.conf"
  grep -q 'group/world-writable' <<< "$(_adamas "${root}" verify app 2>&1)" || return 1
  chmod 644 "${root}/repo/apps/app.conf"
  ln -s app.conf "${root}/repo/apps/alias.conf"
  grep -q 'no config' <<< "$(_adamas "${root}" verify alias 2>&1)" || return 1
  mkdir -p "${root}/repo/apps/webapps"; cp -p "${root}/repo/apps/app.conf" "${root}/repo/apps/webapps/app.conf"
  grep -q 'duplicate config basename' <<< "$(_adamas "${root}" verify app 2>&1)"
}

_run_contract() {
  local root="$1" log
  _make_repo "${root}"; echo org.example.App > "${root}/installed"; log="${root}/flatpak.log"
  _conf "${root}" app 'APP_ID="org.example.App"' 'ALLOW_SHARE=(network)' 'ALLOW_ENV=(KEEP)'
  KEEP=1 LEAK=1 _adamas "${root}" run app --flag >/dev/null
  grep -qx 'run --sandbox --share=network org.example.App --flag' "${log}" || return 1
  grep -qx 'KEEP=1' "${root}/run.env" && ! grep -q '^LEAK=' "${root}/run.env" || return 1
  [[ "$(head -1 "${log}")" == 'reset org.example.App' && "$(tail -1 "${log}")" == 'reset org.example.App' ]] || return 1
  [[ "$(grep -c ' no$' "${log}")" == 8 ]] || return 1
  [[ ! -e "${root}/run/adamas-org.example.App.pids" ]] || return 1

  # portal state never falls back to a shared /tmp
  : > "${log}"
  ! env -u XDG_RUNTIME_DIR -u FLATPAK_USER_DIR HOME="${root}/home" PATH="${root}/bin:${PATH}" \
    bash "${root}/repo/adamas.sh" run app >/dev/null 2>&1 && [[ ! -s "${log}" ]] || return 1

  _conf "${root}" app 'APP_ID="org.example.App"' 'NEED_PORTAL=true' 'ALLOW_PORTAL=(devices:camera)'
  _adamas "${root}" run app >/dev/null
  grep -qx 'run --sandbox --session-bus org.example.App' "${log}" \
    && grep -qx 'set devices camera org.example.App yes' "${log}" \
    && ! grep -qx 'set devices camera org.example.App no' "${log}"
}

_portal_contract() {
  local root="$1" log first rc=0 share
  _make_repo "${root}"; echo org.example.App > "${root}/installed"; log="${root}/flatpak.log"
  for share in false true; do
    _conf "${root}" loose 'APP_ID="org.example.App"' 'ALLOW_PORTAL=(devices:camera)' "SHARE_PORTAL=${share}"
    _conf "${root}" strict 'APP_ID="org.example.App"' "SHARE_PORTAL=${share}"
    : > "${log}"; rm -f "${root}/release"; : > "${root}/hold"
    _adamas "${root}" run loose >/dev/null 2>&1 & first=$!
    _wait_until grep -q '^run ' "${log}"
    rc=0; _adamas "${root}" run strict > "${root}/strict.out" 2>&1 || rc=$?
    if [[ "${share}" == false ]]; then
      # differing policies on one app id never widen silently
      (( rc != 0 )) && grep -q "running as 'loose'" "${root}/strict.out" \
        && [[ "$(grep -c '^run ' "${log}")" == 1 ]] || return 1
    else
      # both opted in: the store keeps the union while loose runs
      (( rc == 0 )) && [[ "$(grep -c '^run ' "${log}")" == 2 ]] \
        && [[ "$(grep ' camera ' "${log}" | tail -1)" == 'set devices camera org.example.App yes' ]] || return 1
    fi
    : > "${root}/release"; wait "${first}"
    [[ "$(tail -1 "${log}")" == 'reset org.example.App' ]] || return 1
  done
}

_route_contract() {
  local root="$1" exports apps outside hooks
  _make_repo "${root}"; echo org.example.App > "${root}/installed"
  exports="${root}/home/.local/share/flatpak/exports/share/applications"; apps="${root}/home/.local/share/applications"
  outside="${root}/outside"; hooks="${root}/hooks"
  mkdir -p "${exports}" "${apps}" "${outside}" "${hooks}"
  printf '%s\n' '[Desktop Entry]' 'DBusActivatable = true' \
    'Exec=/usr/bin/flatpak run --branch=stable --command=app --file-forwarding org.example.App @@u %u @@' \
    '[Desktop Action new]' 'Exec=/usr/bin/flatpak run --command=app org.example.App --new-window' \
    '[Desktop Action main]' 'Exec=/usr/bin/flatpak run --command=app org.example.App --class=org.example.App.Main %U' \
    > "${exports}/org.example.App.desktop"
  printf 'keep\n' > "${outside}/desktop"; mkdir "${outside}/hookdir"
  _conf "${root}" app 'APP_ID="org.example.App"'
  _conf "${root}" web 'APP_ID="org.example.App"' 'HOOK_NAME=web' "HOOK_DIR=${hooks}"

  # a pre-existing symlink is replaced, never written or moved through
  ln -s "${outside}/desktop" "${apps}/org.example.App.desktop"
  ln -s "${outside}/hookdir" "${hooks}/web"
  _adamas "${root}" harden app >/dev/null && _adamas "${root}" harden web >/dev/null || return 1
  grep -qx keep "${outside}/desktop" && [[ -z "$(ls -A "${outside}/hookdir")" ]] || return 1
  [[ ! -L "${apps}/org.example.App.desktop" && ! -L "${hooks}/web" && -x "${hooks}/web" ]] || return 1
  grep -q "run app @@u %u @@$" "${apps}/org.example.App.desktop" \
    && grep -q "run app --new-window$" "${apps}/org.example.App.desktop" \
    && grep -q "run app --class=org.example.App.Main %U$" "${apps}/org.example.App.desktop" || return 1
  # D-Bus activation would bypass the patched Exec= lines
  ! grep -q '^DBusActivatable' "${apps}/org.example.App.desktop" || return 1
  _adamas "${root}" verify app >/dev/null && _adamas "${root}" verify web >/dev/null || return 1

  sed -i 's|^Exec=.*--new-window$|Exec=/usr/bin/flatpak run org.example.App|' "${apps}/org.example.App.desktop"
  ! _adamas "${root}" verify app >/dev/null 2>&1 || return 1
  _adamas "${root}" harden app >/dev/null || return 1
  # GLib reads "DBusActivatable = 1" as true too; auto re-hardens such a route
  echo 'DBusActivatable = 1' >> "${apps}/org.example.App.desktop"
  grep -q 'D-Bus activated' <<< "$(_adamas "${root}" verify app 2>&1)" || return 1
  _adamas "${root}" auto >/dev/null && _adamas "${root}" verify app >/dev/null || return 1
  # an intact route is left alone
  grep -q ' 0 hardened' <<< "$(_adamas "${root}" auto 2>&1)" || return 1
  # an unreadable installation list is a failure, not "no .desktop exported"
  : > "${root}/no-installations"
  ! _adamas "${root}" harden app >/dev/null 2>&1 && ! _adamas "${root}" auto >/dev/null 2>&1 || return 1
  rm "${root}/no-installations"
  printf '#!/bin/sh\nexec flatpak run org.example.App\n' > "${hooks}/web"
  ! _adamas "${root}" verify web >/dev/null 2>&1
}

_draft_contract() {
  local root="$1" exports
  umask 002  # generated configs must still load
  _make_repo "${root}"; printf 'org.example.New\norg.other.New\norg.example.Draft\n' > "${root}/installed"
  exports="${root}/home/.local/share/flatpak/exports/share/applications"; mkdir -p "${exports}"
  printf '[Desktop Entry]\nExec=/usr/bin/flatpak run org.example.New\n' > "${exports}/org.example.New.desktop"
  _conf "${root}" draft-owner 'APP_ID="org.example.Draft"' 'AUTO_SKIP=true'
  printf 'keep\n' > "${root}/outside"; ln -s "${root}/outside" "${root}/repo/apps/linked.conf"
  # generated configs grant nothing, so they never take the route
  _adamas "${root}" auto >/dev/null && _adamas "${root}" auto >/dev/null || return 1
  grep -qx 'AUTO_SKIP=true   # review permissions, then set false' "${root}/repo/apps/new.conf" || return 1
  # a taken short name falls back to the dashed app id
  grep -qx 'APP_ID="org.other.New"' "${root}/repo/apps/org-other-New.conf" || return 1
  grep -q 'not managed by adamas' <<< "$(_adamas "${root}" verify new 2>&1)" || return 1
  [[ ! -e "${root}/home/.local/share/applications/org.example.New.desktop" ]] || return 1
  # a name held by a symlink is a collision: nothing is written through it, auto fails
  echo org.example.Linked >> "${root}/installed"
  ! _adamas "${root}" auto >/dev/null 2>&1 || return 1
  ! _adamas "${root}" trace org.example.Linked --save >/dev/null 2>&1 || return 1
  grep -qx keep "${root}/outside" || return 1

  # a saved trace draft is unreviewed too
  rm "${root}/repo/apps/draft-owner.conf"
  _adamas "${root}" trace org.example.Draft --save >/dev/null 2>&1 || return 1
  grep -q '^AUTO_SKIP=true' "${root}/repo/apps/draft.conf" || return 1
  grep -q 'not managed by adamas' <<< "$(_adamas "${root}" verify draft 2>&1)" || return 1

  # an unreadable app list is a failure, not an empty system
  rm "${root}/installed"
  ! _adamas "${root}" auto >/dev/null 2>&1
}

_watch_contract() {
  local root="$1"
  _make_repo "${root}"
  _adamas "${root}" watch install >/dev/null || return 1
  grep -qx -- '--user daemon-reload' "${root}/systemctl.log" || return 1
  grep -q "PathChanged=${root}/home/.local/share/flatpak/exports/share/applications" \
    "${root}/home/.config/systemd/user/adamas-watch.path"
}

_shipped_contract() {
  local root="$1" conf name out
  _make_repo "${root}"; echo org.mozilla.firefox > "${root}/installed"
  cp -a "${_dir}/apps/." "${root}/repo/apps/"; chmod -R go-w "${root}/repo/apps"
  # every shipped config passes validation
  while IFS= read -r conf; do
    name="$(basename "${conf%.conf}")"
    [[ "${name}" != example ]] || continue
    out=$(_adamas "${root}" verify "${name}" 2>&1) || true
    grep -q "verifying ${name}" <<< "${out}" || { echo "${name}: ${out}"; return 1; }
  done < <(find "${root}/repo/apps" -name '*.conf')
}

_tmpdir=$(mktemp -d)
trap 'rm -rf "${_tmpdir}"' EXIT
mapfile -t _sh < <(printf '%s\n' "${_dir}/adamas.sh" "${_dir}"/lib/*.sh "${_dir}/tests/smoke.sh")

_section syntax
_test "all shell sources parse" bash -c 'for f; do bash -n "$f" || exit; done' _ "${_sh[@]}"
if command -v shellcheck &>/dev/null; then
  _test "shellcheck" shellcheck -x "${_sh[@]}"
else
  echo "  SKIP  shellcheck not installed"
fi

_section interfaces
_test "CLI grammar" _cli_contract "${_tmpdir}/cli"
_test "config validation and safety" _config_contract "${_tmpdir}/config"
_test "shipped configs are valid" _shipped_contract "${_tmpdir}/shipped"

_section sandbox
_test "run compiles flags, sanitizes env, resets portals" _run_contract "${_tmpdir}/run"
_test "one portal policy per app id" _portal_contract "${_tmpdir}/portal"

_section route
_test "harden and verify route integrity" _route_contract "${_tmpdir}/route"
_test "unreviewed configs never take the route" _draft_contract "${_tmpdir}/draft"
_test "watch generates and reloads units" _watch_contract "${_tmpdir}/watch"

printf '\n===============================\n'
printf '  PASS: %d  FAIL: %d\n' "${_pass}" "${_fail}"
printf '===============================\n'
(( _fail == 0 ))
