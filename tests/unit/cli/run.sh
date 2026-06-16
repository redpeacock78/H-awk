#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0
HAWK=./bin/hawk
VALID=tests/unit/cli/fixtures/valid.awk
INVALID=tests/unit/cli/fixtures/invalid.awk

check() {
  local name="$1" expected_exit="$2"
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [[ "$actual" -eq "$expected_exit" ]]; then
    printf "  PASS: %s\n" "$name"
    PASS=$((PASS+1))
  else
    printf "  FAIL: %s (expected exit %d, got %d)\n" "$name" "$expected_exit" "$actual"
    FAIL=$((FAIL+1))
  fi
}

# --no-emit: valid file exits 0
check "no_emit_valid_exits_0"   0  $HAWK --no-emit "$VALID"
# --no-emit: invalid file exits 1
check "no_emit_invalid_exits_1" 1  $HAWK --no-emit "$INVALID"
# --emit: valid file exits 0, produces output
set +e
emit_out=$(HAWK_NO_LIBS=1 $HAWK --emit "$VALID" 2>/dev/null)
emit_exit=$?
set -e
if [[ "$emit_exit" -eq 0 && -n "$emit_out" ]]; then
  printf "  PASS: emit_produces_output\n"; PASS=$((PASS+1))
else
  printf "  FAIL: emit_produces_output (exit=%d, output=%s)\n" "$emit_exit" "$emit_out"
  FAIL=$((FAIL+1))
fi
# --no-emit and --emit together: exits 1 with error message
set +e
combo_out=$(HAWK_NO_LIBS=1 $HAWK --no-emit --emit "$VALID" 2>&1)
combo_exit=$?
set -e
if [[ "$combo_exit" -ne 0 ]] && printf '%s' "$combo_out" | grep -q "mutually exclusive"; then
  printf "  PASS: no_emit_and_emit_error\n"; PASS=$((PASS+1))
else
  printf "  FAIL: no_emit_and_emit_error (exit=%d)\n" "$combo_exit"
  FAIL=$((FAIL+1))
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
