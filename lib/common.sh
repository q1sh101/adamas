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
