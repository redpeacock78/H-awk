#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0
HAWK=./bin/hawk
VALID=tests/unit/cli/fixtures/valid.awk
VALID_SAFE_ENV=tests/unit/cli/fixtures/valid_safe_env.awk
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

# check: valid file exits 0
check "check_valid_exits_0"   0  env HAWK_NO_LIBS=1 "$HAWK" check "$VALID"
# check: invalid file exits 1
check "check_invalid_exits_1" 1  env HAWK_NO_LIBS=1 "$HAWK" check "$INVALID"
# emit: valid file exits 0, produces output
set +e
emit_out=$(HAWK_NO_LIBS=1 "$HAWK" emit "$VALID" 2>/dev/null)
emit_exit=$?
set -e
if [[ "$emit_exit" -eq 0 && -n "$emit_out" ]]; then
  printf "  PASS: emit_produces_output\n"; PASS=$((PASS+1))
else
  printf "  FAIL: emit_produces_output (exit=%d, output=%s)\n" "$emit_exit" "$emit_out"
  FAIL=$((FAIL+1))
fi
# unknown subcommand: exits 1
check "unknown_subcommand_exits_1" 1  env HAWK_NO_LIBS=1 "$HAWK" unknowncmd "$VALID"

# check --strict: valid file exits 0
check "strict_check_valid_exits_0"   0 env HAWK_NO_LIBS=1 "$HAWK" check --strict "$VALID"
# check --strict: safe/env namespace calls exit 0
check "strict_check_safe_env_exits_0" 0 env HAWK_NO_LIBS=1 "$HAWK" check --strict "$VALID_SAFE_ENV"
# check --strict: invalid DSL file exits 1
check "strict_check_invalid_exits_1" 1 env HAWK_NO_LIBS=1 "$HAWK" check --strict "$INVALID"
# emit --strict: valid file exits 0 and produces output
set +e
strict_emit_out=$(HAWK_NO_LIBS=1 "$HAWK" emit --strict "$VALID" 2>/dev/null)
strict_emit_exit=$?
set -e
if [[ "$strict_emit_exit" -eq 0 && -n "$strict_emit_out" ]]; then
  printf "  PASS: strict_emit_valid_produces_output\n"; PASS=$((PASS+1))
else
  printf "  FAIL: strict_emit_valid_produces_output (exit=%d)\n" "$strict_emit_exit"
  FAIL=$((FAIL+1))
fi

# emit は隔離 dist 内の複数ファイル include を stdout だけで実行できる形に展開する
emit_multi=$(mktemp -d)
mkdir -p "$emit_multi/app"
printf '@include "app/part.awk"\n@include "app/part.awk"\nBEGIN { print app_message() }\n' > "$emit_multi/main.awk"
printf 'function app_message() { return "multifile-ok" }\n' > "$emit_multi/app/part.awk"
emit_multi_out=$(HAWK_NO_LIBS=1 "$HAWK" emit "$emit_multi/main.awk" 2>/dev/null)
printf '%s\n' "$emit_multi_out" > "$emit_multi/emitted.awk"
if ! printf '%s\n' "$emit_multi_out" | grep -q '@include'; then
  run_out=$(gawk -f "$emit_multi/emitted.awk" </dev/null)
  if [[ "$run_out" == "multifile-ok" ]]; then
    printf "  PASS: emit_multifile_self_contained\n"; PASS=$((PASS+1))
  else
    printf "  FAIL: emit_multifile_self_contained (output=%s)\n" "$run_out"; FAIL=$((FAIL+1))
  fi
else
  printf "  FAIL: emit_multifile_self_contained (temporary include remained)\n"; FAIL=$((FAIL+1))
fi
rm -rf "$emit_multi"

# check/emit は隔離した一時 dist を使い、cwd の永続 dist を作らない・更新しない
HAWK_ABS="$(pwd)/bin/hawk"
VALID_ABS="$(pwd)/$VALID"
work=$(mktemp -d)
( cd "$work" && HAWK_NO_LIBS=1 "$HAWK_ABS" check --strict "$VALID_ABS" >/dev/null 2>&1 )
if [[ ! -e "$work/dist" ]]; then
  printf "  PASS: check_leaves_no_cwd_dist\n"; PASS=$((PASS+1))
else
  printf "  FAIL: check_leaves_no_cwd_dist (dist/ created)\n"; FAIL=$((FAIL+1))
fi
( cd "$work" && HAWK_NO_LIBS=1 "$HAWK_ABS" emit "$VALID_ABS" >/dev/null 2>&1 )
if [[ ! -e "$work/dist" ]]; then
  printf "  PASS: emit_leaves_no_cwd_dist\n"; PASS=$((PASS+1))
else
  printf "  FAIL: emit_leaves_no_cwd_dist (dist/ created)\n"; FAIL=$((FAIL+1))
fi
rm -rf "$work"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
