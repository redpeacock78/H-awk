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

# --- entry に戻る循環は exit 1 (gawk が実行時 fatal になるため desugar 時点で拒否) ---
dist="$TMP/dist2"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/cyc/a.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "entry_cycle_rejected"; else ng "entry_cycle_rejected" "exit=$st"; fi
if [[ "$err" == *"cycle back to entry"* ]]; then ok "entry_cycle_names_cause"; else ng "entry_cycle_names_cause" "$err"; fi

# --- "./entry" 形式の back-edge も正規化して検出する ---
dist="$TMP/dist2c"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/cyc3/a.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"cycle back to entry"* ]]; then ok "entry_cycle_dotslash_rejected"; else ng "entry_cycle_dotslash_rejected" "exit=$st: $err"; fi

# --- symlink 経由の entry 循環も検出する ---
symcyc="$TMP/symcyc"
mkdir -p "$symcyc"
cp "$FIX/symcyc/a.awk" "$FIX/symcyc/b.awk" "$symcyc/"
ln -s a.awk "$symcyc/alias.awk"
dist="$TMP/dist2d"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$symcyc/a.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"cycle back to entry"* ]]; then ok "entry_cycle_symlink_rejected"; else ng "entry_cycle_symlink_rejected" "exit=$st: $err"; fi

# --- 実在しない "./x.awk" は正規化せずそのまま残す (AWKPATH 落ち防止) ---
dist="$TMP/distdm"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/dotmiss/main.awk" >/dev/null; then
  if grep -qF '@include "./nosuch.awk"' "$dist/main.awk"; then ok "unresolved_dotslash_kept"; else ng "unresolved_dotslash_kept"; fi
else
  ng "unresolved_dotslash_kept" "exit != 0"
fi

# --- "./x.awk" 形式の include は正規化されて dist に書き換わる ---
dist="$TMP/distds"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/dotslash/main.awk" >/dev/null; then
  if grep -qF "@include \"$dist/x.awk\"" "$dist/main.awk"; then ok "dotslash_include_normalized"; else ng "dotslash_include_normalized"; fi
  run_out=$(gawk -f "$dist/main.awk" </dev/null)
  if [[ "$run_out" == "dotslash-x" ]]; then ok "dotslash_tree_runs"; else ng "dotslash_tree_runs" "$run_out"; fi
else
  ng "dotslash_include_normalized" "exit != 0"
fi

# --- entry を経由しない循環は 1 回ずつで停止し、実行も通る ---
dist="$TMP/dist2b"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/cyc2/main.awk" >/dev/null; then
  if [[ -f "$dist/x.awk" && -f "$dist/y.awk" ]]; then ok "cycle_terminates"; else ng "cycle_terminates" "missing outputs"; fi
  run_out=$(gawk -f "$dist/main.awk" </dev/null)
  if [[ "$run_out" == "cyc2" ]]; then ok "cycle_tree_runs"; else ng "cycle_tree_runs" "$run_out"; fi
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
if [[ ! -e "$dist/main.awk" ]]; then ok "parent_not_published_on_child_failure"; else ng "parent_not_published_on_child_failure" "dist/main.awk exists"; fi
leftovers=$(find "$dist" -name ".hawk-desugar.*" 2>/dev/null | wc -l)
if [[ "$leftovers" -eq 0 ]]; then ok "no_scratch_leftovers_on_failure"; else ng "no_scratch_leftovers_on_failure" "$leftovers scratch files remain"; fi

# --- 兄弟 include の失敗時は closure 全体を publish しない ---
dist="$TMP/dist4b"
set +e
HAWK_DIST="$dist" "$LIBS" desugar "$FIX/sib/main.awk" >/dev/null 2>&1
st=$?
set -e
if [[ "$st" -eq 1 && ! -e "$dist/a_good.awk" && ! -e "$dist/main.awk" ]]; then
  ok "sibling_failure_publishes_nothing"
else
  ng "sibling_failure_publishes_nothing" "exit=$st, a_good=$([[ -e "$dist/a_good.awk" ]] && echo yes || echo no)"
fi

# --- '..' で dist の外に出る include は exit 1（P1: dist 脱出防止） ---
dist="$TMP/dist5"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/escape/sub/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "parent_include_escape_rejected"; else ng "parent_include_escape_rejected" "exit=$st"; fi
if [[ ! -e "$dist/../common.awk" && ! -e "$TMP/common.awk" ]]; then ok "parent_include_no_file_written_outside_dist"; else ng "parent_include_no_file_written_outside_dist" "escaped file found"; fi

# --- HAWK_DIST が source と同じ場所を指すと in/out がエイリアスする問題 ---
alias_dir="$TMP/alias"
mkdir -p "$alias_dir"
cp "$FIX/alias/main.awk" "$alias_dir/main.awk"
before_hash=$(cksum < "$alias_dir/main.awk")
set +e
err=$(HAWK_DIST="$alias_dir" "$LIBS" desugar "$alias_dir/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "alias_dist_rejected"; else ng "alias_dist_rejected" "exit=$st"; fi
after_hash=$(cksum < "$alias_dir/main.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "alias_dist_source_untouched"; else ng "alias_dist_source_untouched" "source file was modified"; fi

# --- symlink 経由の source エイリアスも検出する ---
alias2_dir="$TMP/alias2"
mkdir -p "$alias2_dir"
cp "$FIX/alias/main.awk" "$alias2_dir/main.awk"
ln -s "$alias2_dir" "$TMP/alias2-link"
before_hash=$(cksum < "$alias2_dir/main.awk")
set +e
err=$(HAWK_DIST="$TMP/alias2-link" "$LIBS" desugar "$alias2_dir/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "alias_dist_symlink_rejected"; else ng "alias_dist_symlink_rejected" "exit=$st"; fi
after_hash=$(cksum < "$alias2_dir/main.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "alias_dist_symlink_source_untouched"; else ng "alias_dist_symlink_source_untouched" "source file was modified"; fi

# --- source 側が symlink で dist に解決するケースも検出する ---
symsrc="$TMP/symsrc"
mkdir -p "$symsrc/srcdir" "$symsrc/linkdir"
cp "$FIX/symsrc/srcdir/main.awk" "$symsrc/srcdir/main.awk"
ln -s ../srcdir/main.awk "$symsrc/linkdir/main.awk"
before_hash=$(cksum < "$symsrc/srcdir/main.awk")
set +e
err=$(HAWK_DIST="$symsrc/srcdir" "$LIBS" desugar "$symsrc/linkdir/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "symlinked_source_alias_rejected"; else ng "symlinked_source_alias_rejected" "exit=$st"; fi
after_hash=$(cksum < "$symsrc/srcdir/main.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "symlinked_source_untouched"; else ng "symlinked_source_untouched" "source file was modified"; fi

# --- include 名が .tmp で終わっても scratch と衝突しない ---
dist="$TMP/dist6"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/tmpcol/main.awk" >/dev/null; then
  if [[ -f "$dist/a.awk.tmp" ]] && grep -q "tc_tmp" "$dist/a.awk.tmp"; then
    ok "tmp_suffix_include_survives_rewrite"
  else
    ng "tmp_suffix_include_survives_rewrite" "dist/a.awk.tmp missing or clobbered"
  fi
else
  ng "tmp_suffix_include_survives_rewrite" "exit != 0"
fi

# --- scratch ファイルが dist に残らない ---
leftovers=$(find "$TMP/dist1" "$TMP/dist6" -name ".hawk-desugar.*" 2>/dev/null | wc -l)
if [[ "$leftovers" -eq 0 ]]; then ok "no_scratch_leftovers"; else ng "no_scratch_leftovers" "$leftovers scratch files remain"; fi

# --- 同一実体を別名で include すると exit 1 (mirror 後に定義が二重実行されるため) ---
aliasinc="$TMP/aliasinc"
mkdir -p "$aliasinc"
cp "$FIX/aliasinc/main.awk" "$FIX/aliasinc/x.awk" "$aliasinc/"
ln -s x.awk "$aliasinc/alias.awk"
dist="$TMP/distai"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$aliasinc/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"aliases already-included file"* ]]; then ok "alias_include_rejected"; else ng "alias_include_rejected" "exit=$st: $err"; fi
if [[ ! -e "$dist/main.awk" ]]; then ok "alias_include_publishes_nothing"; else ng "alias_include_publishes_nothing" "dist/main.awk exists"; fi

# --- 空白入り HAWK_DIST でも publish が壊れない ---
dist="$TMP/dist with spaces"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null; then
  if [[ -f "$dist/main.awk" && -f "$dist/app/page.awk" ]]; then ok "spaced_dist_publishes"; else ng "spaced_dist_publishes" "missing outputs"; fi
else
  ng "spaced_dist_publishes" "exit != 0"
fi

# --- 空白入り include パスは exit 1 (_seen の区切りと衝突するため非サポート) ---
dist="$TMP/distsn"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/spacename/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"contains spaces"* ]]; then ok "spaced_include_rejected"; else ng "spaced_include_rejected" "exit=$st: $err"; fi
if [[ ! -e "$dist/main.awk" ]]; then ok "spaced_include_publishes_nothing"; else ng "spaced_include_publishes_nothing" "dist/main.awk exists"; fi

# --- marker が regular file 以外なら staging 前に exit 1 ---
dist="$TMP/distmk"
mkdir -p "$dist/.hawk-dist"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"not a regular file"* ]]; then ok "invalid_marker_rejected"; else ng "invalid_marker_rejected" "exit=$st: $err"; fi
if [[ ! -e "$dist/solo.awk" ]]; then ok "invalid_marker_publishes_nothing"; else ng "invalid_marker_publishes_nothing" "dist/solo.awk exists"; fi

# --- 出力先が既存ディレクトリなら exit 1 (mv がディレクトリ内へ移動してしまうため) ---
dist="$TMP/distdir"
mkdir -p "$dist/solo.awk"
set +e
HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" >/dev/null 2>&1
st=$?
set -e
if [[ "$st" -eq 1 && -d "$dist/solo.awk" ]]; then ok "dir_output_rejected"; else ng "dir_output_rejected" "exit=$st"; fi

# --- HAWK_DIST が source 木の中の別ファイルを指すと拒否 (marker 保護) ---
srctree="$TMP/srctree"
mkdir -p "$srctree/sub"
cp "$FIX/solo.awk" "$srctree/main.awk"
printf 'BEGIN { print "another source" }\n' > "$srctree/sub/main.awk"
before_hash=$(cksum < "$srctree/sub/main.awk")
set +e
err=$(HAWK_DIST="$srctree/sub" "$LIBS" desugar "$srctree/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"refusing to overwrite"* ]]; then ok "dist_over_source_rejected"; else ng "dist_over_source_rejected" "exit=$st: $err"; fi
after_hash=$(cksum < "$srctree/sub/main.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "dist_over_source_untouched"; else ng "dist_over_source_untouched" "source file was modified"; fi

# --- marker のある dist への再実行 (上書き) は成功する ---
dist="$TMP/distrerun"
HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null; then ok "rerun_over_marker_ok"; else ng "rerun_over_marker_ok" "exit != 0"; fi

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
