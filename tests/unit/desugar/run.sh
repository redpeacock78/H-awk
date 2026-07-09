#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0
LIBS=./libexec/hawk-libs
LIBS_ABS="$(pwd)/libexec/hawk-libs"
FIX=tests/unit/desugar/fixtures

ok() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
ng() { printf "  FAIL: %s%s\n" "$1" "${2:+ ($2)}"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 再帰 desugar + @include 書き換え + 実行 ---
dist="$TMP/dist1"
out=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk")
if [[ "$out" == "$dist/main.awk" ]]; then ok "entry_path_echoed"; else ng "entry_path_echoed" "$out"; fi
if [[ -f "$dist/app/page.awk" ]]; then ok "included_file_mirrored"; else ng "included_file_mirrored"; fi
if [[ -f "$dist/app/sub/util.awk" ]]; then ok "nested_include_mirrored"; else ng "nested_include_mirrored"; fi
if grep -qF "@include \"$dist/app/page.awk\"" "$dist/main.awk"; then ok "include_rewritten"; else ng "include_rewritten"; fi
if grep -qF "@include \"$dist/app/sub/util.awk\"" "$dist/app/page.awk"; then ok "nested_include_rewritten"; else ng "nested_include_rewritten"; fi
if ! grep -q "let " "$dist/app/page.awk"; then ok "included_file_desugared"; else ng "included_file_desugared"; fi
run_out=$(gawk -f "$dist/main.awk" </dev/null)
if [[ "$run_out" == "hello from page" ]]; then ok "desugared_tree_runs"; else ng "desugared_tree_runs" "$run_out"; fi

# --- 循環 include は 1 回ずつで停止 ---
dist="$TMP/dist2"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/cyc/a.awk" >/dev/null; then
  if [[ -f "$dist/a.awk" && -f "$dist/b.awk" ]]; then ok "cycle_terminates"; else ng "cycle_terminates" "missing outputs"; fi
else
  ng "cycle_terminates" "exit != 0"
fi

# --- 実在しない include は素通り (行もそのまま) ---
dist="$TMP/dist3"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/missing/main.awk" >/dev/null; then
  if grep -qF '@include "no/such.awk"' "$dist/main.awk"; then ok "missing_include_passthrough"; else ng "missing_include_passthrough"; fi
else
  ng "missing_include_passthrough" "exit != 0"
fi

# --- include 先の desugar 失敗は exit 1 + ファイル名表示 ---
dist="$TMP/dist4"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/fail/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "include_desugar_failure_exit1"; else ng "include_desugar_failure_exit1" "exit=$st"; fi
if [[ "$err" == *"bad.awk"* ]]; then ok "failure_names_file"; else ng "failure_names_file" "$err"; fi

# --- HAWK_DIST 未指定なら cwd の dist/ ---
work="$TMP/work"; mkdir -p "$work"
cp "$FIX/solo.awk" "$work/main.awk"
out=$(cd "$work" && "$LIBS_ABS" desugar main.awk)
if [[ "$out" == "dist/main.awk" && -f "$work/dist/main.awk" ]]; then ok "default_dist_dir"; else ng "default_dist_dir" "$out"; fi

# --- 入力ファイル不在は従来どおり exit 1 ---
set +e
"$LIBS" desugar "$TMP/nope.awk" >/dev/null 2>&1
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "entry_not_found_exit1"; else ng "entry_not_found_exit1" "exit=$st"; fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
