#!/usr/bin/env bash
# Healthy fixture: everything that applies must be OK, exit code 0.
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_home healthy

run_doctor_json --global
assert_eq "$RC" 0 "exit code with full-health global config"
assert_eq "$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['fail'])")" 0 "zero failures"
assert_eq "$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['warn'])")" 0 "zero warnings"

# JSON report stays well-formed and every check carries the fields we rely on.
assert_eq "$(printf '%s' "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin);print(all(all(k in c for k in ('id','severity','status','name','detail','remedy')) for c in d['checks']))")" True "every check carries id/severity/status/name/detail/remedy"

summary