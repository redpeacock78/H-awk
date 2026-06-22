# SPDX-License-Identifier: MIT
# tests/unit/test_cache.awk

function test_cache_memory_get_set(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("k1", "v1", 60)
  v = cache::get("k1")
  assert_eq(v, "v1", "cache memory: get after set")
  assert_eq(cache::found(), 1, "cache memory: found=1 on hit")
}

function test_cache_memory_miss(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  v = cache::get("no_such_key")
  assert_eq(v, "", "cache memory: miss returns empty")
  assert_eq(cache::found(), 0, "cache memory: found=0 on miss")
}

function test_cache_memory_del(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("dk", "dv", 60)
  cache::del("dk")
  v = cache::get("dk")
  assert_eq(v, "", "cache memory: del removes key")
  assert_eq(cache::found(), 0, "cache memory: found=0 after del")
}

function test_cache_memory_has() {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("hk", "hv", 60)
  assert_eq(cache::has("hk"), 1, "cache memory: has=1 for existing key")
  assert_eq(cache::has("no_such"), 0, "cache memory: has=0 for missing key")
}

function test_cache_memory_ttl_zero(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("noexp", "v", 0)
  v = cache::get("noexp")
  assert_eq(v, "v", "cache memory: ttl=0 never expires")
}

function test_cache_off(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  cache::set("ok", "ov", 60)
  v = cache::get("ok")
  assert_eq(v, "", "cache off: get always misses")
  assert_eq(cache::found(), 0, "cache off: found=0")
}

function test_cache_backend_memory() {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  assert_eq(cache::backend(), "memory", "cache backend: memory")
}

function test_cache_backend_off() {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  assert_eq(cache::backend(), "off", "cache backend: off")
}

function test_cache_stats(    s) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("s1", "v1", 60)
  cache::get("s1")
  cache::get("nx")
  s = cache::stats()
  assert_true(index(s, "hit=1") > 0,  "cache stats: hit=1")
  assert_true(index(s, "miss=1") > 0, "cache stats: miss=1")
  assert_true(index(s, "set=1") > 0,  "cache stats: set=1")
}

function test_cache_file_set_get(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_test_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("fk1", "world", 60)
  assert_eq(cache::get("fk1"), "world", "cache/file: set/get")
  assert_eq(cache::found(), 1, "cache/file: found=1")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_tab_newline(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_file2_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("tab_key", "line1\nline2\ttab", 60)
  assert_eq(cache::get("tab_key"), "line1\nline2\ttab", "cache/file: tab/newline round-trip")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_ttl_expired(    saved_be, saved_dir, dir, cmd) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_file3_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("exp_k", "v", 60)
  cmd = "gawk -F'\\t' 'BEGIN{OFS=\"\\t\"} {$2=" (awk::systime() - 10) "; print}' " dir "/cache/cache.tsv > " dir "/cache/cache.tsv.tmp && mv " dir "/cache/cache.tsv.tmp " dir "/cache/cache.tsv"
  system(cmd)
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  assert_eq(cache::get("exp_k"), "", "cache/file: expired TTL is miss")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_escape_unescape() {
  assert_eq(cache::_escape("a\tb"), "a\\tb",   "cache: escape tab")
  assert_eq(cache::_escape("a\nb"), "a\\nb",   "cache: escape newline")
  assert_eq(cache::_escape("a\\b"), "a\\\\b",  "cache: escape backslash")
  assert_eq(cache::_unescape("a\\tb"),  "a\tb",  "cache: unescape tab")
  assert_eq(cache::_unescape("a\\nb"),  "a\nb",  "cache: unescape newline")
  assert_eq(cache::_unescape("a\\\\b"), "a\\b",  "cache: unescape backslash")
}

function test_cache_auto_no_zig_no_dir(    saved_be, saved_dir) {
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "auto"
  ENVIRON["HAWK_RUN_DIR"] = ""
  cache::_reset()
  assert_eq(cache::backend(), "memory", "cache: auto falls back to memory")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_auto_with_dir(    saved_be, saved_dir, dir, b) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_auto_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "auto"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  b = cache::backend()
  assert_true((b == "file" || b == "zig"), "cache: auto selects file or zig when dir available")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_empty_string_hit_vs_miss(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("empty", "", 60)
  v = cache::get("empty")
  assert_eq(v, "", "cache: empty string value returns ''")
  assert_eq(cache::found(), 1, "cache: empty string value is hit (found=1)")

  v = cache::get("missing")
  assert_eq(v, "", "cache: missing key returns ''")
  assert_eq(cache::found(), 0, "cache: missing key is miss (found=0)")
}

function test_cache_zig_found_api(    saved_be, v) {
  if (!LIBS_LOADED["cache"]) { TESTS_SKIPPED++; return }
  saved_be = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "zig"
  cache::_reset()

  cache::set("zfound", "zval", 60)
  v = cache::get("zfound")
  assert_eq(v, "zval", "cache zig found: get returns value")
  assert_eq(cache::found(), 1, "cache zig found: hit -> found=1")

  v = cache::get("zfound_missing")
  assert_eq(v, "", "cache zig found: missing returns ''")
  assert_eq(cache::found(), 0, "cache zig found: miss -> found=0")

  cache::set("zempty", "", 60)
  v = cache::get("zempty")
  assert_eq(v, "", "cache zig found: empty value returns ''")
  assert_eq(cache::found(), 1, "cache zig found: empty value hit -> found=1")

  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
}
