#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0

for dir in tests/unit/dsl/*/; do
  [[ -f "${dir}input.awk" ]] || continue
  [[ -f "${dir}expected.awk" ]] || continue
  name=$(basename "$dir")

  actual=$(gawk -f dsl/desugar.awk "${dir}input.awk" 2>/dev/null | grep -v '^# line ')

  if diff -u "${dir}expected.awk" <(printf '%s\n' "$actual") >/dev/null 2>&1; then
    printf "  PASS: %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$name"
    diff -u "${dir}expected.awk" <(printf '%s\n' "$actual") || true
    FAIL=$((FAIL + 1))
  fi
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
