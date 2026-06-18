#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0

for dir in tests/unit/dsl/*/; do
  name=$(basename "$dir")

  # エラー fixture: expected_stderr が存在する場合
  if [[ -f "${dir}expected_stderr" ]]; then
    [[ -f "${dir}input.awk" ]] || continue
    strict_args=()
    [[ -f "${dir}strict" ]] && strict_args=(-v _DS_strict=1)
    expected_exit=1
    [[ -f "${dir}expected_exit" ]] && expected_exit=$(tr -d '[:space:]' < "${dir}expected_exit")
    expected_msg=$(cat "${dir}expected_stderr")

    set +e
    actual_stderr=$(gawk "${strict_args[@]}" -f dsl/desugar.awk "${dir}input.awk" 2>&1 1>/dev/null)
    actual_exit=$?
    set -e

    if [[ "$actual_exit" -eq "$expected_exit" ]] && printf '%s' "$actual_stderr" | grep -qF "$expected_msg"; then
      printf "  PASS: %s\n" "$name"
      PASS=$((PASS + 1))
    else
      printf "  FAIL: %s\n" "$name"
      printf "    expected exit=%s, got exit=%s\n" "$expected_exit" "$actual_exit"
      printf "    expected stderr to contain: %s\n" "$expected_msg"
      printf "    actual stderr: %s\n" "$actual_stderr"
      FAIL=$((FAIL + 1))
    fi
    continue
  fi

  # 通常 fixture: expected.awk が存在する場合
  [[ -f "${dir}input.awk" ]] || continue
  [[ -f "${dir}expected.awk" ]] || continue

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
