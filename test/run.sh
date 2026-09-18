#!/usr/bin/env bash
# Test-suite runner. Executes every test/cases/*.sh in an isolated scope so a
# failing case never aborts the rest. Sourced by CI (test job) or directly.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

total_pass=0
total_fail=0
failed_cases=()

for case in "$ROOT"/test/cases/*.sh; do
  name="$(basename "$case" .sh)"
  out="$(bash "$case" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    printf '%s\n' "$out"
    failed_cases+=("$name")
  fi
  total_fail=$((total_fail + rc))
done

echo
echo "total failed cases: ${#failed_cases[@]}"
[ "${#failed_cases[@]}" -eq 0 ]