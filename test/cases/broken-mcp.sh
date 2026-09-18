#!/usr/bin/env bash
# broken-mcp fixture: an enabled server reports disconnected → g06 WARN,
# exit 1. This guards the ANSI-stripped mcp-list parsing in the doctor.
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_home broken-mcp

run_doctor_json --global
assert_eq "$RC" 2 "broken mcp ⇒ exit 2"
assert_status g06 FAIL
assert_status g05 OK

summary