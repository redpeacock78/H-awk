#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0
LIBS=./libexec/hawk-libs
LIBS_ABS="$(pwd)/libexec/hawk-libs"
FIX=tests/unit/desugar/fixtures

ok() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
ng() { printf "  FAIL: %s%s\n" "$1" "${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { printf "  SKIP: %s%s\n" "$1" "${2:+ ($2)}"; }

# root では chmod a-w が -w 判定にも truncate 阻止にも効かないため、
# root 専用フィクスチャを別途用意するまでは該当アサーションを SKIP する
IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

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
  leftovers=$(find "$dist" -name ".hawk-desugar.*" 2>/dev/null | wc -l)
  if [[ "$leftovers" -eq 0 ]]; then ok "spaced_dist_no_scratch_leftovers"; else ng "spaced_dist_no_scratch_leftovers" "$leftovers scratch files remain"; fi
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

# --- ".hawk-dist" という include 名は marker の予約名として exit 1 ---
dist="$TMP/distrn"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/resname/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"reserved for the dist marker"* ]]; then ok "marker_name_include_rejected"; else ng "marker_name_include_rejected" "exit=$st: $err"; fi

# --- プロジェクト内を指す絶対パス include は exit 1、外部の絶対パスは素通り ---
absinc="$TMP/absinc"
mkdir -p "$absinc"
cat > "$absinc/x.awk" << 'AWKEOF'
function abs_x() { return 1 }
AWKEOF
printf '@include "%s/x.awk"\nBEGIN { print "absinc" }\n' "$absinc" > "$absinc/main.awk"
dist="$TMP/distabs"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$absinc/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"absolute include points inside project root"* ]]; then ok "abs_include_inside_root_rejected"; else ng "abs_include_inside_root_rejected" "exit=$st: $err"; fi

absext="$TMP/absext"
mkdir -p "$absext"
printf '@include "/no/such/external.awk"\nBEGIN { print "absext" }\n' > "$absext/main.awk"
dist="$TMP/distabse"
if HAWK_DIST="$dist" "$LIBS" desugar "$absext/main.awk" >/dev/null; then
  if grep -qF '@include "/no/such/external.awk"' "$dist/main.awk"; then ok "abs_include_external_passthrough"; else ng "abs_include_external_passthrough"; fi
else
  ng "abs_include_external_passthrough" "exit != 0"
fi

# --- marker が書込不可なら staging 前に exit 1 (publish 後の更新失敗を防ぐ) ---
# root (id -u == 0) では chmod a-w が -w 判定にも truncate 阻止にも効かず
# exit=0 になってしまうため、root 実行時はこの2アサーションを SKIP する
if [[ "$IS_ROOT" -eq 1 ]]; then
  skip "unwritable_marker_rejected" "running as root, chmod a-w has no effect"
  skip "unwritable_marker_publishes_nothing" "running as root, chmod a-w has no effect"
else
  dist="$TMP/distmkw"
  HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" >/dev/null
  before_hash=$(cksum < "$dist/solo.awk")
  chmod a-w "$dist/.hawk-dist"
  set +e
  err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" 2>&1 >/dev/null)
  st=$?
  set -e
  chmod u+w "$dist/.hawk-dist"
  if [[ "$st" -eq 1 && "$err" == *"not writable"* ]]; then ok "unwritable_marker_rejected"; else ng "unwritable_marker_rejected" "exit=$st: $err"; fi
  after_hash=$(cksum < "$dist/solo.awk")
  if [[ "$before_hash" == "$after_hash" && ! -e "$dist/main.awk" ]]; then ok "unwritable_marker_publishes_nothing"; else ng "unwritable_marker_publishes_nothing"; fi
fi

# --- marker が symlink なら staging 前に exit 1 (上書き保護の偽装を防ぐ) ---
dist="$TMP/distmks"
mkdir -p "$dist"
printf 'marker target\n' > "$TMP/ext-marker"
ln -s "$TMP/ext-marker" "$dist/.hawk-dist"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"is a symlink"* ]]; then ok "symlink_marker_rejected"; else ng "symlink_marker_rejected" "exit=$st: $err"; fi
if [[ "$(cat "$TMP/ext-marker")" == "marker target" ]]; then ok "symlink_marker_target_untouched"; else ng "symlink_marker_target_untouched"; fi

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

# --- marker は publish 済み rel のみ信頼し、同じ dist 配下の無関係な既存ファイルは
#     引き続き上書き保護される (marker が空ファイルだと最初の成功後に
#     ディレクトリ全体を信頼してしまう問題の再現) ---
srcsub2="$TMP/srcsub2"
mkdir -p "$srcsub2/sub"
cp "$FIX/solo.awk" "$srcsub2/main.awk"
HAWK_DIST="$srcsub2/sub" "$LIBS" desugar "$srcsub2/main.awk" >/dev/null
printf 'BEGIN { print "other-source" }\n' > "$srcsub2/sub/other.awk"
before_hash=$(cksum < "$srcsub2/sub/other.awk")
cp "$FIX/solo.awk" "$srcsub2/other.awk"
set +e
err=$(HAWK_DIST="$srcsub2/sub" "$LIBS" desugar "$srcsub2/other.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"refusing to overwrite"* ]]; then ok "marker_does_not_bless_unrelated_files"; else ng "marker_does_not_bless_unrelated_files" "exit=$st: $err"; fi
after_hash=$(cksum < "$srcsub2/sub/other.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "marker_does_not_bless_unrelated_files_untouched"; else ng "marker_does_not_bless_unrelated_files_untouched" "source file was modified"; fi

# --- include 名に glob 文字が含まれても、_seen の未クォート展開で
#     カレントディレクトリの同名ファイルと誤って alias 判定されない ---
globinc="$TMP/globinc"
mkdir -p "$globinc"
cat > "$globinc/main.awk" <<'EOF'
@include "x*.awk"
@include "xfoo.awk"
BEGIN { print "glob-ok" }
EOF
printf 'BEGIN { }\n' > "$globinc/x*.awk"
printf 'BEGIN { }\n' > "$globinc/xfoo.awk"
dist="$TMP/distglob"
set +e
out=$(cd "$globinc" && HAWK_DIST="$dist" "$LIBS_ABS" desugar main.awk 2>&1)
st=$?
set -e
if [[ "$st" -eq 0 && -f "$dist/x*.awk" && -f "$dist/xfoo.awk" ]]; then
  ok "glob_include_names_not_confused"
else
  ng "glob_include_names_not_confused" "exit=$st: $out"
fi

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

# --- marker が書込可だが読込不可なら staging 前に exit 1
#     (publish 後の marker 読込失敗を防ぐ) ---
if [[ "$IS_ROOT" -eq 1 ]]; then
  skip "unreadable_marker_rejected" "running as root, chmod a-r has no effect"
else
  dist="$TMP/distmkr"
  HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" >/dev/null
  before_hash=$(cksum < "$dist/solo.awk")
  chmod a-r "$dist/.hawk-dist"
  set +e
  err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" 2>&1 >/dev/null)
  st=$?
  set -e
  chmod u+r "$dist/.hawk-dist"
  if [[ "$st" -eq 1 && "$err" == *"not readable"* ]]; then ok "unreadable_marker_rejected"; else ng "unreadable_marker_rejected" "exit=$st: $err"; fi
  after_hash=$(cksum < "$dist/solo.awk")
  if [[ "$before_hash" == "$after_hash" && ! -e "$dist/main.awk" ]]; then ok "unreadable_marker_publishes_nothing"; else ng "unreadable_marker_publishes_nothing"; fi
fi

# --- rel が "-" で始まっても marker 照合の grep がオプションと誤解釈せず
#     再実行できる ---
dashinc="$TMP/dashinc"
mkdir -p "$dashinc"
cat > "$dashinc/-main.awk" << 'AWKEOF'
BEGIN { print "dash" }
AWKEOF
dist="$TMP/distdash"
set +e
out1=$(cd "$dashinc" && HAWK_DIST="$dist" "$LIBS_ABS" desugar ./-main.awk 2>&1)
st1=$?
out2=$(cd "$dashinc" && HAWK_DIST="$dist" "$LIBS_ABS" desugar ./-main.awk 2>&1)
st2=$?
set -e
if [[ "$st1" -eq 0 && "$st2" -eq 0 ]]; then ok "dash_prefixed_entry_rerunnable"; else ng "dash_prefixed_entry_rerunnable" "exit1=$st1 exit2=$st2: $out1 / $out2"; fi

# --- プロジェクト外の絶対パス include が、実はプロジェクト内ファイルへの
#     symlink である場合は拒否 (dist と source の二重定義を防ぐ) ---
abssym="$TMP/abssym"
mkdir -p "$abssym/project" "$abssym/outside"
cat > "$abssym/project/x.awk" << AWKEOF
@include "$abssym/outside/alias.awk"
function proj_x() { return 1 }
AWKEOF
cat > "$abssym/project/main.awk" << 'AWKEOF'
@include "x.awk"
BEGIN { print "abssym" }
AWKEOF
ln -s "$abssym/project/x.awk" "$abssym/outside/alias.awk"
dist="$TMP/distabssym"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$abssym/project/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"absolute include points inside project root"* ]]; then ok "abs_symlink_include_to_project_rejected"; else ng "abs_symlink_include_to_project_rejected" "exit=$st: $err"; fi

# --- 出力先がダングリング symlink でも -e だけでなく -L も見て
#     上書き保護される (置き換えられずに残る) ---
dist="$TMP/distdangle"
mkdir -p "$dist"
ln -s "$TMP/missing-target" "$dist/solo.awk"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 ]]; then ok "dangling_symlink_output_rejected"; else ng "dangling_symlink_output_rejected" "exit=$st: $err"; fi
if [[ -L "$dist/solo.awk" && ! -e "$dist/solo.awk" ]]; then ok "dangling_symlink_output_untouched"; else ng "dangling_symlink_output_untouched"; fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
