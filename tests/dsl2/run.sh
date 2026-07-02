#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/dsl2/run.sh -- DSL v2 工程別 golden test
set -e
cd "$(dirname "$0")/../.."

PASS=0; FAIL=0

check() { # name, expected_file, actual_text
  if diff -u "$2" <(printf '%s\n' "$3") >/dev/null 2>&1; then
    printf "  PASS: %s\n" "$1"; PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$1"
    diff -u "$2" <(printf '%s\n' "$3") || true
    FAIL=$((FAIL + 1))
  fi
}

for dir in tests/dsl2/*/; do
  name=$(basename "$dir")
  [[ -f "${dir}input.awk" ]] || continue

  # エラー fixture
  if [[ -f "${dir}expected_stderr" ]]; then
    set +e
    actual_err=$(gawk -f dsl/v2/main.awk "${dir}input.awk" 2>&1 >/dev/null)
    ret=$?
    set -e
    if [[ $ret -eq 1 ]] && grep -qF "$(cat "${dir}expected_stderr")" <<<"$actual_err"; then
      printf "  PASS: %s\n" "$name"; PASS=$((PASS + 1))
    else
      printf "  FAIL: %s (exit=%d)\n  got: %s\n" "$name" "$ret" "$actual_err"
      FAIL=$((FAIL + 1))
    fi
    continue
  fi

  # 工程ダンプ fixture（存在するものだけ検査）
  for stage in lex rpn ast types; do
    [[ -f "${dir}expected.${stage}.tsv" ]] || continue
    actual=$(gawk -v V2_DUMP=$stage -f dsl/v2/main.awk "${dir}input.awk" 2>/dev/null) || true
    check "$name ($stage)" "${dir}expected.${stage}.tsv" "$actual"
  done

  # emit fixture
  if [[ -f "${dir}expected.awk" ]]; then
    actual=$(gawk -f dsl/v2/main.awk "${dir}input.awk" 2>/dev/null) || true
    check "$name (emit)" "${dir}expected.awk" "$actual"
  fi
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
