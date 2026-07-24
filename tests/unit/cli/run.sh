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
HAWK_ROOT="$(pwd)"
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

# framework 外の cwd でも framework 本体・plugin・native lib を HAWK_LIB から解決する
work=$(mktemp -d)
work="$(cd "$work" && pwd -P)"
mkdir -p "$work/data"
printf 'name\noutside-cwd-ok\n' > "$work/data/items.tsv"
printf 'BEGIN { if (read_tsv("data/items.tsv", rows) == 1) print rows[1, "name"] }\n' > "$work/app.awk"
serve_out=$(cd "$work" && HAWK_NO_LIBS=1 HAWK_NO_SERVE=1 HAWK_WORKERS=1 "$HAWK_ABS" serve app.awk 2>/dev/null)
if [[ "$serve_out" == *"outside-cwd-ok"* ]]; then
  printf "  PASS: serve_outside_hawk_lib\n"; PASS=$((PASS+1))
else
  printf "  FAIL: serve_outside_hawk_lib (output=%s)\n" "$serve_out"; FAIL=$((FAIL+1))
fi
worker_out=$(cd "$work" && HAWK_LIB="$HAWK_ROOT" HAWK_NO_LIBS=1 HAWK_NO_SERVE=1 "$HAWK_ROOT/libexec/hawk-worker" "$work/app.awk" 2>/dev/null)
if [[ "$worker_out" == *"outside-cwd-ok"* ]]; then
  printf "  PASS: worker_outside_hawk_lib\n"; PASS=$((PASS+1))
else
  printf "  FAIL: worker_outside_hawk_lib (output=%s)\n" "$worker_out"; FAIL=$((FAIL+1))
fi
printf 'BEGIN { print ENVIRON["HAWK_LIB"] }\n' > "$work/env.awk"
worker_env=$(cd "$work" && unset HAWK_LIB && HAWK_NO_LIBS=1 HAWK_NO_SERVE=1 "$HAWK_ROOT/libexec/hawk-worker" "$work/env.awk" 2>/dev/null)
all_exported=1
for entry in hawk-serve hawk-worker hawk-supervise hawk-check hawk-emit; do
  grep -q '^export HAWK_LIB=' "$HAWK_ROOT/libexec/$entry" || all_exported=0
done
if [[ "$worker_env" == "$HAWK_ROOT" && "$all_exported" -eq 1 ]]; then
  printf "  PASS: direct_entrypoints_export_hawk_lib\n"; PASS=$((PASS+1))
else
  printf "  FAIL: direct_entrypoints_export_hawk_lib (worker_env=%s, all_exported=%s)\n" "$worker_env" "$all_exported"; FAIL=$((FAIL+1))
fi

framework="$work/framework"
mkdir -p "$framework/plugins/base" "$framework/plugins/demo" "$framework/libs/net/zig-out/lib"
printf '# manifest\n' > "$framework/plugins/base/manifest.awk"
printf '# plugin\n' > "$framework/plugins/base/base.awk"
printf '# manifest\n' > "$framework/plugins/demo/manifest.awk"
printf '# plugin\n' > "$framework/plugins/demo/demo.awk"
case "$(uname -s)" in Darwin) so_ext=dylib ;; *) so_ext=so ;; esac
touch "$framework/libs/net/zig-out/lib/libhawk_net.$so_ext"
plugins_out=$(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" plugins)
if [[ "$plugins_out" == *"$framework/plugins/demo/manifest.awk"* && "$plugins_out" == *"$framework/plugins/demo/demo.awk"* ]]; then
  printf "  PASS: plugins_outside_hawk_lib\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugins_outside_hawk_lib (output=%s)\n" "$plugins_out"; FAIL=$((FAIL+1))
fi

mkdir -p "$work/plugins/logger"
printf '# manifest\n' > "$work/plugins/logger/manifest.awk"
printf '# plugin\n' > "$work/plugins/logger/logger.awk"
mapfile -t plugin_paths < <(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" plugins)
if [[ "${#plugin_paths[@]}" -eq 6 && "${plugin_paths[0]}" == "$framework/plugins/base/manifest.awk" && "${plugin_paths[2]}" == "$framework/plugins/demo/manifest.awk" && "${plugin_paths[4]}" == "$work/plugins/logger/manifest.awk" ]]; then
  printf "  PASS: plugins_dual_roots\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugins_dual_roots (paths=%s)\n" "${plugin_paths[*]}"; FAIL=$((FAIL+1))
fi

mkdir -p "$work/plugins/demo"
printf '# app manifest\n' > "$work/plugins/demo/manifest.awk"
printf '# app plugin\n' > "$work/plugins/demo/demo.awk"
mapfile -t plugin_paths < <(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" plugins)
if [[ "${#plugin_paths[@]}" -eq 6 && "${plugin_paths[2]}" == "$work/plugins/demo/manifest.awk" && "${plugin_paths[3]}" == "$work/plugins/demo/demo.awk" ]]; then
  printf "  PASS: plugins_app_shadow\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugins_app_shadow (paths=%s)\n" "${plugin_paths[*]}"; FAIL=$((FAIL+1))
fi

touch "$work/plugins/demo/.disabled"
mapfile -t plugin_paths < <(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" plugins)
if [[ "${#plugin_paths[@]}" -eq 4 && "${plugin_paths[0]}" == "$framework/plugins/base/manifest.awk" && "${plugin_paths[2]}" == "$work/plugins/logger/manifest.awk" ]]; then
  printf "  PASS: plugins_disabled_app_shadows\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugins_disabled_app_shadows (paths=%s)\n" "${plugin_paths[*]}"; FAIL=$((FAIL+1))
fi

mapfile -t plugin_paths < <(cd "$work" && HAWK_LIB="$work" "$HAWK_ROOT/libexec/hawk-libs" plugins)
if [[ "${#plugin_paths[@]}" -eq 2 && "${plugin_paths[0]}" == "$work/plugins/logger/manifest.awk" && "${plugin_paths[1]}" == "$work/plugins/logger/logger.awk" ]]; then
  printf "  PASS: plugins_same_root_dedup\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugins_same_root_dedup (paths=%s)\n" "${plugin_paths[*]}"; FAIL=$((FAIL+1))
fi

mapfile -t plugin_dirs < <(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" plugin-dirs)
if [[ "${#plugin_dirs[@]}" -eq 2 && "${plugin_dirs[0]}" == "$framework/plugins/base" && "${plugin_dirs[1]}" == "$work/plugins/logger" ]]; then
  printf "  PASS: plugin_dirs_match_selection\n"; PASS=$((PASS+1))
else
  printf "  FAIL: plugin_dirs_match_selection (dirs=%s)\n" "${plugin_dirs[*]}"; FAIL=$((FAIL+1))
fi

libs_out=$(cd "$work" && HAWK_LIB="$framework" "$HAWK_ROOT/libexec/hawk-libs" libs)
if [[ "$libs_out" == *"$framework/libs/net/zig-out/lib/libhawk_net.$so_ext"* && "$libs_out" == *"HAS_NET=1"* ]]; then
  printf "  PASS: libs_outside_hawk_lib\n"; PASS=$((PASS+1))
else
  printf "  FAIL: libs_outside_hawk_lib (output=%s)\n" "$libs_out"; FAIL=$((FAIL+1))
fi
rm -rf "$work"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
