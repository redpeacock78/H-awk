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
if [[ "$out" == "$dist/tests/unit/desugar/fixtures/proj/main.awk" ]]; then ok "entry_path_echoed"; else ng "entry_path_echoed" "$out"; fi
if [[ -f "$dist/app/page.awk" ]]; then ok "included_file_mirrored"; else ng "included_file_mirrored"; fi
if [[ -f "$dist/app/sub/util.awk" ]]; then ok "nested_include_mirrored"; else ng "nested_include_mirrored"; fi
if grep -qF "@include \"$dist/current/" "$dist/main.awk" && grep -qF "app/page.awk\"" "$dist/main.awk"; then ok "include_rewritten"; else ng "include_rewritten"; fi
if grep -qF "@include \"$dist/current/" "$dist/app/page.awk" && grep -qF "app/sub/util.awk\"" "$dist/app/page.awk"; then ok "nested_include_rewritten"; else ng "nested_include_rewritten"; fi
if ! grep -q "let " "$dist/app/page.awk"; then ok "included_file_desugared"; else ng "included_file_desugared"; fi
run_out=$(gawk -f "$dist/main.awk" </dev/null)
if [[ "$run_out" == "hello from page" ]]; then ok "desugared_tree_runs"; else ng "desugared_tree_runs" "$run_out"; fi

shared="$TMP/shared"
mkdir -p "$shared"
printf 'type User = { name: Str }\nfunction get_name() -> Str { return "shared" }\n' > "$shared/types.awk"
printf '@include "types.awk"\nfunction main() -> Response { let u: User = { name: get_name() }; return ctx.res.text(get_name()) }\n' > "$shared/main.awk"
if HAWK_DIST="$TMP/distshared" "$LIBS" desugar "$shared/main.awk" >/dev/null; then ok "shared_declarations_compile"; else ng "shared_declarations_compile"; fi

shared_sig="$TMP/shared-sig"
mkdir -p "$shared_sig"
printf 'function normalize(x: Str) -> Str { return x }\n' > "$shared_sig/lib.awk"
printf '@include "lib.awk"\nfunction caller() { return normalize(123) }\nBEGIN { caller() }\n' > "$shared_sig/main.awk"
set +e
err=$(HAWK_DIST="$TMP/distsharedsig" "$LIBS" desugar "$shared_sig/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -ne 0 && "$err" == *"normalize argument 1 expects Str, got Int"* ]]; then ok "shared_signature_checks_raw_caller"; else ng "shared_signature_checks_raw_caller" "exit=$st: $err"; fi

lex_state="$TMP/lex-state"
mkdir -p "$lex_state"
printf 'function dsl_body() {\n  let x: Int = 1\n  return x\n}\n' > "$lex_state/a.awk"
printf 'function raw(a, b) {\n  return a + b\n}\n' > "$lex_state/b.awk"
printf '@include "a.awk"\n@include "b.awk"\nfunction caller() { return raw(1, 2) }\nBEGIN { print caller() }\n' > "$lex_state/main.awk"
lex_index="$TMP/lex-index.awk"
gawk -v V2_INDEX_LIST="$lex_state/a.awk"$'\034'"$lex_state/b.awk" -v V2_INDEX_OUT="$lex_index" -f dsl/index.awk
if HAWK_DIST="$TMP/distlexstate" "$LIBS" desugar "$lex_state/main.awk" >/dev/null && ! grep -qF 'V2_SHARED_SIG["raw"' "$lex_index"; then ok "index_lex_state_isolated_per_file"; else ng "index_lex_state_isolated_per_file" "raw function was indexed as DSL"; fi

gen="$TMP/generation"
HAWK_DIST="$gen" "$LIBS" desugar "$FIX/solo.awk" >/dev/null
old_gen=$(readlink "$gen/current")
HAWK_DIST="$gen" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null
new_gen=$(readlink "$gen/current")
if [[ "$old_gen" != "$new_gen" && $(find -L "$gen/current" -type f -name main.awk | wc -l | tr -d ' ') -eq 1 && $(find "$gen/$old_gen" -type f -name solo.awk | wc -l | tr -d ' ') -eq 1 ]]; then ok "generation_switch_is_atomic"; else ng "generation_switch_is_atomic"; fi

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
  if grep -qF "@include \"$dist/current/" "$dist/main.awk" && grep -qF "x.awk\"" "$dist/main.awk"; then ok "dotslash_include_normalized"; else ng "dotslash_include_normalized"; fi
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

resns="$TMP/resname"
mkdir -p "$resns/.hawk-dist"
cp "$FIX/resname/main.awk" "$resns/main.awk"
printf 'function rn_x() { return 1 }\n' > "$resns/.hawk-dist/x.awk"
sed -i.bak 's/\.hawk-dist"/.hawk-dist\/x.awk"/' "$resns/main.awk"
rm "$resns/main.awk.bak"
dist="$TMP/distns"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$resns/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"reserved for the dist marker"* && ! -e "$dist/main.awk" && ! -e "$dist/.hawk-dist" ]]; then ok "marker_namespace_include_rejected"; else ng "marker_namespace_include_rejected" "exit=$st: $err"; fi

reserved_ns="$TMP/reserved-namespace"
mkdir -p "$reserved_ns/current"
printf '@include "current/x.awk"\nBEGIN { print "reserved-namespace" }\n' > "$reserved_ns/main.awk"
printf 'function reserved_x() { return 1 }\n' > "$reserved_ns/current/x.awk"
dist="$TMP/dist-reserved-namespace"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$reserved_ns/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"reserved output namespace: current/x.awk"* && ! -e "$dist/current" ]]; then ok "reserved_namespace_include_rejected"; else ng "reserved_namespace_include_rejected" "exit=$st: $err"; fi

reserved_entry="$TMP/reserved-entry"
mkdir -p "$reserved_entry/.hawk-dist"
printf 'BEGIN { print "reserved-entry" }\n' > "$reserved_entry/.hawk-dist/main.awk"
dist="$TMP/dist-reserved-entry"
set +e
err=$(cd "$reserved_entry" && HAWK_DIST="$dist" "$LIBS_ABS" desugar .hawk-dist/main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *".hawk-dist/main.awk"* && ! -e "$dist/current" && ! -e "$dist/.hawk-dist" ]]; then ok "reserved_entry_namespace_rejected"; else ng "reserved_entry_namespace_rejected" "exit=$st: $err"; fi

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

# --- プロジェクト内のファイルへの hard link を指す絶対パス include も exit 1 ---
abshard="$TMP/abshard"
outside2="$TMP/outside2"
mkdir -p "$abshard" "$outside2"
printf '@include "x.awk"\nBEGIN { print "abshard" }\n' > "$abshard/main.awk"
printf '@include "%s/alias.awk"\nfunction ah_x() { return 1 }\n' "$outside2" > "$abshard/x.awk"
ln "$abshard/x.awk" "$outside2/alias.awk"
dist="$TMP/distah"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$abshard/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"same file as"* ]]; then ok "abs_hardlink_include_to_project_rejected"; else ng "abs_hardlink_include_to_project_rejected" "exit=$st: $err"; fi

# --- 絶対パス hard link が、その absolute include より後で relative include される sibling を指す場合も exit 1 ---
abshard2="$TMP/abshard2"
outside3="$TMP/outside3"
mkdir -p "$abshard2" "$outside3"
printf 'function ah2_x() { return 1 }\n' > "$abshard2/x.awk"
ln "$abshard2/x.awk" "$outside3/alias.awk"
printf '@include "%s/alias.awk"\n@include "x.awk"\nBEGIN { print "abshard2" }\n' "$outside3" > "$abshard2/main.awk"
dist="$TMP/distah2"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$abshard2/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"same file as"* && ! -e "$dist/main.awk" && ! -e "$dist/x.awk" ]]; then
  ok "abs_hardlink_to_later_sibling_rejected"
else
  ng "abs_hardlink_to_later_sibling_rejected" "exit=$st: $err"
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
if [[ "$st" -eq 1 && "$err" == *"dist and source trees overlap"* ]]; then ok "dist_over_source_rejected"; else ng "dist_over_source_rejected" "exit=$st: $err"; fi
after_hash=$(cksum < "$srctree/sub/main.awk")
if [[ "$before_hash" == "$after_hash" ]]; then ok "dist_over_source_untouched"; else ng "dist_over_source_untouched" "source file was modified"; fi

# --- marker 所有の旧 flat regular file は generation symlink へ移行する ---
legacy_stable="$TMP/legacy-stable"
mkdir -p "$legacy_stable/dist"
printf 'BEGIN { print "new-stable" }\n' > "$legacy_stable/main.awk"
printf 'BEGIN { print "old-stable" }\n' > "$legacy_stable/dist/main.awk"
legacy_stable_src="$(cd "$legacy_stable" && pwd -P)"
printf '%s\tmain.awk\n' "$legacy_stable_src" > "$legacy_stable/dist/.hawk-dist"
set +e
err=$(cd "$legacy_stable" && HAWK_DIST=dist "$LIBS_ABS" desugar main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 0 && -L "$legacy_stable/dist/main.awk" && "$(gawk -f "$legacy_stable/dist/main.awk" </dev/null)" == "new-stable" ]]; then ok "legacy_stable_regular_migrated"; else ng "legacy_stable_regular_migrated" "exit=$st: $err"; fi

legacy_compat="$TMP/legacy-compat"
legacy_compat_src="$legacy_compat/apps/a"
legacy_compat_dist="$legacy_compat_src/dist"
mkdir -p "$legacy_compat_src" "$legacy_compat_dist"
printf 'BEGIN { print "new-compat" }\n' > "$legacy_compat_src/main.awk"
printf 'BEGIN { print "old-compat" }\n' > "$legacy_compat_dist/main.awk"
legacy_compat_src_phys="$(cd "$legacy_compat_src" && pwd -P)"
printf '%s\tmain.awk\tcompat\n' "$legacy_compat_src_phys" > "$legacy_compat_dist/.hawk-dist"
set +e
err=$(cd "$legacy_compat" && HAWK_DIST="$legacy_compat_dist" "$LIBS_ABS" desugar apps/a/main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 0 && -L "$legacy_compat_dist/main.awk" && -L "$legacy_compat_dist/apps/a/main.awk" && "$(gawk -f "$legacy_compat_dist/main.awk" </dev/null)" == "new-compat" ]]; then ok "legacy_compat_regular_migrated"; else ng "legacy_compat_regular_migrated" "exit=$st: $err"; fi

legacy_dir="$TMP/legacy-dir"
mkdir -p "$legacy_dir/dist/main.awk"
printf 'BEGIN { print "directory-guard" }\n' > "$legacy_dir/main.awk"
legacy_dir_src="$(cd "$legacy_dir" && pwd -P)"
printf '%s\tmain.awk\n' "$legacy_dir_src" > "$legacy_dir/dist/.hawk-dist"
set +e
err=$(cd "$legacy_dir" && HAWK_DIST=dist "$LIBS_ABS" desugar main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && -d "$legacy_dir/dist/main.awk" && ! -e "$legacy_dir/dist/current" && ! -L "$legacy_dir/dist/current" ]]; then ok "marker_owned_directory_rejected_early"; else ng "marker_owned_directory_rejected_early" "exit=$st, current=$([[ -e "$legacy_dir/dist/current" || -L "$legacy_dir/dist/current" ]] && echo yes || echo no): $err"; fi

# --- marker のある dist への再実行 (上書き) は成功する ---
dist="$TMP/distrerun"
HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null; then ok "rerun_over_marker_ok"; else ng "rerun_over_marker_ok" "exit != 0"; fi

# --- marker 未登録の compat symlink は上書きしない ---
compat_src="$TMP/unowned-compat-src"
dist="$TMP/unowned-compat-dist"
mkdir -p "$compat_src/apps/a" "$dist"
printf 'BEGIN { print "compat" }\n' > "$compat_src/apps/a/main.awk"
compat_target="$TMP/unowned-compat-target"
printf 'user file\n' > "$compat_target"
ln -s "$compat_target" "$dist/main.awk"
set +e
err=$(cd "$compat_src" && HAWK_DIST="$dist" "$LIBS_ABS" desugar apps/a/main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && -L "$dist/main.awk" && "$(readlink "$dist/main.awk")" == "$compat_target" && ! -e "$dist/current" ]]; then ok "unowned_compat_symlink_rejected"; else ng "unowned_compat_symlink_rejected" "exit=$st, target=$(readlink "$dist/main.awk" 2>/dev/null): $err"; fi

# --- 改ざんされた stable symlink は現行 generation へ戻す ---
stale_src="$TMP/stale-stable-src"
mkdir -p "$stale_src"
cp "$FIX/solo.awk" "$stale_src/main.awk"
dist="$TMP/dist-stale-stable"
( cd "$stale_src" && HAWK_DIST="$dist" "$LIBS_ABS" desugar main.awk >/dev/null )
stale_target="$TMP/stale-target.awk"
printf 'BEGIN { print "stale" }\n' > "$stale_target"
rm "$dist/main.awk"
ln -s "$stale_target" "$dist/main.awk"
( cd "$stale_src" && HAWK_DIST="$dist" "$LIBS_ABS" desugar main.awk >/dev/null )
if [[ -L "$dist/main.awk" && "$(readlink "$dist/main.awk")" == "$dist/current/main.awk" ]]; then ok "stale_stable_symlink_refreshed"; else ng "stale_stable_symlink_refreshed" "target=$(readlink "$dist/main.awk" 2>/dev/null)"; fi

stale_dir="$TMP/stale-directory-target"
mkdir -p "$stale_dir"
rm "$dist/main.awk"
ln -s "$stale_dir" "$dist/main.awk"
( cd "$stale_src" && HAWK_DIST="$dist" "$LIBS_ABS" desugar main.awk >/dev/null )
if [[ -L "$dist/main.awk" && "$(readlink "$dist/main.awk")" == "$dist/current/main.awk" ]]; then ok "stale_directory_symlink_refreshed"; else ng "stale_directory_symlink_refreshed" "target=$(readlink "$dist/main.awk" 2>/dev/null)"; fi

# --- record と alias が include 間で同名なら index 時点で拒否する ---
type_collision="$TMP/type-collision"
mkdir -p "$type_collision"
printf 'type User = { name: Str }\n' > "$type_collision/record.awk"
printf 'type User = Str\n' > "$type_collision/alias.awk"
printf '@include "record.awk"\n@include "alias.awk"\nBEGIN { print "collision" }\n' > "$type_collision/main.awk"
printf '@include "alias.awk"\n@include "record.awk"\nBEGIN { print "collision" }\n' > "$type_collision/reverse.awk"
dist="$TMP/dist-type-collision"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$type_collision/main.awk" 2>&1 >/dev/null)
st=$?
err_reverse=$(HAWK_DIST="$TMP/dist-type-collision-reverse" "$LIBS" desugar "$type_collision/reverse.awk" 2>&1 >/dev/null)
st_reverse=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"type name is both record and alias: User"* && "$st_reverse" -eq 1 && "$err_reverse" == *"type name is both record and alias: User"* ]]; then ok "alias_record_name_collision_rejected"; else ng "alias_record_name_collision_rejected" "forward=$st: $err / reverse=$st_reverse: $err_reverse"; fi

# --- 異なる source の同名 basename entry は namespace で分離される ---
multi_entry="$TMP/multi-entry"
mkdir -p "$multi_entry/apps/a" "$multi_entry/apps/b"
printf 'BEGIN { print "from-a" }\n' > "$multi_entry/apps/a/main.awk"
printf 'BEGIN { print "from-b" }\n' > "$multi_entry/apps/b/main.awk"
dist="$TMP/distcs"
( cd "$multi_entry" && HAWK_DIST="$dist" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null )
first_a="$dist/$(readlink "$dist/current")/apps/a/main.awk"
compat_a="$(readlink "$dist/main.awk")"
( cd "$multi_entry" && HAWK_DIST="$dist" "$LIBS_ABS" desugar apps/b/main.awk >/dev/null )
compat_after_b="$(readlink "$dist/main.awk")"
( cd "$multi_entry" && HAWK_DIST="$dist" "$LIBS_ABS" desugar apps/b/main.awk >/dev/null )
if [[ "$compat_after_b" == "$compat_a" && "$(readlink "$dist/main.awk")" == "$compat_a" ]]; then ok "cross_source_compat_owner_persists_on_rerun"; else ng "cross_source_compat_owner_persists_on_rerun"; fi
entries=$(find -L "$dist/current" -type f -name main.awk | wc -l | tr -d ' ')
if [[ "$entries" -eq 2 && "$(readlink "$dist/main.awk")" == "$compat_a" ]] && grep -q "from-a" "$dist/apps/a/main.awk" && grep -q "from-b" "$dist/apps/b/main.awk"; then
  ok "cross_source_same_basename_isolated"
else
  ng "cross_source_same_basename_isolated" "entries=$entries"
fi
run_a=$(gawk -f "$dist/apps/a/main.awk" </dev/null)
run_b=$(gawk -f "$dist/apps/b/main.awk" </dev/null)
if [[ "$run_a" == "from-a" && "$run_b" == "from-b" && "$first_a" -ef "$dist/current/apps/a/main.awk" ]]; then
  ok "multi_entry_namespace_coexist"
else
  ng "multi_entry_namespace_coexist" "a=$run_a, b=$run_b"
fi

dist_namespace_owner="$TMP/dist-namespace-owner"
( cd "$multi_entry" && HAWK_DIST="$dist_namespace_owner" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null )
if ( cd "$multi_entry" && HAWK_DIST="$dist_namespace_owner" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null ); then
  ok "namespaced_same_cwd_rerun"
else
  ng "namespaced_same_cwd_rerun"
fi
mkdir -p "$dist_namespace_owner/a"
unrelated_namespace_target="$TMP/unrelated-namespace-target.awk"
printf 'BEGIN { print "unrelated" }\n' > "$unrelated_namespace_target"
ln -s "$unrelated_namespace_target" "$dist_namespace_owner/a/main.awk"
unrelated_namespace_link="$(readlink "$dist_namespace_owner/a/main.awk")"
set +e
err=$(cd "$multi_entry/apps" && HAWK_DIST="$dist_namespace_owner" "$LIBS_ABS" desugar a/main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"refusing to overwrite existing namespaced output"* && -L "$dist_namespace_owner/a/main.awk" && "$(readlink "$dist_namespace_owner/a/main.awk")" == "$unrelated_namespace_link" ]]; then
  ok "cross_cwd_namespace_marker_isolated"
else
  ng "cross_cwd_namespace_marker_isolated" "exit=$st: $err"
fi

owner_a="$(cd "$multi_entry/apps/a" && pwd -P)"
owner_b="$(cd "$multi_entry/apps/b" && pwd -P)"
dist_missing_other="$TMP/dist-compat-missing-other"
( cd "$multi_entry" && HAWK_DIST="$dist_missing_other" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null )
rm "$dist_missing_other/main.awk"
set +e
( cd "$multi_entry" && HAWK_DIST="$dist_missing_other" "$LIBS_ABS" desugar apps/b/main.awk >/dev/null )
st=$?
set -e
if [[ "$st" -eq 0 && ! -e "$dist_missing_other/main.awk" && ! -L "$dist_missing_other/main.awk" ]] && ! grep -qxF -- "$owner_b"$'\t'main.awk$'\t'compat "$dist_missing_other/.hawk-dist"; then ok "missing_compat_other_source_skips"; else ng "missing_compat_other_source_skips" "exit=$st, compat=$([[ -e "$dist_missing_other/main.awk" || -L "$dist_missing_other/main.awk" ]] && echo yes || echo no)"; fi

dist_missing_self="$TMP/dist-compat-missing-self"
( cd "$multi_entry" && HAWK_DIST="$dist_missing_self" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null )
compat_self="$(readlink "$dist_missing_self/main.awk")"
rm "$dist_missing_self/main.awk"
( cd "$multi_entry" && HAWK_DIST="$dist_missing_self" "$LIBS_ABS" desugar apps/a/main.awk >/dev/null )
if [[ -L "$dist_missing_self/main.awk" && "$(readlink "$dist_missing_self/main.awk")" == "$compat_self" ]] && grep -qxF -- "$owner_a"$'\t'main.awk$'\t'compat "$dist_missing_self/.hawk-dist"; then ok "missing_compat_owner_repairs"; else ng "missing_compat_owner_repairs"; fi

# --- marker は publish 済み rel のみ信頼し、同じ dist 配下の無関係な既存ファイルは
#     引き続き上書き保護される (marker が空ファイルだと最初の成功後に
#     ディレクトリ全体を信頼してしまう問題の再現) ---
srcsub2="$TMP/srcsub2"
mkdir -p "$srcsub2/sub"
cp "$FIX/solo.awk" "$srcsub2/main.awk"
before_hash=$(cksum < "$srcsub2/main.awk")
if HAWK_DIST="$srcsub2/sub" "$LIBS" desugar "$srcsub2/main.awk" >/dev/null; then ok "source_tree_dist_published"; else ng "source_tree_dist_published"; fi
after_hash=$(cksum < "$srcsub2/main.awk")
if [[ "$before_hash" == "$after_hash" && $(find -L "$srcsub2/sub/current" -type f -name main.awk | wc -l | tr -d ' ') -eq 1 ]]; then ok "source_tree_dist_source_untouched"; else ng "source_tree_dist_source_untouched"; fi

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

# --- HAWK_DIST の末尾 / は親ディレクトリ検査前に正規化する ---
dist="$TMP/dist-trailing/"
if HAWK_DIST="$dist" "$LIBS" desugar "$FIX/solo.awk" >/dev/null && [[ -f "${dist%/}/solo.awk" ]]; then ok "hawk_dist_trailing_slash_normalized"; else ng "hawk_dist_trailing_slash_normalized"; fi

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

# --- marker 登録済みディレクトリが symlink に差し替わっていると、再 desugar は
#     symlink 先 (dist の外) に publish せず exit 1 ---
dist="$TMP/distsymout"
HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" >/dev/null
outside_symout="$TMP/outside_symout"
mkdir -p "$outside_symout"
rm -rf "$dist/app"
ln -s "$outside_symout" "$dist/app"
set +e
err=$(HAWK_DIST="$dist" "$LIBS" desugar "$FIX/proj/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && "$err" == *"escapes dist via symlink"* && ! -e "$outside_symout/page.awk" ]]; then
  ok "symlinked_output_dir_rejected"
else
  ng "symlinked_output_dir_rejected" "exit=$st: $err"
fi

# --- 出力先の親 symlink は mkdir -p より前に拒否し、外部にディレクトリを作らない ---
symlink_parent_src="$TMP/symlink-parent-src"
mkdir -p "$symlink_parent_src/app/sub"
printf '@include "app/sub/x.awk"\nBEGIN { print "symlink-parent" }\n' > "$symlink_parent_src/main.awk"
printf 'function symlink_parent_x() { return 1 }\n' > "$symlink_parent_src/app/sub/x.awk"
symlink_parent_dist="$TMP/symlink-parent-dist"
symlink_parent_outside="$TMP/symlink-parent-outside"
mkdir -p "$symlink_parent_dist" "$symlink_parent_outside"
ln -s "$symlink_parent_outside" "$symlink_parent_dist/app"
set +e
err=$(HAWK_DIST="$symlink_parent_dist" "$LIBS" desugar "$symlink_parent_src/main.awk" 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && ! -e "$symlink_parent_outside/sub" ]]; then
  ok "symlinked_parent_no_external_mkdir"
else
  ng "symlinked_parent_no_external_mkdir" "exit=$st, outside_sub=$([[ -e "$symlink_parent_outside/sub" ]] && echo yes || echo no): $err"
fi

# --- stable namespace の親 symlink は作成前に拒否し、外部へ出力しない ---
stable_parent_src="$TMP/stable-parent-src"
stable_parent_dist="$TMP/stable-parent-dist"
stable_parent_outside="$TMP/stable-parent-outside"
mkdir -p "$stable_parent_src/app" "$stable_parent_dist" "$stable_parent_outside"
printf 'BEGIN { print "stable-parent" }\n' > "$stable_parent_src/app/main.awk"
ln -s "$stable_parent_outside" "$stable_parent_dist/app"
set +e
err=$(cd "$stable_parent_src" && HAWK_DIST="$stable_parent_dist" "$LIBS_ABS" desugar app/main.awk 2>&1 >/dev/null)
st=$?
set -e
if [[ "$st" -eq 1 && ! -e "$stable_parent_outside/main.awk" && ! -e "$stable_parent_dist/current" ]]; then
  ok "stable_symlink_parent_escape_rejected"
else
  ng "stable_symlink_parent_escape_rejected" "exit=$st, external=$([[ -e "$stable_parent_outside/main.awk" ]] && echo yes || echo no): $err"
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
