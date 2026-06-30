# SPDX-License-Identifier: MIT
# tests/unit/test_cache.awk

function test_cache_memory_get_set(    v, r, opt) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("k1", "v1", 60)
  v = cache::get("k1")
  assert_eq(v, "v1", "cache memory: get after set")
  r = cache::dispatch("get", "k1")
  assert_true(result_ok(r), "cache memory: dispatch get hit ok")
  opt = result_val(r)
  assert_true(option_some(opt) && option_val(opt) == "v1", "cache memory: dispatch get hit some")
}

function test_cache_memory_miss(    v, r, opt) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  v = cache::get("no_such_key")
  assert_eq(v, "", "cache memory: miss returns empty")
  r = cache::dispatch("get", "no_such_key")
  assert_true(result_ok(r), "cache memory: dispatch get miss ok")
  opt = result_val(r)
  assert_true(option_none(opt), "cache memory: dispatch get miss none")
}

function test_cache_memory_del(    v, r, opt) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("dk", "dv", 60)
  cache::del("dk")
  v = cache::get("dk")
  assert_eq(v, "", "cache memory: del removes key")
  r = cache::dispatch("get", "dk")
  assert_true(result_ok(r), "cache memory: dispatch get after del ok")
  opt = result_val(r)
  assert_true(option_none(opt), "cache memory: dispatch get after del none")
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

function test_cache_off(    v, r, opt) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  cache::set("ok", "ov", 60)
  v = cache::get("ok")
  assert_eq(v, "", "cache off: get always misses")
  r = cache::dispatch("get", "ok")
  assert_true(result_ok(r), "cache off: dispatch get ok")
  opt = result_val(r)
  assert_true(option_none(opt), "cache off: dispatch get none")
}

function test_cache_file_set_get(    saved_be, saved_dir, dir, r, opt) {
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
  r = cache::dispatch("get", "fk1")
  assert_true(result_ok(r), "cache/file: dispatch get ok")
  opt = result_val(r)
  assert_true(option_some(opt) && option_val(opt) == "world", "cache/file: dispatch get some")
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

function test_cache_empty_string_hit_vs_miss(    v, r, opt) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::set("empty", "", 60)
  v = cache::get("empty")
  assert_eq(v, "", "cache: empty string value returns ''")
  r = cache::dispatch("get", "empty")
  assert_true(result_ok(r), "cache: empty string dispatch get ok")
  opt = result_val(r)
  assert_true(option_some(opt) && option_val(opt) == "", "cache: empty string dispatch get some")

  v = cache::get("missing")
  assert_eq(v, "", "cache: missing key returns ''")
  r = cache::dispatch("get", "missing")
  assert_true(result_ok(r), "cache: missing key dispatch get ok")
  opt = result_val(r)
  assert_true(option_none(opt), "cache: missing key dispatch get none")
}

function test_cache_zig_found_api(    saved_be, v, r, opt) {
  if (!LIBS_LOADED["cache"]) { TESTS_SKIPPED++; return }
  saved_be = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "zig"
  cache::_reset()

  cache::set("zfound", "zval", 60)
  v = cache::get("zfound")
  assert_eq(v, "zval", "cache zig found: get returns value")
  r = cache::dispatch("get", "zfound")
  assert_true(result_ok(r), "cache zig found: hit dispatch ok")
  opt = result_val(r)
  assert_true(option_some(opt) && option_val(opt) == "zval", "cache zig found: hit dispatch some")

  v = cache::get("zfound_missing")
  assert_eq(v, "", "cache zig found: missing returns ''")
  r = cache::dispatch("get", "zfound_missing")
  assert_true(result_ok(r), "cache zig found: miss dispatch ok")
  opt = result_val(r)
  assert_true(option_none(opt), "cache zig found: miss dispatch none")

  cache::set("zempty", "", 60)
  v = cache::get("zempty")
  assert_eq(v, "", "cache zig found: empty value returns ''")
  r = cache::dispatch("get", "zempty")
  assert_true(result_ok(r), "cache zig found: empty dispatch ok")
  opt = result_val(r)
  assert_true(option_some(opt) && option_val(opt) == "", "cache zig found: empty dispatch some")

  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
}
