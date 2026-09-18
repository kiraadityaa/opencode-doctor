#!/usr/bin/env bash
# bad-jsonc fixture: the global config is unparseable → g01 must FAIL and the
# doctor must exit 2 without crashing.
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_home bad-jsonc

run_doctor_json --global
assert_eq "$RC" 2 "exit code 2 on broken config"
assert_status g01 FAIL

# Human mode must also survive and report the failure.
run_doctor --global
assert_eq "$RC" 2 "human mode exit code 2"

summary