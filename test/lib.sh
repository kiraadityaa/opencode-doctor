#!/usr/bin/env bash
# Shared helpers for the opencode-doctor test-suite. Every test case sources
# this file. Runs the REAL doctor.sh against fixture configs using a fake
# `opencode` shim, so nothing touches the developer's own machine.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$ROOT/doctor.sh"
FIXTURES="$ROOT/test/fixtures"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

PASS=0
FAIL=0

strip_path() {
  # Strip PATH entries that could leak a real opencode binary, then PREPEND
  # fixtures/bin so the fake shim always wins command lookup.
  local keep=""
  local p
  while IFS= read -r p; do
    case "$p" in
      *opencode*) : ;;
      *) keep="${keep:+$keep:}$p" ;;
    esac
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  printf '%s' "$FIXTURES/bin:$keep"
}

scratch() {
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX")"
  HOME="$SCRATCH/home"
  XDG_CONFIG_HOME="$SCRATCH/xdg"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  export HOME XDG_CONFIG_HOME
  PATH="$(strip_path)"
  export PATH
  export DOCTOR_ASSUME_VM="${DOCTOR_ASSUME_VM:-}"
}

fixture_home() { # $1 fixture name
  local name="$1"
  scratch
  cp -r "$FIXTURES/$name/xdg/." "$XDG_CONFIG_HOME/"
  FIX_DIR="$FIXTURES/$name"
}

run_doctor() {
  # shellcheck disable=SC2086
  "$DOCTOR" $* --offline 2> "$SCRATCH/doctor.stderr"
  RC=$?
  return $RC
}

run_doctor_json() {
  # $@: flags (without --json). Parses output, stores in OUT.
  # shellcheck disable=SC2086
  OUT="$("$DOCTOR" --json $* --offline 2> "$SCRATCH/doctor.stderr")"
  RC=$?
  printf '%s' "$OUT" | python3 -m json.tool > /dev/null 2>&1 || {
    echo "FAIL: --json output is not valid JSON"
    printf '%s\n' "$OUT" | head -5
    return 1
  }
}

check_ok()   { echo "  ok: $*"; }
check_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() { # $1 actual  $2 expected  $3 label
  if [ "$1" = "$2" ]; then check_ok "$3 ($1)"; else check_fail "$3 (got '$1', want '$2')"; fi
}

assert_status() { # $1 id  $2 expected status  (uses OUT via python)
  local got
  got="$(printf '%s' "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = ''
for c in d['checks']:
    if c['id'] == '$1':
        s = c['status']
print(s)
")"
  assert_eq "$got" "$2" "status[$1]"
}

summary() {
  echo
  echo "case $CASE_NAME: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}